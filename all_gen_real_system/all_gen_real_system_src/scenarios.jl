# ============================================================
# scenarios.jl  ─  4개 시나리오 + β 민감도 분석 + 몬테카를로 + 출력제한 분석
# ============================================================
# 문서 참조: 02_프로젝트_수행 §3.4, mainland_re_bid_blocks §2.3
#
# 시나리오:
#   Case A (zero):         모든 블록 b_{k,t} = 0 원
#   Case B (floor):        모든 블록 b_{k,t} = BidFloor
#   Case C (mixed):        Low = BidFloor, Mid = 0.5×BidFloor, High = 0 원
#   Case D (conservative): Low = 0.5×BidFloor, Mid = 0.25×BidFloor, High = 0 원
#
# β 민감도: 1.5 / 2.0 / 2.5 (하한가 계수)
# 입찰참여율 민감도: ρ = 0.1 / 0.2 / 0.3 / 0.5
# [개선 4c] 몬테카를로: Uniform[BidFloor, 0] 확률적 입찰가
# [개선 6] 출력제한 분석: 시나리오별 curtailment 지표
# ============================================================
# 의존: types.jl, build_pre_ed.jl, build_post_ed.jl (상위에서 include 완료)
# ============================================================

using Printf
using DataFrames
using Statistics
using Random

# ============================================================
# 1. 시나리오 정의
# ============================================================
"""
    ScenarioConfig

시나리오 설정 구조체.
"""
struct ScenarioConfig
    name::String        # 시나리오 이름 (예: "Case_A_zero")
    scenario::String    # build_mainland_re_blocks의 scenario 인자
    beta::Float64       # 하한가 계수
    rho_pv::Float64     # 태양광 입찰참여율
    rho_w::Float64      # 풍력 입찰참여율
    rec_price::Float64  # REC 평균가격 [원/kWh]
end

"""
    default_scenarios(; beta=2.0, rho_pv=0.3, rho_w=0.3, rec_price=80.0) -> Vector{ScenarioConfig}

기본 4개 시나리오 설정을 생성.
"""
function default_scenarios(; beta::Float64=2.0,
                            rho_pv::Float64=0.3,
                            rho_w::Float64=0.3,
                            rec_price::Float64=80.0)
    return ScenarioConfig[
        ScenarioConfig("Case_A_zero",         "zero",         beta, rho_pv, rho_w, rec_price),
        ScenarioConfig("Case_B_floor",        "floor",        beta, rho_pv, rho_w, rec_price),
        ScenarioConfig("Case_C_mixed",        "mixed",        beta, rho_pv, rho_w, rec_price),
        ScenarioConfig("Case_D_conservative", "conservative", beta, rho_pv, rho_w, rec_price),
    ]
end

# ============================================================
# 2. 출력제한 분석 (개선사항 6)
# ============================================================
"""
    analyze_curtailment(curtailment::Vector{Float64},
                        smp::Vector{Float64}) -> CurtailmentAnalysis

출력제한 벡터와 SMP 벡터로 출력제한 분석을 수행.
"""
function analyze_curtailment(curtailment::Vector{Float64},
                              smp::Vector{Float64})
    T = length(curtailment)
    total = sum(curtailment)
    hours = count(c -> c > 1e-3, curtailment)
    max_curt = maximum(curtailment)

    # SMP와의 상관계수 (Pearson)
    # 출력제한이 전혀 없으면 상관계수 계산 불가
    if hours > 1 && std(curtailment) > 1e-6 && std(smp) > 1e-6
        corr = cor(curtailment, smp)
    else
        corr = 0.0
    end

    return CurtailmentAnalysis(total, hours, max_curt, copy(curtailment), corr)
end

# ============================================================
# 3. 시나리오 결과 구조
# ============================================================
"""
    ScenarioResult

단일 시나리오 결과.
"""
struct ScenarioResult
    config::ScenarioConfig
    post_result::PostEDResult
    delta_smp::Dict{String, Any}    # compute_delta_smp 결과
    metrics::ValidationMetrics      # Post SMP vs Pre SMP 비교 (방향성 분석)
    curtailment::CurtailmentAnalysis  # [개선 6] 출력제한 분석
end

