# ============================================================
# run_all.jl — 전체 122기 개별 발전기 기반 ED 파이프라인
# ============================================================
# 기존 src/ 솔버를 재사용하되, 개별 발전기 122기 데이터로 구동
# 12일 대표일에 대해 6 Phase 파이프라인 수행
#
# 사용법:
#   cd PSE_Project1/
#   julia --project=. all_gen_real_system/all_gen_real_system_src/run_all.jl
# ============================================================

using Printf
using JuMP
using HiGHS
using CSV
using DataFrames
using Statistics
using Dates
import MathOptInterface as MOI

# ── include 순서 ──
const SRC_DIR = @__DIR__
include(joinpath(SRC_DIR, "types.jl"))
include(joinpath(SRC_DIR, "load_data.jl"))
include(joinpath(SRC_DIR, "preprocess.jl"))
include(joinpath(SRC_DIR, "build_basic_ed.jl"))
include(joinpath(SRC_DIR, "build_pre_ed.jl"))
include(joinpath(SRC_DIR, "build_post_ed.jl"))
include(joinpath(SRC_DIR, "calibrate.jl"))
include(joinpath(SRC_DIR, "scenarios.jl"))

const OUT_DIR = joinpath(SRC_DIR, "..", "all_gen_real_system_outputs")
mkpath(OUT_DIR)

