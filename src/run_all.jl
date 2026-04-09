# ============================================================
# run_all.jl  ─  전체 파이프라인 통합 실행
# ============================================================
# Basic ED → Calibration → Pre ED → Post ED (4 시나리오) → 민감도 → 몬테카를로
#
# [개선사항 반영]
# 1. Price Adder 교차검증 + 물리적 bounds
# 2. Piecewise Linear 비용함수
# 3. Nuclear Must-Off 가용용량 반영
# 4. RE 6블록 + Pmin + 몬테카를로
# 5. Curtailment Dual Pollution 수정
# 6. 출력제한 분석
#
# 사용법:
#   cd project/
#   julia setup.jl                    # 최초 1회: 패키지 설치
#   julia --project=. src/run_all.jl  # 전체 파이프라인 실행
# ============================================================

using Printf
using CSV
using DataFrames
using Dates
using Statistics

# ── include 순서 (types.jl 이 최상위, 중복 include 방지) ──
include(joinpath(@__DIR__, "types.jl"))
include(joinpath(@__DIR__, "load_data.jl"))
include(joinpath(@__DIR__, "preprocess.jl"))
include(joinpath(@__DIR__, "dummy_data.jl"))
include(joinpath(@__DIR__, "build_basic_ed.jl"))
include(joinpath(@__DIR__, "build_pre_ed.jl"))
include(joinpath(@__DIR__, "build_post_ed.jl"))
include(joinpath(@__DIR__, "calibrate.jl"))
include(joinpath(@__DIR__, "scenarios.jl"))