# ============================================================
# 4. 시나리오 일괄 실행
# ============================================================
"""
    run_scenarios(pre_input::PreEDInput,
                  pre_result::EDResult,
                  avail_pv::Vector{Float64},
                  avail_w::Vector{Float64};
                  scenarios=nothing,
                  pw_costs=PiecewiseCost[],
                  re_pmin_frac=0.1) -> Vector{ScenarioResult}

설정된 시나리오들을 순차 실행하고 결과를 반환.
"""
function run_scenarios(pre_input::PreEDInput,
                       pre_result::EDResult,
                       avail_pv::Vector{Float64},
                       avail_w::Vector{Float64};
                       scenarios::Union{Nothing, Vector{ScenarioConfig}}=nothing,
                       pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                       re_pmin_frac::Float64=0.1)
    if isnothing(scenarios)
        scenarios = default_scenarios()
    end

    results = ScenarioResult[]

    for (i, sc) in enumerate(scenarios)
        println("  [$i/$(length(scenarios))] 시나리오: $(sc.name)")
        println("    β=$(sc.beta), ρ_PV=$(sc.rho_pv), ρ_W=$(sc.rho_w), scenario=$(sc.scenario)")

        # Post ED 입력 생성
        post_input = make_post_input(
            pre_input, avail_pv, avail_w;
            rho_pv=sc.rho_pv, rho_w=sc.rho_w,
            rec_price=sc.rec_price, beta=sc.beta,
            scenario=sc.scenario
        )

        # Post ED 풀기
        post_result = solve_post_ed(post_input;
                                     pw_costs=pw_costs,
                                     re_pmin_frac=re_pmin_frac)

        if post_result.base.status != :OPTIMAL
            @warn "  시나리오 $(sc.name) 실패"
            continue
        end

        # LP dual 기반 Post SMP (개선 5: 오염 없음)
        post_smp = determine_post_smp(post_result, post_input, pre_input)

        # SMP가 반영된 PostEDResult 재구성
        adjusted_base = EDResult(
            post_result.base.T,
            post_result.base.generation,
            post_smp,
            post_result.base.total_cost,
            post_result.base.cluster_names,
            post_result.base.status,
            post_result.base.curtailment
        )
        adjusted_post = PostEDResult(adjusted_base, post_result.re_dispatch,
                                     post_result.re_block_names, post_result.curtailment)

        # ΔSMP 분석
        delta = compute_delta_smp(pre_result, adjusted_post)

        # Post SMP 검증지표 (Pre SMP 대비)
        metrics = compute_metrics(adjusted_post.base.smp, pre_result.smp)

        # [개선 6] 출력제한 분석
        curt_analysis = analyze_curtailment(adjusted_post.curtailment, adjusted_post.base.smp)

        push!(results, ScenarioResult(sc, adjusted_post, delta, metrics, curt_analysis))

        @printf("    → 평균 ΔSMP: %+.0f 원/MWh, 하락 %d시간, 상승 %d시간\n",
                delta["mean_delta"], delta["hours_down"], delta["hours_up"])
        if curt_analysis.total_mwh > 1e-3
            @printf("    → 출력제한: %.0f MWh (%d시간)\n",
                    curt_analysis.total_mwh, curt_analysis.hours)
        end
    end

    return results
end

# ============================================================
# 5. β 민감도 분석
# ============================================================
"""
    run_beta_sensitivity(pre_input, pre_result, avail_pv, avail_w;
                         betas=[1.5, 2.0, 2.5],
                         scenario="mixed",
                         rho_pv=0.3, rho_w=0.3,
                         rec_price=80.0,
                         pw_costs=PiecewiseCost[],
                         re_pmin_frac=0.1) -> Vector{ScenarioResult}

β(하한가 계수) 민감도 분석을 수행.
동일 시나리오(예: mixed)에서 β만 변경하여 효과를 비교.
"""
function run_beta_sensitivity(pre_input::PreEDInput,
                               pre_result::EDResult,
                               avail_pv::Vector{Float64},
                               avail_w::Vector{Float64};
                               betas::Vector{Float64}=[1.5, 2.0, 2.5],
                               scenario::String="mixed",
                               rho_pv::Float64=0.3,
                               rho_w::Float64=0.3,
                               rec_price::Float64=80.0,
                               pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                               re_pmin_frac::Float64=0.1)
    configs = ScenarioConfig[
        ScenarioConfig("beta_$(b)_$(scenario)", scenario, b, rho_pv, rho_w, rec_price)
        for b in betas
    ]

    return run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                         scenarios=configs, pw_costs=pw_costs,
                         re_pmin_frac=re_pmin_frac)
end

# ============================================================
# 6. 입찰참여율 민감도 분석
# ============================================================
"""
    run_rho_sensitivity(pre_input, pre_result, avail_pv, avail_w;
                        rhos=[0.1, 0.2, 0.3, 0.5],
                        scenario="mixed", beta=2.0, rec_price=80.0,
                        pw_costs=PiecewiseCost[],
                        re_pmin_frac=0.1) -> Vector{ScenarioResult}

입찰참여율(ρ) 민감도 분석.
태양광과 풍력에 동일한 ρ를 적용.
"""
function run_rho_sensitivity(pre_input::PreEDInput,
                              pre_result::EDResult,
                              avail_pv::Vector{Float64},
                              avail_w::Vector{Float64};
                              rhos::Vector{Float64}=[0.1, 0.2, 0.3, 0.5],
                              scenario::String="mixed",
                              beta::Float64=2.0,
                              rec_price::Float64=80.0,
                              pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                              re_pmin_frac::Float64=0.1)
    configs = ScenarioConfig[
        ScenarioConfig("rho_$(r)_$(scenario)", scenario, beta, r, r, rec_price)
        for r in rhos
    ]

    return run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                         scenarios=configs, pw_costs=pw_costs,
                         re_pmin_frac=re_pmin_frac)
