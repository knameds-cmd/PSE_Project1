# ============================================================
# scenarios.jl  ─  4개 시나리오 + β/ρ 민감도 + 몬테카를로 + 출력제한 분석
# ============================================================
# v2: §2.3 BidderType mixture, §3 Case_A_zero=ρ=0 baseline,
#     §6 Beta(α,β) mixture + common shock MC
# ============================================================
# 의존: types.jl, build_pre_ed.jl, build_post_ed.jl (상위에서 include 완료)
# ============================================================

using Printf
using DataFrames
using Statistics
using Random
using Distributions

# ============================================================
# 1. 시나리오 정의
# ============================================================
struct ScenarioConfig
    name::String
    scenario::String
    beta::Float64
    rho_pv::Float64
    rho_w::Float64
    rec_price::Float64
end

"""
§3 — Case_A_zero 는 입찰참여 자체가 없는(ρ=0) baseline.
"""
function default_scenarios(; beta::Float64=2.0,
                            rho_pv::Float64=0.3,
                            rho_w::Float64=0.3,
                            rec_price::Float64=80.0)
    return ScenarioConfig[
        ScenarioConfig("Case_A_zero",         "zero",         beta, 0.0,    0.0,   rec_price),
        ScenarioConfig("Case_B_floor",        "floor",        beta, rho_pv, rho_w, rec_price),
        ScenarioConfig("Case_C_mixed",        "mixed",        beta, rho_pv, rho_w, rec_price),
        ScenarioConfig("Case_D_conservative", "conservative", beta, rho_pv, rho_w, rec_price),
    ]
end

# ============================================================
# 1.1 Bidder Types — §2.3
# ============================================================
function default_bidder_types()
    return BidderType[
        BidderType("aggressive",   0.30, (2.0, 5.0), (0.6, 0.3, 0.1)),
        BidderType("moderate",     0.40, (3.0, 3.0), (0.4, 0.4, 0.2)),
        BidderType("conservative", 0.20, (5.0, 2.0), (0.2, 0.4, 0.4)),
        BidderType("PPA_locked",   0.10, (8.0, 1.5), (0.1, 0.3, 0.6)),
    ]
end

const POLICY_PENETRATION_SCENARIOS = Dict{String, NTuple{4,Float64}}(
    "S1_Early"      => (0.50, 0.30, 0.15, 0.05),
    "S2_Mature"     => (0.30, 0.40, 0.20, 0.10),
    "S3_Aggressive" => (0.15, 0.35, 0.30, 0.20),
)

function bidder_types_for_scenario(name::String)
    haskey(POLICY_PENETRATION_SCENARIOS, name) ||
        error("Unknown policy penetration scenario: $name. " *
              "Choices: $(collect(keys(POLICY_PENETRATION_SCENARIOS)))")
    shares = POLICY_PENETRATION_SCENARIOS[name]
    base = default_bidder_types()
    return BidderType[
        BidderType(base[i].name, shares[i], base[i].beta_dist, base[i].w_blocks)
        for i in 1:length(base)
    ]
end

# ============================================================
# 2. 출력제한 분석
# ============================================================
function analyze_curtailment(curtailment::Vector{Float64},
                              smp::Vector{Float64})
    T = length(curtailment)
    total = sum(curtailment)
    hours = count(c -> c > 1e-3, curtailment)
    max_curt = maximum(curtailment)

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
struct ScenarioResult
    config::ScenarioConfig
    post_result::PostEDResult
    delta_smp::Dict{String, Any}
    metrics::ValidationMetrics
    curtailment::CurtailmentAnalysis
end

