# ============================================================
# build_post_ed.jl  ─  Post-revision Economic Dispatch 모델
# ============================================================
# 수식 참조: 보고서용 수식정리본 §4, mainland_re_bid_blocks §3
#
# (R1) 목적함수:  min Σ_t [ Σ_g c̃_{g,t}·p_{g,t} + Σ_k b_{k,t}·r_{k,t} ]
# (R2) 수급균형:  Σ_g p_{g,t} + Σ_k r_{k,t} + re_net_t = D_t   ∀t
#                 0 ≤ re_net_t ≤ RE_t^{nonbid}  (Dual Pollution 방지)
# (R3) 재생블록:  α·R̄_{k,t} ≤ r_{k,t} ≤ R̄_{k,t}  ∀k,t  (Pmin 제약 포함)
# (R4) 입찰하한:  BidFloor = -β × REC
# + Pre-model의 모든 제약 (P4, P5) 유지
# + Piecewise Linear 비용함수 지원
#
# Pre-model과의 차이:
# - 재생에너지 일부가 nonbid → bid 블록으로 전환
# - 입찰블록이 공급곡선에 포함되어 가격결정에 참여
# - SMP = LP dual (수급균형 쌍대변수, curtailment 오염 없음)
# ============================================================
# 의존: types.jl, build_pre_ed.jl (상위에서 include 완료)
# ============================================================

using JuMP
using HiGHS
import MathOptInterface as MOI

# ============================================================
# Post-revision ED 입력 구조
# ============================================================
"""
    PostEDInput

Post-revision ED 전용 입력.
PreEDInput + 재생에너지 입찰블록 + 비입찰 재생발전량.
"""
struct PostEDInput
    pre::PreEDInput                     # Pre ED 입력 (클러스터, 비용 등)
    re_blocks::Vector{RenewableBidBlock} # 입찰 블록 목록 (PV_low, PV_mid, PV_high, W_low, W_mid, W_high)
    re_nonbid::Vector{Float64}          # 비입찰 재생발전량 [MW] (길이 = T)
    demand::Vector{Float64}             # 총 수요 [MW] (순수요가 아닌 전체 수요)
end