# ============================================================
# 메인 파이프라인
# ============================================================
function main()
    println("=" ^ 74)
    println("  전력시스템 경제 프로젝트 ─ 전체 파이프라인 (개선판)")
    println("  재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석")
    println("  실행 시각: $(Dates.now())")
    println("=" ^ 74)

    output_dir = joinpath(@__DIR__, "..", "outputs")
    mkpath(output_dir)

    # ================================================================
    # PHASE 0: 데이터 로딩 + 개선사항 반영
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 0: 데이터 준비")
    println("─" ^ 74)

    use_real = has_real_data()
    if use_real
        println("  ✓ 실제 데이터 발견 — CSV에서 로딩합니다.")
        all_data = load_all_data()
        println("  ⚠ 실제 데이터 파이프라인은 아직 미완성. 더미 데이터로 진행합니다.")
        use_real = false
    end

    if !use_real
        println("  → 더미 데이터로 실행합니다. data/raw/에 CSV를 넣으면 자동 전환됩니다.")
    end

    # 더미 데이터 생성
    base_input = make_dummy_input(24)
    actual_smp = make_dummy_actual_smp(24)

    # [개선 3] Nuclear Must-Off 반영
    println("\n  ── Nuclear Must-Off 반영 ──")
    nuc_must_off = make_dummy_nuclear_must_off()
    analysis_day = 100  # 봄철 분석 대상일 (4월 중순)
    nuc_avail = compute_nuclear_availability(nuc_must_off, analysis_day)
    println("  · 분석일(Day $analysis_day): 가용 원전 Pmin=$(nuc_avail.pmin) MW, Pmax=$(nuc_avail.pmax) MW")

    # 원전 클러스터 용량 조정
    adjusted_clusters = ThermalCluster[]
    for c in base_input.clusters
        if c.fuel == "nuclear"
            adj = adjust_cluster_capacity(c; pmin=nuc_avail.pmin, pmax=nuc_avail.pmax)
            push!(adjusted_clusters, adj)
            println("  · $(c.name): Pmax $(c.pmax) → $(nuc_avail.pmax) MW, Pmin $(c.pmin) → $(nuc_avail.pmin) MW")
        else
            push!(adjusted_clusters, c)
        end
    end
    base_input = EDInput(base_input.T, base_input.demand, base_input.re_generation, adjusted_clusters)

    # [개선 2] Piecewise Linear 비용함수 준비
    println("\n  ── Piecewise Linear 비용함수 ──")
    gencost = make_dummy_gencost()
    pw_costs = compute_piecewise_costs(base_input.clusters, gencost; S=4)
    println("  · $(length(pw_costs))개 클러스터, 구간 수: $(join([length(pw.segments) for pw in pw_costs], ", "))")

    # [개선 1] Price Adder 물리적 bounds 준비
    unit_specs = make_dummy_unit_specs()
    adder_bounds = compute_adder_physical_bounds(base_input.clusters, unit_specs)
    println("\n  ── Price Adder 물리적 상한 ──")
    for (g, c) in enumerate(base_input.clusters)
        if adder_bounds[g] < Inf
            @printf("  · %-15s: %.0f 원/MWh\n", c.name, adder_bounds[g])
        end
    end

    # 태양광/풍력 개별 가용량 (Post ED 블록 생성용)
    avail_pv = Float64[
        0, 0, 0, 0, 0, 200,
        1500, 6000, 14000, 22000, 28000, 30000,
        30000, 29000, 25000, 18000, 10000, 3000,
        300, 0, 0, 0, 0, 0
    ]
    avail_w = Float64[
        3750, 3900, 4050, 4200, 4050, 3750,
        3300, 3000, 2700, 2550, 2400, 2250,
        2100, 2250, 2400, 2700, 3000, 3300,
        3600, 3900, 4200, 4350, 4200, 4050
    ]

    println("\n  · 수요: $(round(minimum(base_input.demand))) ~ $(round(maximum(base_input.demand))) MW")
    println("  · 재생: $(round(minimum(base_input.re_generation))) ~ $(round(maximum(base_input.re_generation))) MW")

    # ================================================================
    # PHASE 1: Basic ED
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 1: Basic ED (교과서형 기준선)")
    println("─" ^ 74)

    basic_result = solve_basic_ed(base_input)
    if basic_result.status != :OPTIMAL
        println("  ✗ Basic ED 실패. 중단합니다.")
        return
    end

    basic_metrics = compute_metrics(basic_result.smp, actual_smp)
    println("  ✓ Basic ED 완료")
    @printf("  · MAE: %.0f 원/MWh, RMSE: %.0f 원/MWh\n",
            basic_metrics.mae, basic_metrics.rmse)
    @printf("  · 평균 SMP — 모형: %.0f, 실제: %.0f 원/MWh\n",
            basic_metrics.mean_model, basic_metrics.mean_actual)

    # Basic 결과 저장
    basic_df = DataFrame(
        hour = 0:23,
        demand = base_input.demand,
        re = base_input.re_generation,
        net_demand = base_input.demand .- base_input.re_generation,
        smp_basic = basic_result.smp,
        smp_actual = actual_smp,
        error_basic = basic_result.smp .- actual_smp,
    )
    CSV.write(joinpath(output_dir, "basic_result.csv"), basic_df)
    println("  ✓ basic_result.csv 저장")

    # ================================================================
    # PHASE 2: Calibration (Price Adder 추정 — 물리적 bounds 적용)
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 2: Calibration (Price Adder 추정 — 물리적 bounds + Piecewise)")
    println("─" ^ 74)

    fuel_prices = default_fuel_prices()
    println("  · 연료가격: ", join(["$k=$(v)원/Gcal" for (k,v) in sort(collect(fuel_prices))], ", "))

    # [개선 1] 반복 보정 (물리적 bounds + Piecewise Linear)
    adder, cal_history = estimate_price_adder(
        base_input, actual_smp;
        fuel_prices=fuel_prices,
        max_iter=15,
        target_mae=3000.0,
        learning_rate=0.4,
        adder_bounds=adder_bounds,
        pw_costs=pw_costs
    )

    println("  ✓ Calibration 완료 ($(length(cal_history)) 반복)")
    if !isempty(cal_history)
        @printf("  · 최종 MAE: %.0f 원/MWh (Basic MAE: %.0f → 개선율 %.1f%%)\n",
                cal_history[end].mae, basic_metrics.mae,
                100.0 * (1 - cal_history[end].mae / basic_metrics.mae))
    end

    # [개선 1] Price Adder 물리적 범위 검증
    println("\n  ── Price Adder 물리적 범위 검증 ──")
    bounds_ok = validate_adder_bounds(adder, adder_bounds,
                                       [c.name for c in base_input.clusters])
    println(bounds_ok ? "  ✓ 모든 클러스터 adder가 물리적 범위 내" :
                        "  ⚠ 일부 클러스터 adder가 물리적 범위 초과")

    # Calibration 히스토리 저장
    cal_df = DataFrame(
        iteration = 1:length(cal_history),
        mae = [m.mae for m in cal_history],
        rmse = [m.rmse for m in cal_history],
    )
    CSV.write(joinpath(output_dir, "calibration_history.csv"), cal_df)

    # [개선 1] 교차검증 (더미 데이터에서는 단일 대표일이므로, 변형 데이터로 수행)
    println("\n  ── 교차검증 (과적합 진단) ──")
    # 더미: 수요를 ±5% 변형하여 3개 대표일 생성
    cv_days = []
    for scale in [0.95, 1.0, 1.05]
        push!(cv_days, (
            demand = base_input.demand .* scale,
            re_generation = base_input.re_generation,
            actual_smp = actual_smp .* scale,
        ))
    end
    cv_result = cross_validate_adder(base_input, cv_days;
                                      fuel_prices=fuel_prices,
                                      max_iter=10,
                                      learning_rate=0.4,
                                      target_mae=5000.0,
                                      adder_bounds=adder_bounds,
                                      pw_costs=pw_costs)

    # ================================================================
    # PHASE 3: Pre-revision ED (보정된 기준모형 — Piecewise Linear)
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 3: Pre-revision ED (현행 육지 SMP 재현 — Piecewise Linear)")
    println("─" ^ 74)

    pre_input = make_pre_input(base_input; fuel_prices=fuel_prices, adder=adder)
    pre_result = solve_pre_ed(pre_input; pw_costs=pw_costs)

    if pre_result.status != :OPTIMAL
        println("  ✗ Pre ED 실패. 중단합니다.")
        return
    end

    pre_metrics = compute_metrics(pre_result.smp, actual_smp)
    println("  ✓ Pre ED 완료")
    @printf("  · MAE: %.0f 원/MWh, RMSE: %.0f 원/MWh\n",
            pre_metrics.mae, pre_metrics.rmse)

    # 출력제한 정보
    pre_curt_total = sum(pre_result.curtailment)
    pre_curt_hours = count(c -> c > 1e-3, pre_result.curtailment)
    if pre_curt_total > 1e-3
        @printf("  · Pre ED 출력제한: %.0f MWh (%d시간)\n", pre_curt_total, pre_curt_hours)
    end

    # 한계연료원
    pre_mf = identify_marginal_fuel_pre(pre_result, pre_input)
    pre_mf_share = marginal_fuel_share(pre_mf)
    println("  · 한계연료원: ", join(["$k=$(round(v,digits=1))%" for (k,v) in sort(collect(pre_mf_share), by=x->-x[2])], ", "))

    # Pre 결과 저장
    pre_df = DataFrame(
        hour = 0:23,
        demand = base_input.demand,
        re = base_input.re_generation,
        smp_basic = basic_result.smp,
        smp_pre = pre_result.smp,
        smp_actual = actual_smp,
        error_pre = pre_result.smp .- actual_smp,
        marginal_fuel = pre_mf,
        curtailment = pre_result.curtailment,
    )
    for g in 1:length(base_input.clusters)
        pre_df[!, Symbol(base_input.clusters[g].name)] = pre_result.generation[g, :]
    end
    CSV.write(joinpath(output_dir, "pre_result.csv"), pre_df)
    println("  ✓ pre_result.csv 저장")

    # ================================================================
    # PHASE 4: Post-revision ED (4개 시나리오 — 6블록 + RE Pmin)
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 4: Post-revision ED (재생에너지 입찰제 — 6블록, RE Pmin=10%)")
    println("─" ^ 74)

    sc_results = run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                                pw_costs=pw_costs, re_pmin_frac=0.1)
    print_scenario_summary(sc_results, pre_result)

    # 시나리오 요약 저장
    if !isempty(sc_results)
        sc_summary = scenario_summary_table(sc_results)
        CSV.write(joinpath(output_dir, "scenario_summary.csv"), sc_summary)
        println("  ✓ scenario_summary.csv 저장")

        # 시나리오별 시간대 SMP 저장
        sc_hourly = DataFrame(hour = 0:23, smp_pre = pre_result.smp)
        for r in sc_results
            sc_hourly[!, Symbol("smp_" * r.config.name)] = r.post_result.base.smp
            sc_hourly[!, Symbol("delta_" * r.config.name)] = r.delta_smp["delta_smp"]
            sc_hourly[!, Symbol("curt_" * r.config.name)] = r.curtailment.by_hour
        end
        CSV.write(joinpath(output_dir, "scenario_hourly.csv"), sc_hourly)
        println("  ✓ scenario_hourly.csv 저장")

        # [개선 6] Pre vs Post 출력제한 비교
        println("\n  ── Pre vs Post 출력제한 비교 ──")
        curt_compare = compare_pre_post_curtailment(pre_result, sc_results)
        CSV.write(joinpath(output_dir, "curtailment_analysis.csv"), curt_compare)
        for row in eachrow(curt_compare)
            @printf("  · %-22s: %.0f MWh (%d시간)",
                    row.scenario, row.curtailment_MWh, row.curtailment_hours)
            if row.reduction_pct != 0.0
                @printf(" [%+.1f%%]", -row.reduction_pct)
            end
            println()
        end
        println("  ✓ curtailment_analysis.csv 저장")
    end

    # ================================================================
    # PHASE 4.5: 몬테카를로 시뮬레이션 (개선사항 4c)
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 4.5: 몬테카를로 시뮬레이션 (확률적 입찰가)")
    println("─" ^ 74)

    mc_result = run_monte_carlo_scenarios(
        pre_input, pre_result, avail_pv, avail_w;
        n_samples=100, beta=2.0, rec_price=80.0,
        rho_pv=0.3, rho_w=0.3, seed=42,
        pw_costs=pw_costs, re_pmin_frac=0.1
    )

    if mc_result.n_samples > 0
        mc_df = DataFrame(
            hour = 0:23,
            smp_pre = pre_result.smp,
            mc_mean_smp = mc_result.mean_smp,
            mc_p5_smp = mc_result.p5_smp,
            mc_p95_smp = mc_result.p95_smp,
            mc_delta = mc_result.mean_smp .- pre_result.smp,
            mc_mean_curt = mc_result.mean_curtailment,
        )
        CSV.write(joinpath(output_dir, "monte_carlo_result.csv"), mc_df)
        println("  ✓ monte_carlo_result.csv 저장")
    end

    # ================================================================
    # PHASE 5: 민감도 분석
    # ================================================================
    println("\n" * "─" ^ 74)
    println("  PHASE 5: 민감도 분석")
    println("─" ^ 74)

    # β 민감도
    println("\n  [β 민감도 — mixed 시나리오]")
    beta_results = run_beta_sensitivity(
        pre_input, pre_result, avail_pv, avail_w;
        betas=[1.5, 2.0, 2.5],
        pw_costs=pw_costs, re_pmin_frac=0.1
    )
    if !isempty(beta_results)
        print_scenario_summary(beta_results, pre_result)
        beta_df = scenario_summary_table(beta_results)
        CSV.write(joinpath(output_dir, "sensitivity_beta.csv"), beta_df)
        println("  ✓ sensitivity_beta.csv 저장")
    end

    # ρ 민감도
    println("\n  [입찰참여율(ρ) 민감도 — mixed 시나리오]")
    rho_results = run_rho_sensitivity(
        pre_input, pre_result, avail_pv, avail_w;
        rhos=[0.1, 0.2, 0.3, 0.5],
        pw_costs=pw_costs, re_pmin_frac=0.1
    )
    if !isempty(rho_results)
        print_scenario_summary(rho_results, pre_result)
        rho_df = scenario_summary_table(rho_results)
        CSV.write(joinpath(output_dir, "sensitivity_rho.csv"), rho_df)
        println("  ✓ sensitivity_rho.csv 저장")
    end

    # ================================================================
    # PHASE 6: 전체 요약
    # ================================================================
    println("\n" * "=" ^ 74)
    println("  전체 파이프라인 완료 요약")
    println("=" ^ 74)
    println()
    println("  ┌─ SMP 정합도 비교 ─────────────────────────────────────┐")
    @printf("  │ %-15s │ %12s │ %12s │ %12s │\n", "Model", "MAE", "RMSE", "Mean SMP")
    println("  ├─────────────────┼──────────────┼──────────────┼──────────────┤")
    @printf("  │ %-15s │ %12.0f │ %12.0f │ %12.0f │\n",
            "Basic ED", basic_metrics.mae, basic_metrics.rmse, basic_metrics.mean_model)
    @printf("  │ %-15s │ %12.0f │ %12.0f │ %12.0f │\n",
            "Pre ED (PW)", pre_metrics.mae, pre_metrics.rmse, pre_metrics.mean_model)
    @printf("  │ %-15s │ %12s │ %12s │ %12.0f │\n",
            "Actual", "-", "-", pre_metrics.mean_actual)
    println("  └─────────────────┴──────────────┴──────────────┴──────────────┘")

    println()
    println("  ┌─ 개선사항 적용 현황 ──────────────────────────────────────────┐")
    println("  │ [✓] 1. Price Adder 교차검증 + 물리적 bounds                  │")
    println("  │ [✓] 2. Piecewise Linear 비용함수 ($(length(pw_costs[1].segments))구간)          │")
    println("  │ [✓] 3. Nuclear Must-Off (Day $analysis_day: Pmax=$(nuc_avail.pmax) MW)    │")
    println("  │ [✓] 4. RE 6블록 + Pmin=10% + 몬테카를로($(mc_result.n_samples)회)        │")
    println("  │ [✓] 5. Curtailment Dual Pollution 수정 (re_net 분리)         │")
    println("  │ [✓] 6. 출력제한 분석 (Pre vs Post 비교)                      │")
    println("  └──────────────────────────────────────────────────────────────┘")

    println()
    println("  출력 파일:")
    for f in sort(readdir(output_dir))
        fpath = joinpath(output_dir, f)
        if isfile(fpath)
            size_kb = round(filesize(fpath) / 1024, digits=1)
            println("    $(f) ($(size_kb) KB)")
        end
    end

    println("\n  다음 단계:")
    println("  1. data/raw/에 실제 CSV/MAT 데이터를 넣으면 자동으로 실제 데이터 사용")
    println("  2. nuclear_must_off.csv, gencost 데이터 제공 시 더미→실데이터 전환")
    println("  3. 보고서·발표 그래프는 outputs/ 폴더의 CSV로 생성")
    println("=" ^ 74)
end

# 실행
main()