# ============================================================
# 4. 시나리오 일괄 실행
# ============================================================
function run_scenarios(pre_input::PreEDInput,
                       pre_result::EDResult,
                       avail_pv::Vector{Float64},
                       avail_w::Vector{Float64};
                       scenarios::Union{Nothing, Vector{ScenarioConfig}}=nothing,
                       pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                       re_pmin_frac::Float64=0.1,
                       installed_pv::Float64=0.0,
                       installed_w::Float64=0.0,
                       epsilon_nonbid::Float64=100.0)
    if isnothing(scenarios)
        scenarios = default_scenarios()
    end

    results = ScenarioResult[]

    for (i, sc) in enumerate(scenarios)
        println("  [$i/$(length(scenarios))] 시나리오: $(sc.name)")
        println("    β=$(sc.beta), ρ_PV=$(sc.rho_pv), ρ_W=$(sc.rho_w), scenario=$(sc.scenario)")

        # §3: Case_A_zero (ρ=0) → bidding 비활성
        is_zero_case = (sc.rho_pv == 0.0 && sc.rho_w == 0.0)

        post_input = make_post_input(
            pre_input, avail_pv, avail_w;
            rho_pv=sc.rho_pv, rho_w=sc.rho_w,
            rec_price=sc.rec_price, beta=sc.beta,
            scenario=sc.scenario,
            installed_pv=installed_pv, installed_w=installed_w,
        )

        post_result = solve_post_ed(post_input;
                                     pw_costs=pw_costs,
                                     re_pmin_frac=re_pmin_frac,
                                     epsilon_nonbid=epsilon_nonbid,
                                     bidding_active=!is_zero_case)

        if post_result.base.status != :OPTIMAL
            @warn "  시나리오 $(sc.name) 실패"
            continue
        end

        post_smp = determine_post_smp(post_result, post_input, pre_input)

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

        delta = compute_delta_smp(pre_result, adjusted_post)
        metrics = compute_metrics(adjusted_post.base.smp, pre_result.smp)
        curt_analysis = analyze_curtailment(adjusted_post.curtailment, adjusted_post.base.smp)

        push!(results, ScenarioResult(sc, adjusted_post, delta, metrics, curt_analysis))

        @printf("    → 평균 ΔSMP: %+.0f 원/MWh, 하락 %d시간, 상승 %d시간\n",
                delta["mean_delta"], delta["hours_down"], delta["hours_up"])
        if curt_analysis.total_mwh > 1e-3
            @printf("    → 출력제한: %.0f MWh (%d시간)\n",
                    curt_analysis.total_mwh, curt_analysis.hours)
        end

        # §11 sanity check: Case_A_zero → Pre-ED 와 SMP 동치
        if is_zero_case
            max_dev = maximum(abs.(adjusted_post.base.smp .- pre_result.smp))
            if max_dev > 1.0
                @warn "[Compatibility check] Case_A_zero 의 SMP 가 Pre-ED 와 " *
                      "$(round(max_dev, digits=2)) 원/MWh 차이 — bidding=off 경로 점검 필요"
            else
                println("    ✓ baseline 일치 검증: max|SMP_post_A − SMP_pre| = " *
                        "$(round(max_dev, digits=4)) 원/MWh")
            end
        end
    end

    return results
end

# ============================================================
# 5. β 민감도 분석
# ============================================================
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
                               re_pmin_frac::Float64=0.1,
                               installed_pv::Float64=0.0,
                               installed_w::Float64=0.0)
    configs = ScenarioConfig[
        ScenarioConfig("beta_$(b)_$(scenario)", scenario, b, rho_pv, rho_w, rec_price)
        for b in betas
    ]

    return run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                         scenarios=configs, pw_costs=pw_costs,
                         re_pmin_frac=re_pmin_frac,
                         installed_pv=installed_pv, installed_w=installed_w)
end

# ============================================================
# 6. 입찰참여율 민감도 분석
# ============================================================
function run_rho_sensitivity(pre_input::PreEDInput,
                              pre_result::EDResult,
                              avail_pv::Vector{Float64},
                              avail_w::Vector{Float64};
                              rhos::Vector{Float64}=[0.1, 0.2, 0.3, 0.5],
                              scenario::String="mixed",
                              beta::Float64=2.0,
                              rec_price::Float64=80.0,
                              pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                              re_pmin_frac::Float64=0.1,
                              installed_pv::Float64=0.0,
                              installed_w::Float64=0.0)
    configs = ScenarioConfig[
        ScenarioConfig("rho_$(r)_$(scenario)", scenario, beta, r, r, rec_price)
        for r in rhos
    ]

    return run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                         scenarios=configs, pw_costs=pw_costs,
                         re_pmin_frac=re_pmin_frac,
                         installed_pv=installed_pv, installed_w=installed_w)
end

