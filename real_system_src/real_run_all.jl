## real_run_all.jl — 실데이터 기반 전체 파이프라인 실행
#
# 기존 src/ 솔버를 그대로 재사용하되, 실데이터로 구동
# 12일 대표일에 대해 6 Phase 파이프라인 수행
# 결과를 outputs_real_system/에 저장

println("="^70)
println("  전력시장 경제급전 분석 — 실데이터 파이프라인")
println("  2024년 한국 육지계통 SMP 변화 분석")
println("="^70)

# ── 패키지 & 기존 소스 로딩 ───────────────────────────────────
using JuMP, HiGHS, CSV, DataFrames, Statistics, Dates

const PROJECT_DIR = dirname(@__DIR__)
const SRC_DIR = joinpath(PROJECT_DIR, "src")
const RAW_DIR = joinpath(PROJECT_DIR, "data", "raw")
const OUT_DIR = joinpath(PROJECT_DIR, "outputs_real_system")

mkpath(OUT_DIR)

# 기존 src 재사용 (types, 솔버, 시나리오 등)
include(joinpath(SRC_DIR, "types.jl"))
include(joinpath(SRC_DIR, "build_basic_ed.jl"))
include(joinpath(SRC_DIR, "build_pre_ed.jl"))
include(joinpath(SRC_DIR, "build_post_ed.jl"))
include(joinpath(SRC_DIR, "calibrate.jl"))
include(joinpath(SRC_DIR, "scenarios.jl"))
include(joinpath(SRC_DIR, "preprocess.jl"))

# 실데이터 전용 로더/전처리
include(joinpath(PROJECT_DIR, "real_system_src", "real_load_data.jl"))
include(joinpath(PROJECT_DIR, "real_system_src", "real_preprocess.jl"))

# ══════════════════════════════════════════════════════════════
# PHASE 0: 데이터 로딩 및 대표일 선정
# ══════════════════════════════════════════════════════════════
println("\n" * "="^70)
println("  PHASE 0: 데이터 로딩 및 대표일 선정")
println("="^70)

data = load_all_real_data(RAW_DIR)
merged = data.merged
clusters_base = data.clusters
fuel_dict = data.fuel_dict
avg_fuel = data.avg_fuel
gencost_dict = data.gencost
unit_specs = data.unit_specs
must_off = data.must_off

G = length(clusters_base)
println("\n클러스터 수: $G (CHP 제거, VOM=0)")

# 대표일 선정
profiles = compute_real_day_profiles(merged)
rep_days = select_real_representative_days(profiles)
N_DAYS = length(rep_days)
println("\n대표일 $N_DAYS 일 선정 완료")

# Piecewise cost 준비
pw_costs_base = compute_piecewise_costs(clusters_base, gencost_dict; S=4)
println("Piecewise cost segments: $(length(pw_costs_base)) clusters x 4 segments")

# Price adder bounds
adder_bounds = compute_adder_physical_bounds(clusters_base, unit_specs)
println("Adder bounds computed: max=$(round(maximum(adder_bounds), digits=0)) 원/MWh")

# ══════════════════════════════════════════════════════════════
# 결과 수집용 DataFrame들
# ══════════════════════════════════════════════════════════════
basic_results_all = DataFrame()
calibration_all = DataFrame()
pre_results_all = DataFrame()
scenario_summary_all = DataFrame()
scenario_hourly_all = DataFrame()
curtailment_all = DataFrame()
mc_results_all = DataFrame()
sensitivity_beta_all = DataFrame()
sensitivity_rho_all = DataFrame()