# ============================================================
# 육지 맞춤형 재생 입찰블록 생성 ─ 6블록 확장 (개선사항 4b)
# ============================================================
"""
    build_mainland_re_blocks(avail_pv, avail_w;
        rho_pv=0.3, rho_w=0.3,
        w_pv=(0.4, 0.3, 0.3), w_w=(0.4, 0.3, 0.3),
        rec_price=80.0, beta=2.0,
        scenario="mixed") -> (Vector{RenewableBidBlock}, Vector{Float64})

육지 맞춤형 6블록 재생에너지 입찰블록을 생성한다.

## 매개변수
- avail_pv, avail_w: 시간대별 태양광/풍력 총가용량 [MW]
- rho_pv, rho_w: 입찰참여율 (0~1)
- w_pv, w_w: Low/Mid/High 블록 분할 비율 (합=1)
- rec_price: REC 평균가격 [원/kWh]
- beta: 하한가 계수 (제주형 2.5, 시나리오 1.5/2.0/2.5)
- scenario: "zero", "floor", "mixed", "conservative"

## 반환
- blocks: RenewableBidBlock 6개 배열
- re_nonbid: 비입찰 재생발전량 벡터
"""
function build_mainland_re_blocks(avail_pv::Vector{Float64},
                                   avail_w::Vector{Float64};
                                   rho_pv::Float64=0.3,
                                   rho_w::Float64=0.3,
                                   w_pv::Tuple{Float64,Float64,Float64}=(0.4, 0.3, 0.3),
                                   w_w::Tuple{Float64,Float64,Float64}=(0.4, 0.3, 0.3),
                                   rec_price::Float64=80.0,
                                   beta::Float64=2.0,
                                   scenario::String="mixed")
    T = length(avail_pv)
    @assert length(avail_w) == T "태양광/풍력 가용량 길이 불일치"

    # (R4) 입찰 하한가: BidFloor = -β × REC
    # REC 단위: 원/kWh → 원/MWh 변환 (×1000)
    bid_floor = -(beta * rec_price * 1000.0)  # 원/MWh

    # 입찰참여분과 비입찰분 분리
    pv_bid_total = rho_pv .* avail_pv
    w_bid_total  = rho_w .* avail_w
    re_nonbid = (1.0 - rho_pv) .* avail_pv .+ (1.0 - rho_w) .* avail_w

    # Low/Mid/High 블록 분할
    pv_low_avail  = w_pv[1] .* pv_bid_total
    pv_mid_avail  = w_pv[2] .* pv_bid_total
    pv_high_avail = w_pv[3] .* pv_bid_total
    w_low_avail   = w_w[1] .* w_bid_total
    w_mid_avail   = w_w[2] .* w_bid_total
    w_high_avail  = w_w[3] .* w_bid_total

    # 시나리오별 가격 부여
    function make_bid(level::Symbol)
        if scenario == "zero"
            return fill(0.0, T)
        elseif scenario == "floor"
            return fill(bid_floor, T)
        elseif scenario == "mixed"
            # Low 블록: 하한가, Mid 블록: 50% 하한가, High 블록: 0원
            if level == :low
                return fill(bid_floor, T)
            elseif level == :mid
                return fill(0.5 * bid_floor, T)
            else
                return fill(0.0, T)
            end
        elseif scenario == "conservative"
            # Low 블록: 50% 하한가, Mid 블록: 25% 하한가, High 블록: 0원
            if level == :low
                return fill(0.5 * bid_floor, T)
            elseif level == :mid
                return fill(0.25 * bid_floor, T)
            else
                return fill(0.0, T)
            end
        else
            error("알 수 없는 시나리오: $scenario")
        end
    end

    blocks = RenewableBidBlock[
        RenewableBidBlock("PV_low",  "solar", pv_low_avail,  make_bid(:low)),
        RenewableBidBlock("PV_mid",  "solar", pv_mid_avail,  make_bid(:mid)),
        RenewableBidBlock("PV_high", "solar", pv_high_avail, make_bid(:high)),
        RenewableBidBlock("W_low",   "wind",  w_low_avail,   make_bid(:low)),
        RenewableBidBlock("W_mid",   "wind",  w_mid_avail,   make_bid(:mid)),
        RenewableBidBlock("W_high",  "wind",  w_high_avail,  make_bid(:high)),
    ]

    return blocks, re_nonbid
end