end

# ============================================================
# 7. 몬테카를로 시뮬레이션 (개선사항 4c)
# ============================================================
"""
    run_monte_carlo_scenarios(pre_input, pre_result, avail_pv, avail_w;
        n_samples=100, beta=2.0, rec_price=80.0,
        rho_pv=0.3, rho_w=0.3, seed=42,
        pw_costs=PiecewiseCost[],
        re_pmin_frac=0.1) -> MonteCarloResult

확률적 입찰가 분포에서 몬테카를로 시뮬레이션을 수행.

각 샘플에서 블록별 입찰가를 Uniform[BidFloor, 0]에서 독립 추출.
사업자별 입찰 전략의 이질성을 확률적으로 반영.
"""
function run_monte_carlo_scenarios(pre_input::PreEDInput,
                                    pre_result::EDResult,
                                    avail_pv::Vector{Float64},
                                    avail_w::Vector{Float64};
                                    n_samples::Int=100,
                                    beta::Float64=2.0,
                                    rec_price::Float64=80.0,
                                    rho_pv::Float64=0.3,
                                    rho_w::Float64=0.3,
                                    seed::Int=42,
                                    pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                                    re_pmin_frac::Float64=0.1)
    T = pre_input.base.T
    rng = MersenneTwister(seed)

    bid_floor = -(beta * rec_price * 1000.0)

    # 입찰/비입찰 분리 (한번만 계산)
    pv_bid_total = rho_pv .* avail_pv
    w_bid_total  = rho_w .* avail_w
    re_nonbid = (1.0 - rho_pv) .* avail_pv .+ (1.0 - rho_w) .* avail_w

    # 6블록 가용량 (고정)
    w_pv = (0.4, 0.3, 0.3)
    w_w  = (0.4, 0.3, 0.3)

    block_avails = [
        ("PV_low",  "solar", w_pv[1] .* pv_bid_total),
        ("PV_mid",  "solar", w_pv[2] .* pv_bid_total),
        ("PV_high", "solar", w_pv[3] .* pv_bid_total),
        ("W_low",   "wind",  w_w[1] .* w_bid_total),
        ("W_mid",   "wind",  w_w[2] .* w_bid_total),
        ("W_high",  "wind",  w_w[3] .* w_bid_total),
    ]

    all_smp = zeros(n_samples, T)
    all_curt = zeros(n_samples, T)
    success_count = 0

    println("  몬테카를로 시뮬레이션: $(n_samples)회 샘플링 시작")

    for s in 1:n_samples
        # 블록별 랜덤 입찰가: Uniform[bid_floor, 0]
        blocks = RenewableBidBlock[]
        for (name, tech, avail) in block_avails
            bid_price = rand(rng) * (-bid_floor) + bid_floor  # U[bid_floor, 0]
            push!(blocks, RenewableBidBlock(name, tech, avail, fill(bid_price, T)))
        end

        post_input = PostEDInput(pre_input, blocks, re_nonbid, pre_input.base.demand)
        post_result = solve_post_ed(post_input; pw_costs=pw_costs, re_pmin_frac=re_pmin_frac)

        if post_result.base.status == :OPTIMAL
            success_count += 1
            all_smp[s, :] = post_result.base.smp
            all_curt[s, :] = post_result.curtailment
        end

        if s % 25 == 0
            println("    [$s/$n_samples] 완료")
        end
    end

    if success_count == 0
        @warn "몬테카를로: 모든 샘플 실패"
        return MonteCarloResult(0, zeros(T), zeros(T), zeros(T), 0.0, zeros(0, T), zeros(T))
    end

    # 유효 샘플만 추출
    valid_smp = all_smp[1:success_count, :]
    valid_curt = all_curt[1:success_count, :]

    mean_smp_vec = vec(mean(valid_smp, dims=1))
    p5_smp  = [quantile(valid_smp[:, t], 0.05) for t in 1:T]
    p95_smp = [quantile(valid_smp[:, t], 0.95) for t in 1:T]
    mean_delta = mean(mean_smp_vec .- pre_result.smp)
    mean_curt_vec = vec(mean(valid_curt, dims=1))

    println("  ✓ 몬테카를로 완료: $(success_count)/$(n_samples) 성공")
    @printf("    → 평균 ΔSMP: %+.0f 원/MWh\n", mean_delta)
    @printf("    → SMP 범위 (5th-95th): %.0f ~ %.0f 원/MWh\n",
            minimum(p5_smp), maximum(p95_smp))

    return MonteCarloResult(success_count, mean_smp_vec, p5_smp, p95_smp,
                            mean_delta, valid_smp, mean_curt_vec)