# ══════════════════════════════════════════════════════════════
# 대표일 루프: 각 날짜에 대해 6 Phase 실행
# ══════════════════════════════════════════════════════════════
for (day_idx, date_str) in enumerate(rep_days)
    println("\n" * "="^70)
    println("  대표일 $day_idx/$N_DAYS: $date_str")
    println("="^70)

    # ── 해당 일자 데이터 추출 ──
    day = extract_real_day(merged, date_str)
    T = day.T

    # 원전 정비 반영
    clusters, n_offline = adjust_nuclear_for_day(clusters_base, must_off, date_str)
    nuc = first(filter(c -> c.fuel == "nuclear", clusters))
    println("  Nuclear: $(n_offline)기 정비, 가용 Pmax=$(round(nuc.pmax))MW")

    # Piecewise cost 재계산 (원전 용량 변경 반영)
    pw_costs = compute_piecewise_costs(clusters, gencost_dict; S=4)

    # 유효한계비용 산출 (월별 연료단가, VOM=0)
    effective_mc = compute_real_effective_mc(clusters, fuel_dict, date_str, T)

    # ── PHASE 1: Basic ED ──
    println("\n  [PHASE 1] Basic ED...")
    base_input = EDInput(T, day.demand, day.re_total, clusters)
    basic_result = solve_basic_ed(base_input)

    if basic_result.status in (:Optimal, :OPTIMAL)
        basic_metrics = compute_basic_metrics(basic_result, day.smp_actual)
        marginal_fuels = identify_marginal_fuel(basic_result, base_input)
        println("    Status: Optimal, MAE=$(round(basic_metrics["MAE"], digits=0)) 원/MWh")

        for t in 1:T
            push!(basic_results_all, (
                date=date_str, hour=t,
                demand=day.demand[t], re=day.re_total[t],
                net_demand=max(0, day.demand[t] - day.re_total[t]),
                smp_model=basic_result.smp[t],
                smp_actual=day.smp_actual[t],
                smp_error=basic_result.smp[t] - day.smp_actual[t],
                marginal_fuel=marginal_fuels[t],
                [Symbol(clusters[g].name) => basic_result.generation[g,t] for g in 1:G]...
            ))
        end
    else
        println("    Status: $(basic_result.status) — 건너뜀")
        continue
    end

    # ── PHASE 2: Calibration ──
    println("\n  [PHASE 2] Price Adder Calibration...")
    adder, cal_history = estimate_price_adder(
        base_input, day.smp_actual;
        max_iter=15, target_mae=3000.0, learning_rate=0.3,
        adder_bounds=adder_bounds, pw_costs=pw_costs
    )
    final_mae = cal_history[end].mae
    println("    Iterations: $(length(cal_history)), Final MAE=$(round(final_mae, digits=0)) 원/MWh")

    for (iter, m) in enumerate(cal_history)
        push!(calibration_all, (
            date=date_str, iteration=iter,
            mae=m.mae, rmse=m.rmse,
            mean_model=m.mean_model, mean_actual=m.mean_actual,
        ))
    end

    # ── PHASE 3: Pre-revision ED ──
    println("\n  [PHASE 3] Pre-revision ED...")
    pre_input = PreEDInput(base_input, effective_mc, adder)
    pre_result = solve_pre_ed(pre_input; pw_costs=pw_costs)

    if pre_result.status in (:Optimal, :OPTIMAL)
        pre_metrics = compute_basic_metrics(pre_result, day.smp_actual)
        pre_fuels = identify_marginal_fuel_pre(pre_result, pre_input)
        println("    Status: Optimal, MAE=$(round(pre_metrics["MAE"], digits=0)) 원/MWh")

        for t in 1:T
            push!(pre_results_all, (
                date=date_str, hour=t,
                demand=day.demand[t], re=day.re_total[t],
                smp_model=pre_result.smp[t],
                smp_actual=day.smp_actual[t],
                smp_error=pre_result.smp[t] - day.smp_actual[t],
                marginal_fuel=pre_fuels[t],
                curtailment=pre_result.curtailment[t],
                [Symbol(clusters[g].name) => pre_result.generation[g,t] for g in 1:G]...
            ))
        end
    else
        println("    Status: $(pre_result.status) — 건너뜀")
        continue
    end

    # ── PHASE 4: Post-revision ED (4개 시나리오) ──
    println("\n  [PHASE 4] Post-revision ED (4 scenarios)...")
    avail_pv = day.solar
    avail_w = day.wind

    scenario_configs = default_scenarios(beta=2.0, rho_pv=0.3, rho_w=0.3, rec_price=80.0)
    scenario_results = run_scenarios(
        pre_input, pre_result, avail_pv, avail_w;
        scenarios=scenario_configs, pw_costs=pw_costs, re_pmin_frac=0.1
    )

    for sr in scenario_results
        cfg = sr.config
        ds = sr.delta_smp
        curt = sr.curtailment

        push!(scenario_summary_all, (
            date=date_str,
            scenario=cfg.name,
            beta=cfg.beta, rho_pv=cfg.rho_pv, rho_w=cfg.rho_w,
            mean_smp_pre=mean(pre_result.smp),
            mean_smp_post=mean(sr.post_result.base.smp),
            mean_delta_smp=ds["mean_delta"],
            hours_down=ds["hours_down"],
            hours_up=ds["hours_up"],
            curtailment_mwh=curt.total_mwh,
            curtailment_hours=curt.hours,
            max_curtailment_mw=curt.max_mw,
        ))

        for t in 1:T
            push!(scenario_hourly_all, (
                date=date_str, hour=t, scenario=cfg.name,
                smp_pre=pre_result.smp[t],
                smp_post=sr.post_result.base.smp[t],
                delta_smp=ds["delta_smp"][t],
                curtailment=curt.by_hour[t],
            ))
        end
    end

    # 출력제한 분석
    for sr in scenario_results
        push!(curtailment_all, (
            date=date_str, scenario=sr.config.name,
            pre_curtailment_mwh=sum(pre_result.curtailment),
            post_curtailment_mwh=sr.curtailment.total_mwh,
            reduction_mwh=sum(pre_result.curtailment) - sr.curtailment.total_mwh,
        ))
    end

    # Monte Carlo
    println("    Monte Carlo (100 samples)...")
    mc_result = run_monte_carlo_scenarios(
        pre_input, pre_result, avail_pv, avail_w;
        n_samples=100, beta=2.0, rho_pv=0.3, rho_w=0.3,
        rec_price=80.0, pw_costs=pw_costs, seed=42
    )
    for t in 1:T
        push!(mc_results_all, (
            date=date_str, hour=t,
            mean_smp=mc_result.mean_smp[t],
            p5_smp=mc_result.p5_smp[t],
            p95_smp=mc_result.p95_smp[t],
            smp_pre=pre_result.smp[t],
            mean_curtailment=mc_result.mean_curtailment[t],
        ))
    end
    println("    MC mean ΔSMP: $(round(mc_result.mean_delta_smp, digits=0)) 원/MWh")

    # ── PHASE 5: 민감도 분석 ──
    println("\n  [PHASE 5] Sensitivity Analysis...")

    # β 민감도
    beta_results = run_beta_sensitivity(
        pre_input, pre_result, avail_pv, avail_w;
        betas=[1.5, 2.0, 2.5], scenario="mixed",
        rho_pv=0.3, rho_w=0.3, rec_price=80.0, pw_costs=pw_costs
    )
    for sr in beta_results
        push!(sensitivity_beta_all, (
            date=date_str, beta=sr.config.beta,
            mean_delta_smp=sr.delta_smp["mean_delta"],
            curtailment_mwh=sr.curtailment.total_mwh,
            mean_smp_post=mean(sr.post_result.base.smp),
        ))
    end

    # ρ 민감도
    rho_results = run_rho_sensitivity(
        pre_input, pre_result, avail_pv, avail_w;
        rhos=[0.1, 0.2, 0.3, 0.5], scenario="mixed",
        beta=2.0, rec_price=80.0, pw_costs=pw_costs
    )
    for sr in rho_results
        push!(sensitivity_rho_all, (
            date=date_str, rho=sr.config.rho_pv,
            mean_delta_smp=sr.delta_smp["mean_delta"],
            curtailment_mwh=sr.curtailment.total_mwh,
            mean_smp_post=mean(sr.post_result.base.smp),
        ))
    end

    println("  Day $date_str complete.")