# ============================================================
# Post-revision ED 풀기 (Dual Pollution 수정 + Piecewise Linear + RE Pmin)
# ============================================================
"""
    solve_post_ed(input::PostEDInput;
                  pw_costs=PiecewiseCost[],
                  re_pmin_frac=0.1) -> PostEDResult

Post-revision ED를 풀고 결과를 반환한다.

## 개선사항 반영
- [개선 5] Curtailment: re_net 변수로 분리 → LP dual 오염 방지
- [개선 2] Piecewise Linear: 구간별 세그먼트 변수 지원
- [개선 4a] RE Pmin: 낙찰 시 최소 re_pmin_frac × avail 공급 의무
"""
function solve_post_ed(input::PostEDInput;
                       pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                       re_pmin_frac::Float64=0.1)
    T = input.pre.base.T
    G = length(input.pre.base.clusters)
    K = length(input.re_blocks)
    clusters = input.pre.base.clusters

    # 총 비용 계수 (Piecewise가 아닌 경우의 폴백용)
    total_mc = input.pre.effective_mc .+ input.pre.price_adder
    use_piecewise = !isempty(pw_costs) && length(pw_costs) == G

    # ── JuMP 모델 ──
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # ── 열발전 변수 (Piecewise Linear 지원) ──
    if use_piecewise
        # 세그먼트별 증분 변수
        max_S = maximum(length(pw.segments) for pw in pw_costs)
        @variable(model, delta[g=1:G, s=1:max_S, t=1:T] >= 0)

        # 세그먼트 상한 제약
        for g in 1:G, t in 1:T
            S_g = length(pw_costs[g].segments)
            for s in 1:S_g
                set_upper_bound(delta[g, s, t], pw_costs[g].segments[s].delta_max)
            end
            # 사용하지 않는 세그먼트는 0으로 고정
            for s in (S_g+1):max_S
                fix(delta[g, s, t], 0.0; force=true)
            end
        end

        # 총 출력 표현식
        @expression(model, p_total[g=1:G, t=1:T],
            pw_costs[g].pmin + sum(delta[g, s, t] for s in 1:length(pw_costs[g].segments))
        )

        # must-run 최소출력 제약
        for g in 1:G, t in 1:T
            if clusters[g].must_run
                @constraint(model, p_total[g, t] >= clusters[g].pmin)
            end
            @constraint(model, p_total[g, t] <= clusters[g].pmax)
        end

        # 램프 제약
        for g in 1:G, t in 2:T
            ru = clusters[g].ramp_up
            rd = clusters[g].ramp_down
            if ru < Inf && ru > 0
                @constraint(model, p_total[g, t] - p_total[g, t-1] <= ru)
            end
            if rd < Inf && rd > 0
                @constraint(model, p_total[g, t-1] - p_total[g, t] <= rd)
            end
        end
    else
        # 기존 단일 변수 방식 (폴백)
        @variable(model, p[g=1:G, t=1:T])

        for g in 1:G, t in 1:T
            if clusters[g].must_run
                set_lower_bound(p[g, t], clusters[g].pmin)
            else
                set_lower_bound(p[g, t], 0.0)
            end
            set_upper_bound(p[g, t], clusters[g].pmax)
        end

        for g in 1:G, t in 2:T
            ru = clusters[g].ramp_up
            rd = clusters[g].ramp_down
            if ru < Inf && ru > 0
                @constraint(model, p[g, t] - p[g, t-1] <= ru)
            end
            if rd < Inf && rd > 0
                @constraint(model, p[g, t-1] - p[g, t] <= rd)
            end
        end

        # p_total은 p와 동일
        @expression(model, p_total[g=1:G, t=1:T], p[g, t])
    end

    # ── 재생 입찰블록 변수 (R3) — RE Pmin 제약 포함 ──
    @variable(model, r[k=1:K, t=1:T] >= 0)

    for k in 1:K, t in 1:T
        avail_kt = max(0.0, input.re_blocks[k].avail[t])
        set_upper_bound(r[k, t], avail_kt)
        # (개선 4a) 제주 규정: 낙찰 시 최소 Pmin 공급 의무
        if re_pmin_frac > 0.0 && avail_kt > 1e-3
            set_lower_bound(r[k, t], re_pmin_frac * avail_kt)
        end
    end

    # ── 비입찰 RE: re_net 변수로 분리 (개선 5: Dual Pollution 방지) ──
    # re_net[t]는 실제 투입되는 비입찰 RE량
    # curtailment = re_nonbid[t] - re_net[t] (사후 계산)
    @variable(model, 0 <= re_net[t=1:T] <= input.re_nonbid[t])

    # (R2) 수급균형: 열발전 + 재생입찰 + 비입찰RE(net) = 총수요
    balance = @constraint(model, [t=1:T],
        sum(p_total[g, t] for g in 1:G) +
        sum(r[k, t] for k in 1:K) +
        re_net[t] == input.demand[t]
    )

    # (R1) 목적함수
    if use_piecewise
        # Piecewise Linear 비용 + Price Adder
        @objective(model, Min,
            sum(pw_costs[g].segments[s].marginal_cost * delta[g, s, t]
                for g in 1:G
                for s in 1:length(pw_costs[g].segments)
                for t in 1:T) +
            sum(input.pre.price_adder[g, t] * p_total[g, t]
                for g in 1:G, t in 1:T) +
            sum(input.re_blocks[k].bid[t] * r[k, t]
                for k in 1:K, t in 1:T)
        )
    else
        @objective(model, Min,
            sum(total_mc[g, t] * p_total[g, t] for g in 1:G, t in 1:T) +
            sum(input.re_blocks[k].bid[t] * r[k, t] for k in 1:K, t in 1:T)
        )
    end

    # ── 최적화 ──
    optimize!(model)

    status = termination_status(model)
    if status != MOI.OPTIMAL
        @error "Post ED 최적화 실패: status = $status"
        base_result = EDResult(T, zeros(G, T), zeros(T), 0.0,
                              [c.name for c in clusters], :INFEASIBLE, zeros(T))
        return PostEDResult(base_result, zeros(K, T),
                           [b.name for b in input.re_blocks], zeros(T))
    end

    # ── 결과 추출 ──
    gen_matrix = zeros(G, T)
    for g in 1:G, t in 1:T
        gen_matrix[g, t] = value(p_total[g, t])
    end

    re_dispatch = zeros(K, T)
    for k in 1:K, t in 1:T
        re_dispatch[k, t] = value(r[k, t])
    end

    # LP dual → SMP (개선 5: curtailment 오염 없으므로 직접 사용)
    smp = zeros(T)
    for t in 1:T
        smp[t] = dual(balance[t])
    end

    # curtailment 사후 계산
    curt = zeros(T)
    for t in 1:T
        curt[t] = input.re_nonbid[t] - value(re_net[t])
    end

    curt_total = sum(curt)
    if curt_total > 1e-3
        curt_hours = count(curt[t] > 1e-3 for t in 1:T)
        @warn "Post ED: 비입찰 재생 출력제한 $(round(curt_total, digits=0)) MWh ($(curt_hours)시간)"
    end

    total_cost = objective_value(model)

    base_result = EDResult(T, gen_matrix, smp, total_cost,
                          [c.name for c in clusters], :OPTIMAL, zeros(T))

    return PostEDResult(base_result, re_dispatch,
                       [b.name for b in input.re_blocks], curt)
