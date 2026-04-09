# ============================================================
# build_pre_ed.jl  ─  Pre-revision Economic Dispatch 모델
# ============================================================
# 수식 참조: 보고서용 수식정리본 §3 (Pre-revision ED)
#
# (P1) 유효 한계비용: c̃_{g,t} = HR_g × FuelPrice_{f,m} + VOM_g + A_{g,s,h}
# (P2) 목적함수:  min Σ_t Σ_g  c̃_{g,t} · p_{g,t}
# (P3) 수급균형:  Σ_g p_{g,t} = D_t - RE_t              ∀t
# (P4) 출력제약:  P_g^min ≤ p_{g,t} ≤ P_g^max           ∀g,t
# (P5) 램프제약:  -RD_g ≤ p_{g,t} - p_{g,t-1} ≤ RU_g    ∀g, t≥2
#
# Basic ED와의 차이:
# - 유효 한계비용 (시간가변, 열소비율×연료비+VOM+price_adder)
# - 최소출력 제약
# - 시간간 램프 제약
# - must-run 강제 (pmin 이상 보장)
# - [개선 2] Piecewise Linear 비용함수 지원
# ============================================================
# 의존: types.jl (상위에서 include 완료)
# ============================================================

using JuMP
using HiGHS
import MathOptInterface as MOI

# ============================================================
# Pre-revision ED 입력 확장 구조
# ============================================================
"""
    PreEDInput

Pre-revision ED 전용 입력.
EDInput + 유효 한계비용 행렬 + price adder.
"""
struct PreEDInput
    base::EDInput                       # 기본 입력 (T, demand, re_generation, clusters)
    effective_mc::Matrix{Float64}       # 유효 한계비용 [G × T] (원/MWh)
    price_adder::Matrix{Float64}        # price adder [G × T] (원/MWh), calibration에서 추정
end

# ============================================================
# Pre-revision ED 풀기 (Piecewise Linear 지원)
# ============================================================
"""
    solve_pre_ed(input::PreEDInput; pw_costs=PiecewiseCost[]) -> EDResult

Pre-revision ED를 풀고 결과를 반환한다.

## Basic ED 대비 추가사항
1. 유효 한계비용 c̃_{g,t} = effective_mc[g,t] + price_adder[g,t]
2. 최소출력 제약: p_{g,t} ≥ P_g^min  (must_run인 경우 강제)
3. 램프 제약: |p_{g,t} - p_{g,t-1}| ≤ ramp limit
4. must-run: pmin 이상 강제 발전
5. [개선 2] Piecewise Linear 비용함수 (pw_costs 제공 시)
"""
function solve_pre_ed(input::PreEDInput;
                      pw_costs::Vector{PiecewiseCost}=PiecewiseCost[])
    T = input.base.T
    G = length(input.base.clusters)
    clusters = input.base.clusters

    use_piecewise = !isempty(pw_costs) && length(pw_costs) == G

    # 순수요 계산 (RE를 음의 부하로 처리)
    # 현행 시장: 초과공급 시 RE 출력제한(curtailment) 명령이 발동되므로
    # net_demand >= must_run_pmin 을 보장하도록 RE를 사전 cap
    must_run_min = sum(c.pmin for c in clusters if c.must_run)
    effective_re = copy(input.base.re_generation)
    re_curtailed = zeros(T)
    for t in 1:T
        max_re = input.base.demand[t] - must_run_min
        if effective_re[t] > max_re && max_re > 0
            re_curtailed[t] = effective_re[t] - max_re
            effective_re[t] = max_re
        elseif max_re <= 0
            re_curtailed[t] = effective_re[t]
            effective_re[t] = 0.0
        end
    end
    curt_total = sum(re_curtailed)
    if curt_total > 1e-3
        curt_hours = count(re_curtailed[t] > 1e-3 for t in 1:T)
        @warn "Pre ED: RE 출력제한 $(round(curt_total, digits=0)) MWh ($(curt_hours)시간, 현행 출력제한 명령 반영)"
    end

    net_demand = input.base.demand .- effective_re
    for t in 1:T
        if net_demand[t] < 0.0
            net_demand[t] = 0.0
        end
    end

    # 총 비용 계수: 유효 한계비용 + price adder (Piecewise 미사용 시)
    total_mc = input.effective_mc .+ input.price_adder  # [G × T]

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
        # 기존 단일 변수 방식
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

        @expression(model, p_total[g=1:G, t=1:T], p[g, t])
    end

    # (P3) 수급균형
    balance = @constraint(model, [t=1:T],
        sum(p_total[g, t] for g in 1:G) == net_demand[t]
    )

    # (P2) 목적함수
    if use_piecewise
        @objective(model, Min,
            sum(pw_costs[g].segments[s].marginal_cost * delta[g, s, t]
                for g in 1:G
                for s in 1:length(pw_costs[g].segments)
                for t in 1:T) +
            sum(input.price_adder[g, t] * p_total[g, t]
                for g in 1:G, t in 1:T)
        )
    else
        @objective(model, Min,
            sum(total_mc[g, t] * p_total[g, t] for g in 1:G, t in 1:T)
        )
    end

    # ── 최적화 ──
    optimize!(model)

    status = termination_status(model)
    if status != MOI.OPTIMAL
        @error "Pre ED 최적화 실패: status = $status"

        total_pmin = sum(c.pmin for c in clusters)
        min_net = minimum(net_demand)
        @error "  진단: must-run pmin합=$must_run_min, 전체 pmin합=$total_pmin, 최소 순수요=$min_net"

        return EDResult(T, zeros(G, T), zeros(T), 0.0,
                       [c.name for c in clusters], :INFEASIBLE, zeros(T))
    end

    # ── 결과 추출 ──
    gen_matrix = zeros(G, T)
    for g in 1:G, t in 1:T
        gen_matrix[g, t] = value(p_total[g, t])
    end

    smp = zeros(T)
    for t in 1:T
        smp[t] = dual(balance[t])
    end

    total_cost = objective_value(model)

    return EDResult(T, gen_matrix, smp, total_cost,
                   [c.name for c in clusters], :OPTIMAL, re_curtailed)