# ============================================================
# 7. 몬테카를로 시뮬레이션 — §6 Beta mixture + common shock
# ============================================================
function run_monte_carlo_scenarios(pre_input::PreEDInput,
                                    pre_result::EDResult,
                                    avail_pv::Vector{Float64},
                                    avail_w::Vector{Float64};
                                    n_samples::Int=200,
                                    beta::Float64=2.0,
                                    rec_price::Float64=80.0,
                                    rho_pv::Float64=0.3,
                                    rho_w::Float64=0.3,
                                    bidder_types::Union{Nothing, Vector{BidderType}}=nothing,
                                    common_shock_sd::Float64=0.10,
                                    installed_pv::Float64=0.0,
                                    installed_w::Float64=0.0,
                                    seed::Int=42,
                                    pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                                    re_pmin_frac::Float64=0.1,
                                    epsilon_nonbid::Float64=100.0)
    T = pre_input.base.T
    rng = MersenneTwister(seed)

    if isnothing(bidder_types)
        bidder_types = default_bidder_types()
    end
    J = length(bidder_types)
    bid_floor = -(beta * rec_price * 1000.0)
    abs_floor = -bid_floor

    # block-level normalization weights
    norm_w  = NTuple{3,Float64}((
        sum(bt.share * bt.w_blocks[1] for bt in bidder_types),
        sum(bt.share * bt.w_blocks[2] for bt in bidder_types),
        sum(bt.share * bt.w_blocks[3] for bt in bidder_types),
    ))

    pv_bid_total = rho_pv .* avail_pv
    w_bid_total  = rho_w  .* avail_w
    re_nonbid = (1.0 - rho_pv) .* avail_pv .+ (1.0 - rho_w) .* avail_w

    w_pv = (0.4, 0.3, 0.3)
    w_w  = (0.4, 0.3, 0.3)

    block_avails = [
        ("PV_low",  "solar", w_pv[1] .* pv_bid_total, w_pv[1] * rho_pv * installed_pv, :low),
        ("PV_mid",  "solar", w_pv[2] .* pv_bid_total, w_pv[2] * rho_pv * installed_pv, :mid),
        ("PV_high", "solar", w_pv[3] .* pv_bid_total, w_pv[3] * rho_pv * installed_pv, :high),
        ("W_low",   "wind",  w_w[1]  .* w_bid_total,  w_w[1]  * rho_w  * installed_w,  :low),
        ("W_mid",   "wind",  w_w[2]  .* w_bid_total,  w_w[2]  * rho_w  * installed_w,  :mid),
        ("W_high",  "wind",  w_w[3]  .* w_bid_total,  w_w[3]  * rho_w  * installed_w,  :high),
    ]

    beta_dists = [Beta(bt.beta_dist[1], bt.beta_dist[2]) for bt in bidder_types]
    shock_dist = Normal(1.0, common_shock_sd)

    all_smp  = zeros(n_samples, T)
    all_curt = zeros(n_samples, T)
    success_count = 0

    println("  몬테카를로 시뮬레이션 (Beta mixture + common shock): " *
            "$(n_samples)회 샘플링 시작")

    for s in 1:n_samples
        u = [rand(rng, beta_dists[j]) for j in 1:J]
        kappa = max(0.0, rand(rng, shock_dist))

        u_blk = zeros(3)
        for blk in 1:3
            num = 0.0
            for j in 1:J
                num += bidder_types[j].share * bidder_types[j].w_blocks[blk] * u[j]
            end
            u_blk[blk] = norm_w[blk] > 0 ? num / norm_w[blk] : 0.0
        end

        b_blk = NTuple{3,Float64}((
            clamp(kappa * (u_blk[1] - 1.0) * abs_floor, bid_floor, 0.0),
            clamp(kappa * (u_blk[2] - 1.0) * abs_floor, bid_floor, 0.0),
            clamp(kappa * (u_blk[3] - 1.0) * abs_floor, bid_floor, 0.0),
        ))

        blocks = RenewableBidBlock[]
        for (name, tech, avail, inst, lvl) in block_avails
            bid_t = lvl == :low  ? b_blk[1] :
                    lvl == :mid  ? b_blk[2] : b_blk[3]
            push!(blocks, RenewableBidBlock(name, tech, avail, fill(bid_t, T), inst))
        end

        post_input = PostEDInput(pre_input, blocks, re_nonbid, pre_input.base.demand)
        post_result = solve_post_ed(post_input;
                                     pw_costs=pw_costs,
                                     re_pmin_frac=re_pmin_frac,
                                     epsilon_nonbid=epsilon_nonbid,
                                     bidding_active=true)

        if post_result.base.status == :OPTIMAL
            success_count += 1
            all_smp[s, :]  = post_result.base.smp
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

    valid_smp  = all_smp[1:success_count, :]
    valid_curt = all_curt[1:success_count, :]

    mean_smp_vec = vec(mean(valid_smp, dims=1))
    p5_smp   = [quantile(valid_smp[:, t], 0.05) for t in 1:T]
    p95_smp  = [quantile(valid_smp[:, t], 0.95) for t in 1:T]
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
# 8. 결과 요약 테이블 생성
# ============================================================
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
            curtailment_MWh = r.curtailment.total_mwh,
            curtailment_hours = r.curtailment.hours,
            max_curtailment_MW = r.curtailment.max_mw,
            smp_curt_corr = r.curtailment.smp_correlation,
        ))
    end
    return DataFrame(rows)
end

# ============================================================
# 9. Pre vs Post 출력제한 비교
# ============================================================
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