end

# ============================================================
# Post ED용 입력 생성 헬퍼
# ============================================================
"""
    make_post_input(pre_input::PreEDInput, avail_pv, avail_w;
                    kwargs...) -> PostEDInput

Pre ED 입력에서 Post ED 입력을 생성.
재생에너지를 입찰/비입찰로 분리하고 블록을 구성.
"""
function make_post_input(pre_input::PreEDInput,
                         avail_pv::Vector{Float64},
                         avail_w::Vector{Float64};
                         rho_pv::Float64=0.3,
                         rho_w::Float64=0.3,
                         rec_price::Float64=80.0,
                         beta::Float64=2.0,
                         scenario::String="mixed",
                         w_pv::Tuple{Float64,Float64,Float64}=(0.4, 0.3, 0.3),
                         w_w::Tuple{Float64,Float64,Float64}=(0.4, 0.3, 0.3))
    blocks, re_nonbid = build_mainland_re_blocks(
        avail_pv, avail_w;
        rho_pv=rho_pv, rho_w=rho_w,
        w_pv=w_pv, w_w=w_w,
        rec_price=rec_price, beta=beta,
        scenario=scenario
    )

    return PostEDInput(pre_input, blocks, re_nonbid, pre_input.base.demand)
end

# ============================================================
# Post-ED SMP 결정 — LP dual 직접 사용 (개선 5)
# ============================================================
"""
    determine_post_smp(post_result::PostEDResult, input::PostEDInput,
                       pre_input::PreEDInput) -> Vector{Float64}

LP dual을 기반으로 Post-model SMP를 결정한다.

## 개선 5 반영
re_net 변수 분리로 curtailment 페널티가 dual에 포함되지 않으므로,
LP dual을 직접 SMP로 사용한다. 별도의 threshold 체크나 폴백 불필요.
"""
function determine_post_smp(post_result::PostEDResult,
                            input::PostEDInput,
                            pre_input::PreEDInput)
    # LP dual이 곧 SMP (curtailment 오염 없음)
    return copy(post_result.base.smp)
end

# ============================================================
# ΔSMP 분석
# ============================================================
"""
    compute_delta_smp(pre_result::EDResult, post_result::PostEDResult) -> Dict

Pre vs Post SMP 차이 분석.
- delta_smp: 시간대별 ΔSMP = SMP_post - SMP_pre
- 양수: Post에서 SMP 상승 (저녁 램프 등)
- 음수: Post에서 SMP 하락 (낮 재생 주입 등)
"""
function compute_delta_smp(pre_result::EDResult, post_result::PostEDResult)
    T = pre_result.T
    delta = post_result.base.smp .- pre_result.smp

    return Dict(
        "delta_smp"    => delta,
        "mean_delta"   => sum(delta) / T,
        "max_decrease" => minimum(delta),  # 최대 하락
        "max_increase" => maximum(delta),  # 최대 상승
        "hours_down"   => count(d -> d < -1e-3, delta),  # SMP 하락 시간 수
        "hours_up"     => count(d -> d > 1e-3, delta),   # SMP 상승 시간 수
        "hours_same"   => count(d -> abs(d) <= 1e-3, delta),
    )
end