# ============================================================
# 메인 파이프라인
# ============================================================
function main()
    println("=" ^ 74)
    println("  전력시스템 경제 프로젝트 — 개별 발전기 122기 파이프라인")
    println("  재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석")
    println("  실행 시각: $(Dates.now())")
    println("=" ^ 74)

    # ================================================================
    # PHASE 0: 데이터 로딩 + 전처리
    # ================================================================
    println("\n" * "-" ^ 74)
    println("  PHASE 0: 데이터 준비")
    println("-" ^ 74)

    if !has_real_data()
        println("  processed/ 데이터가 없습니다.")
        println("  먼저 preprocessing_code/run_all_preprocessing.py를 실행하세요.")
        return
    end

    # ── 데이터 로딩 ──
    all_data = load_all_data()
    generators = all_data["generators"]::Vector{ThermalGenerator}
    gencost_dict = all_data["gencost"]::Dict{String,Tuple{Float64,Float64,Float64}}
    unit_specs = all_data["unit_specs"]::Vector{ThermalUnitSpec}
    must_off = all_data["nuclear_must_off"]::DataFrame
    smp_demand_df = all_data["smp_demand"]::DataFrame
    re_df = all_data["renewable"]::DataFrame

    G = length(generators)
    println("\n  발전기: $(G)기")

    # ── SMP·수요·재생에너지 병합 ──
    println("\n  -- SMP/수요/재생에너지 데이터 병합 --")
    merged = innerjoin(smp_demand_df, re_df, on=[:date, :hour])
    rename!(merged,
        :smp_mainland => :smp,
        :demand_mainland => :demand,
        :solar_mainland => :solar,
        :wind_mainland => :wind
    )
    merged.re_total = merged.solar .+ merged.wind
    println("  병합 완료: $(nrow(merged))행")

    # ── 대표일 선정 ──
    println("\n  -- 대표일 12일 선정 --")
    profiles = compute_day_profiles(merged)
    rep_days = select_representative_days(profiles)
    N_DAYS = length(rep_days)
    println("  대표일 $(N_DAYS)일:")
    for (i, d) in enumerate(rep_days)
        p = first(filter(x -> x.date == d, profiles))
        @printf("    %2d. %s [%s] 최대수요=%.0f MW, 평균SMP=%.0f 원/MWh\n",
                i, d, p.season, p.max_demand, p.mean_smp)
    end

    # ── Piecewise cost & Adder bounds ──
    pw_costs_base = compute_piecewise_costs(generators, gencost_dict; S=4)
    println("\n  Piecewise cost: $(length(pw_costs_base))기 x 4구간")

    adder_bounds = compute_adder_physical_bounds(generators, unit_specs)
    println("  Adder bounds: max=$(round(maximum(adder_bounds), digits=0)) 원/MWh")

    # ================================================================
    # 결과 수집용 DataFrame
    # ================================================================
    basic_results_all = DataFrame()
    calibration_all = DataFrame()
    pre_results_all = DataFrame()
    scenario_summary_all = DataFrame()
    scenario_hourly_all = DataFrame()
    curtailment_all = DataFrame()
    mc_results_all = DataFrame()
    sensitivity_beta_all = DataFrame()
    sensitivity_rho_all = DataFrame()

    # ================================================================
    # 대표일 루프
    # ================================================================
    for (day_idx, date_str) in enumerate(rep_days)
        println("\n" * "=" ^ 74)
        println("  대표일 $day_idx/$N_DAYS: $date_str")
        println("=" ^ 74)

        # ── 해당 일자 데이터 추출 ──
        day = extract_day_data(merged, date_str)
        T = day.T
        if T != 24
            @warn "  날짜 $date_str: T=$T (24가 아님), 건너뜁니다."
            continue
        end

        re_total = day.solar .+ day.wind

        # ── 원전 정비 반영 (이름 매핑 기반) ──
        day_of_year = Dates.dayofyear(Date(date_str))
        adjusted_gens, offline_pairs = apply_nuclear_must_off(generators, must_off, day_of_year)

        nuc_total_pmax = sum(g.pmax for g in adjusted_gens if g.fuel == "Nuclear")
        offline_count = length(offline_pairs)
        println("  Nuclear: $(offline_count)기 정비, 가용 $(round(nuc_total_pmax)) MW")
        for (uname, gid) in offline_pairs
            println("    OFF: $uname -> $gid")
        end

        # PW cost 재계산 (원전 용량 변경)
        pw_costs = compute_piecewise_costs(adjusted_gens, gencost_dict; S=4)

        # ── PHASE 1: Basic ED ──
        println("\n  [PHASE 1] Basic ED...")
        base_input = EDInput(T, day.demand, re_total, adjusted_gens)
        basic_result = solve_basic_ed(base_input)

        if basic_result.status != :OPTIMAL
            println("    INFEASIBLE -- 건너뜁니다.")
            continue
        end

        basic_metrics = compute_metrics(basic_result.smp, day.smp)
        marginal_fuels = identify_marginal_fuel(basic_result, base_input)
        @printf("    MAE: %.0f 원/MWh, RMSE: %.0f 원/MWh\n",
                basic_metrics.mae, basic_metrics.rmse)

        for t in 1:T
            push!(basic_results_all, (
                date=date_str, hour=t,
                demand=day.demand[t], re=re_total[t],
                net_demand=max(0.0, day.demand[t] - re_total[t]),
                smp_model=basic_result.smp[t],
                smp_actual=day.smp[t],
                smp_error=basic_result.smp[t] - day.smp[t],
                marginal_fuel=marginal_fuels[t],
            ))
        end

        # ── PHASE 2: Calibration ──
        println("\n  [PHASE 2] Price Adder Calibration...")
        # gencost 기반 MC matrix 생성
        effective_mc = build_effective_mc_matrix(adjusted_gens, gencost_dict, T)

        adder, cal_history = estimate_price_adder(
            base_input, day.smp;
            max_iter=15, target_mae=3000.0, learning_rate=0.3,
            adder_bounds=adder_bounds, pw_costs=pw_costs
        )
        if !isempty(cal_history)
            @printf("    %d iterations, Final MAE: %.0f 원/MWh\n",
                    length(cal_history), cal_history[end].mae)
        end

        for (iter, m) in enumerate(cal_history)
            push!(calibration_all, (
                date=date_str, iteration=iter,
                mae=m.mae, rmse=m.rmse,
            ))
        end

        # ── PHASE 3: Pre-revision ED ──
        println("\n  [PHASE 3] Pre-revision ED...")
        pre_input = PreEDInput(base_input, effective_mc, adder)
        pre_result = solve_pre_ed(pre_input; pw_costs=pw_costs)

        if pre_result.status != :OPTIMAL
            println("    INFEASIBLE -- 건너뜁니다.")
            continue
        end

        pre_metrics = compute_metrics(pre_result.smp, day.smp)
        pre_fuels = identify_marginal_fuel_pre(pre_result, pre_input)
        @printf("    MAE: %.0f 원/MWh, RMSE: %.0f 원/MWh\n",
                pre_metrics.mae, pre_metrics.rmse)

        for t in 1:T
            push!(pre_results_all, (
                date=date_str, hour=t,
                demand=day.demand[t], re=re_total[t],
                smp_model=pre_result.smp[t],
                smp_actual=day.smp[t],
                smp_error=pre_result.smp[t] - day.smp[t],
                marginal_fuel=pre_fuels[t],
                curtailment=pre_result.curtailment[t],
            ))
        end

        # ── PHASE 4: Post-revision ED ──
        println("\n  [PHASE 4] Post-revision ED (4 scenarios)...")
        avail_pv = day.solar
        avail_w = day.wind

        sc_results = run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                                    pw_costs=pw_costs, re_pmin_frac=0.1)

        for sr in sc_results
            cfg = sr.config
            ds = sr.delta_smp
            curt = sr.curtailment

            push!(scenario_summary_all, (
                date=date_str, scenario=cfg.name,
                mean_smp_pre=mean(pre_result.smp),
                mean_smp_post=mean(sr.post_result.base.smp),
                mean_delta_smp=ds["mean_delta"],
                curtailment_mwh=curt.total_mwh,
                curtailment_hours=curt.hours,
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
        curt_compare = compare_pre_post_curtailment(pre_result, sc_results)
        for row in eachrow(curt_compare)
            push!(curtailment_all, (
                date=date_str,
                scenario=row.scenario,
                curtailment_MWh=row.curtailment_MWh,
                curtailment_hours=row.curtailment_hours,
                reduction_pct=row.reduction_pct,
            ))
        end

        # Monte Carlo
        println("    Monte Carlo (50 samples)...")
        mc_result = run_monte_carlo_scenarios(
            pre_input, pre_result, avail_pv, avail_w;
            n_samples=50, beta=2.0, rec_price=80.0,
            rho_pv=0.3, rho_w=0.3, seed=42,
            pw_costs=pw_costs, re_pmin_frac=0.1
        )
        if mc_result.n_samples > 0
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
            @printf("    MC mean dSMP: %.0f 원/MWh\n", mc_result.mean_delta_smp)
        end

        # ── PHASE 5: 민감도 분석 ──
        println("\n  [PHASE 5] Sensitivity...")
        beta_results = run_beta_sensitivity(
            pre_input, pre_result, avail_pv, avail_w;
            betas=[1.5, 2.0, 2.5], pw_costs=pw_costs, re_pmin_frac=0.1
        )
        for sr in beta_results
            push!(sensitivity_beta_all, (
                date=date_str, beta=sr.config.beta,
                mean_delta_smp=sr.delta_smp["mean_delta"],
                curtailment_mwh=sr.curtailment.total_mwh,
            ))
        end

        rho_results = run_rho_sensitivity(
            pre_input, pre_result, avail_pv, avail_w;
            rhos=[0.1, 0.2, 0.3, 0.5], pw_costs=pw_costs, re_pmin_frac=0.1
        )
        for sr in rho_results
            push!(sensitivity_rho_all, (
                date=date_str, rho=sr.config.rho_pv,
                mean_delta_smp=sr.delta_smp["mean_delta"],
                curtailment_mwh=sr.curtailment.total_mwh,
            ))
        end

        println("  Day $date_str complete.")
    end

    # ================================================================
    # 결과 저장
    # ================================================================
    println("\n" * "=" ^ 74)
    println("  결과 저장")
    println("=" ^ 74)

    function save_csv(df, name)
        if nrow(df) > 0
            path = joinpath(OUT_DIR, name)
            CSV.write(path, df)
            println("  $name: $(nrow(df)) rows")
        else
            println("  $name: SKIP (empty)")
        end
    end

    save_csv(basic_results_all,    "basic_result.csv")
    save_csv(calibration_all,       "calibration_history.csv")
    save_csv(pre_results_all,       "pre_result.csv")
    save_csv(scenario_summary_all,  "scenario_summary.csv")
    save_csv(scenario_hourly_all,   "scenario_hourly.csv")
    save_csv(curtailment_all,       "curtailment_analysis.csv")
    save_csv(mc_results_all,        "monte_carlo_result.csv")
    save_csv(sensitivity_beta_all,  "sensitivity_beta.csv")
    save_csv(sensitivity_rho_all,   "sensitivity_rho.csv")

    # 최종 요약
    println("\n" * "=" ^ 74)
    println("  파이프라인 완료")
    println("=" ^ 74)
    println("  발전기: $(G)기 (개별 발전기, 클러스터링 없음)")
    println("  대표일: $(N_DAYS)일")

    if nrow(calibration_all) > 0
        last_maes = filter(r -> r.iteration == maximum(calibration_all.iteration), calibration_all)
        @printf("  Calibration 평균 MAE: %.0f 원/MWh\n", mean(last_maes.mae))
    end

    if nrow(scenario_summary_all) > 0
        for sc in unique(scenario_summary_all.scenario)
            sub = filter(r -> r.scenario == sc, scenario_summary_all)
            @printf("  시나리오 %s: 평균 dSMP=%.0f 원/MWh\n", sc, mean(sub.mean_delta_smp))
        end
    end

    println("\n  출력: $OUT_DIR")
    println("=" ^ 74)
end

# 실행
main()