end

# ══════════════════════════════════════════════════════════════
# 결과 저장
# ══════════════════════════════════════════════════════════════
println("\n" * "="^70)
println("  결과 저장: $OUT_DIR")
println("="^70)

function save_csv(df, name)
    path = joinpath(OUT_DIR, name)
    CSV.write(path, df)
    println("  $name: $(nrow(df)) rows")
end

save_csv(basic_results_all, "basic_result.csv")
save_csv(calibration_all, "calibration_history.csv")
save_csv(pre_results_all, "pre_result.csv")
save_csv(scenario_summary_all, "scenario_summary.csv")
save_csv(scenario_hourly_all, "scenario_hourly.csv")
save_csv(curtailment_all, "curtailment_analysis.csv")
save_csv(mc_results_all, "monte_carlo_result.csv")
save_csv(sensitivity_beta_all, "sensitivity_beta.csv")
save_csv(sensitivity_rho_all, "sensitivity_rho.csv")

# ── 최종 요약 ────────────────────────────────────────────────
println("\n" * "="^70)
println("  실행 완료 요약")
println("="^70)
println("  대표일: $N_DAYS 일")
println("  클러스터: $G 개 (CHP 제거, VOM=0)")
if nrow(calibration_all) > 0
    last_iters = filter(r -> r.iteration == maximum(calibration_all.iteration), calibration_all)
    println("  Calibration 최종 MAE: $(round(mean(last_iters.mae), digits=0)) 원/MWh")
end

if nrow(scenario_summary_all) > 0
    for sc in unique(scenario_summary_all.scenario)
        sub = filter(r -> r.scenario == sc, scenario_summary_all)
        println("  시나리오 $sc: 평균 ΔSMP=$(round(mean(sub.mean_delta_smp), digits=0)) 원/MWh")
    end
end

println("\n출력 파일 $(length(readdir(OUT_DIR))) 개 → $OUT_DIR")
println("="^70)