end

# ============================================================
# 8. 결과 요약 테이블 생성 (출력제한 포함)
# ============================================================
"""
    scenario_summary_table(results::Vector{ScenarioResult}) -> DataFrame

시나리오 결과를 요약 DataFrame으로 정리.
[개선 6] 출력제한 지표 컬럼 추가.
"""
function scenario_summary_table(results::Vector{ScenarioResult})
    rows = []
    for r in results
        push!(rows, (
            scenario = r.config.name,
            beta = r.config.beta,
            rho_pv = r.config.rho_pv,
            rho_w = r.config.rho_w,
            bid_mode = r.config.scenario,
            mean_smp_post = mean(r.post_result.base.smp),
            mean_delta_smp = r.delta_smp["mean_delta"],
            max_decrease = r.delta_smp["max_decrease"],
            max_increase = r.delta_smp["max_increase"],
            hours_down = r.delta_smp["hours_down"],
            hours_up = r.delta_smp["hours_up"],
            total_re_bid_MWh = sum(r.post_result.re_dispatch),
            total_cost = r.post_result.base.total_cost,
            # [개선 6] 출력제한 지표
            curtailment_MWh = r.curtailment.total_mwh,
            curtailment_hours = r.curtailment.hours,
            max_curtailment_MW = r.curtailment.max_mw,
            smp_curt_corr = r.curtailment.smp_correlation,
        ))
    end
    return DataFrame(rows)
end

# ============================================================
# 9. Pre vs Post 출력제한 비교 (개선사항 6)
# ============================================================
"""
    compare_pre_post_curtailment(pre_result::EDResult,
                                 scenario_results::Vector{ScenarioResult}) -> DataFrame

Pre-ED와 Post-ED의 출력제한을 비교하는 요약 테이블.
입찰제 도입이 출력제한을 줄이는 효과 분석.
"""
function compare_pre_post_curtailment(pre_result::EDResult,
                                       scenario_results::Vector{ScenarioResult})
    pre_curt_total = sum(pre_result.curtailment)
    pre_curt_hours = count(c -> c > 1e-3, pre_result.curtailment)

    rows = [(
        scenario = "Pre (baseline)",
        curtailment_MWh = pre_curt_total,
        curtailment_hours = pre_curt_hours,
        reduction_pct = 0.0,
    )]

    for r in scenario_results
        post_curt = r.curtailment.total_mwh
        reduction = pre_curt_total > 1e-3 ? (1.0 - post_curt / pre_curt_total) * 100.0 : 0.0
        push!(rows, (
            scenario = r.config.name,
            curtailment_MWh = post_curt,
            curtailment_hours = r.curtailment.hours,
            reduction_pct = reduction,
        ))
    end

    return DataFrame(rows)
end

# ============================================================
# 10. 시나리오 결과 출력
# ============================================================
"""
    print_scenario_summary(results::Vector{ScenarioResult}, pre_result::EDResult)

시나리오 비교 결과를 표 형태로 출력.
"""
function print_scenario_summary(results::Vector{ScenarioResult}, pre_result::EDResult)
    println("\n  ┌─ 시나리오 비교 요약 ─────────────────────────────────────────────────────────────────┐")
    @printf("  │ %-22s │ %10s │ %10s │ %10s │ %6s │ %6s │ %10s │\n",
            "Scenario", "Mean SMP", "ΔSMP avg", "ΔSMP max↓", "Hrs↓", "Hrs↑", "Curt(MWh)")
    println("  ├────────────────────────┼────────────┼────────────┼────────────┼────────┼────────┼────────────┤")

    pre_mean = mean(pre_result.smp)
    pre_curt = sum(pre_result.curtailment)
    @printf("  │ %-22s │ %10.0f │ %10s │ %10s │ %6s │ %6s │ %10.0f │\n",
            "Pre (baseline)", pre_mean, "-", "-", "-", "-", pre_curt)

    for r in results
        @printf("  │ %-22s │ %10.0f │ %+10.0f │ %10.0f │ %6d │ %6d │ %10.0f │\n",
                r.config.name,
                mean(r.post_result.base.smp),
                r.delta_smp["mean_delta"],
                r.delta_smp["max_decrease"],
                r.delta_smp["hours_down"],
                r.delta_smp["hours_up"],
                r.curtailment.total_mwh)
    end
    println("  └────────────────────────┴────────────┴────────────┴────────────┴────────┴────────┴────────────┘")
end