end

# ============================================================
# Pre ED용 더미 입력 생성
# ============================================================
"""
    make_pre_input(base_input::EDInput;
                   fuel_prices=nothing,
                   adder=nothing) -> PreEDInput

Basic ED의 EDInput을 Pre ED 입력으로 확장.
- fuel_prices: Dict(fuel => 원/Gcal). 없으면 기본값 사용.
- adder: [G × T] price adder 행렬. 없으면 0으로 초기화 (calibration 전).
"""
function make_pre_input(base_input::EDInput;
                        fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing,
                        adder::Union{Nothing, Matrix{Float64}}=nothing)
    T = base_input.T
    G = length(base_input.clusters)

    # 유효 한계비용 계산
    if isnothing(fuel_prices)
        fuel_prices = default_fuel_prices()
    end
    mc_matrix = build_effective_mc_matrix(base_input.clusters, fuel_prices, T)

    # Price adder (초기값: 0)
    if isnothing(adder)
        adder = zeros(G, T)
    end

    return PreEDInput(base_input, mc_matrix, adder)
end

# ============================================================
# Pre ED 전용 한계연료원 식별
# ============================================================
"""
    identify_marginal_fuel_pre(result::EDResult, input::PreEDInput) -> Vector{String}

Pre ED에서의 한계연료원 식별.
유효 한계비용 기준으로 판별 (Basic ED의 marginal_cost 대신).
"""
function identify_marginal_fuel_pre(result::EDResult, input::PreEDInput)
    T = result.T
    G = length(input.base.clusters)
    total_mc = input.effective_mc .+ input.price_adder
    marginal_fuels = Vector{String}(undef, T)

    for t in 1:T
        marginal_g = 0
        marginal_cost = -Inf

        for g in 1:G
            gen = result.generation[g, t]
            pmax = input.base.clusters[g].pmax
            pmin = input.base.clusters[g].must_run ? input.base.clusters[g].pmin : 0.0

            # 부분 투입 (pmin < gen < pmax)
            if gen > pmin + 1e-3 && gen < pmax - 1e-3
                if total_mc[g, t] > marginal_cost
                    marginal_cost = total_mc[g, t]
                    marginal_g = g
                end
            end
        end

        # fallback: 투입된 클러스터 중 최고 유효비용
        if marginal_g == 0
            for g in 1:G
                pmin = input.base.clusters[g].must_run ? input.base.clusters[g].pmin : 0.0
                if result.generation[g, t] > pmin + 1e-3
                    if total_mc[g, t] > marginal_cost
                        marginal_cost = total_mc[g, t]
                        marginal_g = g
                    end
                end
            end
        end

        marginal_fuels[t] = marginal_g > 0 ? input.base.clusters[marginal_g].fuel : "none"
    end

    return marginal_fuels
end
