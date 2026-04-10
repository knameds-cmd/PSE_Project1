# ============================================================
# run_all.jl  ─  전체 파이프라인 v2 (개별 발전기 122기 + real-data)
# ============================================================
# Gurobi solver variant
# ============================================================
# 8784시간 패널(2024) → train/test split → multi-day calibration
# → 12개 대표일에서 Pre/Post ED 평가 → 침투도(S1/S2/S3) 시나리오
# → β·ρ 민감도 → Beta-mixture 몬테카를로
#
# v2 핵심 변화 (개선계획서 §1~§11)
#   §1  potential 재구성 (발전량 ≡ potential 가정)
#   §2  Bidder mixture types (S2 default)
#   §3  Case_A_zero ≡ ρ=0 baseline + bidding_active=false
#   §5  RE Pmin = min(α·installed, avail)
#   §6  Beta(α,β) mixture + common shock 몬테카를로
#   §7  활성 marginal 전체 갱신 + 1/n_marg 정규화
#   §8  Tikhonov L2 shrinkage
#   §9  curtailment_free calibration purity
#   §10 Train/test/buffer split + 3D adder (G×24×S)
#   §11 검증 assert + CHANGELOG
#
# 사용법:
#   cd PSE_Project1/
#   julia --project=. all_gen_real_system/all_gen_real_system_src/gurobi/run_all.jl
# ============================================================

using Printf
using CSV
using DataFrames
using Dates
using Statistics
using Random

# ── include 순서 (types.jl 이 최상위) ──
const SRC_DIR = @__DIR__
include(joinpath(SRC_DIR, "..", "types.jl"))
include(joinpath(SRC_DIR, "..", "load_data.jl"))
include(joinpath(SRC_DIR, "..", "preprocess.jl"))
include(joinpath(SRC_DIR, "build_basic_ed.jl"))
include(joinpath(SRC_DIR, "build_pre_ed.jl"))
include(joinpath(SRC_DIR, "build_post_ed.jl"))
include(joinpath(SRC_DIR, "..", "calibrate.jl"))
include(joinpath(SRC_DIR, "..", "scenarios.jl"))

# ============================================================
# CHANGELOG (§11)
# ============================================================
const CHANGELOG_V2 = """
v2 (개별 발전기 122기 + real-data) — 개선계획서 TASK 1~11
  - 개별 발전기 122기 (클러스터링 없음), MATPOWER KPG193 기반
  - heat_rate/vom 제거: 한국 CBP 시장 — gencost에 열소비율 내포
  - §1  potential 재구성 (가정: 2024 발전량 ≡ potential, max CF<1)
  - §2  BidderType mixture (aggressive/moderate/conservative/PPA_locked)
  - §3  Case_A_zero ≡ ρ=0 baseline (bidding_active=false), ε_nonbid=100
  - §5  RE Pmin = min(α·installed_mw, avail) (installed_mw 누락 시 fallback)
  - §6  Beta(α,β) mixture + common shock 몬테카를로
  - §7  활성 marginal 전체 갱신 + 1/n_marg 정규화
  - §8  Tikhonov L2 shrinkage (λη=0.05/iter)
  - §9  curtailment_free calibration (RE must-take, dual purity)
  - §10 Train/test/buffer split (계절 ±3일 buffer) + 3D adder G×24×S
  - §11 sanity assert: |SMP_post_A − SMP_pre| < 1
"""

const OUT_DIR = joinpath(SRC_DIR, "..", "..", "all_gen_real_system_outputs")

# ============================================================
# 메인 파이프라인
# ============================================================
function main()
    println("=" ^ 78)
    println("  전력시스템 경제 프로젝트 ─ 개별 발전기 122기 파이프라인 v2")
    println("  재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석")
    println("  실행 시각: $(Dates.now())")
    println("=" ^ 78)
    println()
    println(CHANGELOG_V2)

    mkpath(OUT_DIR)

    # ================================================================
    # PHASE 0: 데이터 로딩 + 8784시간 panel 빌드
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 0: 실데이터 로딩 (CSV → 8784h panel)")
    println("─" ^ 78)

    @assert has_real_data() "processed/ 에 필수 CSV 가 없습니다."

    panel = build_full_year_panel()

    generators   = load_generators()
    unit_specs   = load_unit_specs()
    gencost_dict = load_gencost()
    nuc_off_df   = load_nuclear_must_off()
    re_cap       = load_renewables_capacity()
    fuel_monthly = load_fuel_costs_monthly()

    G = length(generators)
    println("  · 발전기 $(G)기, " *
            "PV 설비 $(round(re_cap.solar_mw, digits=0)) MW, " *
            "Wind 설비 $(round(re_cap.wind_mw, digits=0)) MW")

    # 진단: CF
    @printf("  · 2024 PV peak CF = %.3f, Wind peak CF = %.3f\n",
            maximum(panel.cf_pv), maximum(panel.cf_w))

    # ── Piecewise Linear 비용함수 ──
    pw_costs = compute_piecewise_costs(generators, gencost_dict; S=4)
    println("  · Piecewise: $(length(pw_costs)) 발전기")

    # ── Price Adder 물리적 상한 ──
    adder_bounds = compute_adder_physical_bounds(generators, unit_specs)

    # ================================================================
    # PHASE 1: Train/Test/Buffer split  (§10)
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 1: Train/Test/Buffer split (§10)")
    println("─" ^ 78)

    # daily aggregate frame for compute_day_profiles
    daily = DataFrame(
        date   = panel.date,
        hour   = panel.hour,
        demand = panel.demand,
        smp    = panel.smp,
        solar  = panel.potential_pv,
        wind   = panel.potential_w,
    )
    profiles = compute_day_profiles(daily)
    split = split_train_test_buffer(profiles;
                                    per_season_test=3,
                                    per_season_train=25,
                                    buffer_days=3)

    println("  · test  $(length(split.test_dates))일")
    println("  · train $(length(split.train_dates))일")
    println("  · buffer $(length(split.buffer_dates))일")

    # ================================================================
    # PHASE 2: Multi-day Calibration  (§7+§8+§9+§10)
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 2: Multi-day Price Adder 추정 (3D G×24×S)")
    println("─" ^ 78)

    rng = MersenneTwister(2024)
    adder3, mae_history = estimate_price_adder_multi(
        generators, panel,
        split.train_dates, split.season_label;
        fuel_costs_monthly = fuel_monthly,
        n_epochs       = 10,
        learning_rate  = 0.2,
        l2_shrinkage   = 0.05,
        target_mae     = 4000.0,
        adder_bounds   = adder_bounds,
        pw_costs       = pw_costs,
        S              = 4,
        rng            = rng,
    )

    cal_df = DataFrame(epoch = 1:length(mae_history), train_mae = mae_history)
    CSV.write(joinpath(OUT_DIR, "calibration_history.csv"), cal_df)
    println("  ✓ calibration_history.csv 저장")

    # ================================================================
    # PHASE 3: 12 대표일 평가 (Pre/Post + 시나리오)
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 3: 대표일 평가 — Pre / Post / 4 시나리오")
    println("─" ^ 78)

    all_pre_rows         = DataFrame()
    all_scenario_rows    = DataFrame()
    sanity_violations    = String[]
    pre_test_metrics     = ValidationMetrics[]

    for d in split.test_dates
        season = split.season_label[d]
        season_name = season == 1 ? "spring" :
                       season == 2 ? "summer" :
                       season == 3 ? "fall"   : "winter"
        println("\n  ── $(d)  [$season_name] ──")

        dd = extract_day_input(panel, d, generators)
        fp = fuel_prices_for_month(fuel_monthly, dd.year, dd.month)

        # Nuclear must-off 적용
        day_of_year = Dates.dayofyear(d)
        adjusted_gens, offline_pairs = apply_nuclear_must_off(generators, nuc_off_df, day_of_year)
        if !isempty(offline_pairs)
            println("    Nuclear OFF: $(length(offline_pairs))기")
        end

        # PW cost 재계산 (원전 용량 변경)
        pw_costs_d = compute_piecewise_costs(adjusted_gens, gencost_dict; S=4)

        # Day-단위 ED 입력 + 해당 계절의 adder slice
        day_ed = EDInput(24, dd.demand, dd.re_gen, adjusted_gens)
        adder_d = adder_slice_for_date(adder3, d, split.season_label)
        # gencost 기반 MC matrix
        mc_d = build_effective_mc_matrix(adjusted_gens, gencost_dict, 24)
        pre_in  = PreEDInput(day_ed, mc_d, adder_d)

        pre_res = solve_pre_ed(pre_in; pw_costs=pw_costs_d, curtailment_free=false)
        if pre_res.status != :OPTIMAL
            @warn "Pre ED 실패: $d"
            continue
        end

        m_pre = compute_metrics(pre_res.smp, dd.smp)
        push!(pre_test_metrics, m_pre)
        @printf("    Pre  MAE=%.0f RMSE=%.0f mean[mod=%.0f act=%.0f]\n",
                m_pre.mae, m_pre.rmse, m_pre.mean_model, m_pre.mean_actual)

        # Pre 결과 누적
        for t in 1:24
            push!(all_pre_rows, (
                date         = d,
                hour         = t - 1,
                season       = season_name,
                demand       = dd.demand[t],
                pv_pot       = dd.potential_pv[t],
                wind_pot     = dd.potential_w[t],
                smp_pre      = pre_res.smp[t],
                smp_actual   = dd.smp[t],
                error_pre    = pre_res.smp[t] - dd.smp[t],
                curt_pre     = pre_res.curtailment[t],
            ); promote=true)
        end

        # Post 시나리오 (4 cases)
        sc_results = run_scenarios(
            pre_in, pre_res,
            dd.potential_pv, dd.potential_w;
            scenarios     = default_scenarios(beta=2.0, rho_pv=0.3, rho_w=0.3),
            pw_costs      = pw_costs_d,
            re_pmin_frac  = 0.1,
            installed_pv  = re_cap.solar_mw,
            installed_w   = re_cap.wind_mw,
            epsilon_nonbid= 100.0,
        )

        # §11 검증
        for r in sc_results
            if r.config.name == "Case_A_zero"
                max_dev = maximum(abs.(r.post_result.base.smp .- pre_res.smp))
                if max_dev > 1.0
                    push!(sanity_violations,
                          "$(d) Case_A_zero max|ΔSMP|=$(round(max_dev, digits=2))")
                end
            end
        end

        for r in sc_results
            for t in 1:24
                push!(all_scenario_rows, (
                    date            = d,
                    hour            = t - 1,
                    season          = season_name,
                    scenario        = r.config.name,
                    smp_pre         = pre_res.smp[t],
                    smp_post        = r.post_result.base.smp[t],
                    delta           = r.delta_smp["delta_smp"][t],
                    curt_post       = r.curtailment.by_hour[t],
                ); promote=true)
            end
        end
    end

    CSV.write(joinpath(OUT_DIR, "pre_result.csv"),     all_pre_rows)
    CSV.write(joinpath(OUT_DIR, "scenario_hourly.csv"), all_scenario_rows)
    println("\n  ✓ pre_result.csv / scenario_hourly.csv 저장")

    # 검증 결과
    if !isempty(pre_test_metrics)
        println("\n  ── Pre ED 평균 검증지표 (test 12일) ──")
        @printf("  · mean MAE  : %.0f 원/MWh\n", mean(m.mae for m in pre_test_metrics))
        @printf("  · mean RMSE : %.0f 원/MWh\n", mean(m.rmse for m in pre_test_metrics))
    end

    println("\n  ── §11 sanity check ──")
    if isempty(sanity_violations)
        println("  ✓ Case_A_zero compatibility 통과 (모든 12일 |ΔSMP| < 1 원/MWh)")
    else
        println("  ⚠ compatibility 위반:")
        for v in sanity_violations
            println("      · $v")
        end
    end

    # ================================================================
    # PHASE 4: 정책 침투도 시나리오 (S1/S2/S3)
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 4: 정책 침투도 시나리오 (S1/S2/S3)")
    println("─" ^ 78)

    rep_date = first(split.test_dates)
    println("  · 평가 기준일: $rep_date")

    dd_r = extract_day_input(panel, rep_date, generators)
    fp_r = fuel_prices_for_month(fuel_monthly, dd_r.year, dd_r.month)

    # Nuclear must-off 적용
    day_of_year_r = Dates.dayofyear(rep_date)
    adjusted_gens_r, _ = apply_nuclear_must_off(generators, nuc_off_df, day_of_year_r)
    pw_costs_r = compute_piecewise_costs(adjusted_gens_r, gencost_dict; S=4)
    mc_r = build_effective_mc_matrix(adjusted_gens_r, gencost_dict, 24)

    adder_r = adder_slice_for_date(adder3, rep_date, split.season_label)
    pre_in_r = PreEDInput(EDInput(24, dd_r.demand, dd_r.re_gen, adjusted_gens_r), mc_r, adder_r)
    pre_res_r = solve_pre_ed(pre_in_r; pw_costs=pw_costs_r, curtailment_free=false)

    penetration_rows = DataFrame()
    for scen_name in ["S1_Early", "S2_Mature", "S3_Aggressive"]
        println("\n  [$scen_name]")
        btypes = bidder_types_for_scenario(scen_name)

        mc = run_monte_carlo_scenarios(
            pre_in_r, pre_res_r, dd_r.potential_pv, dd_r.potential_w;
            n_samples       = 100,
            beta            = 2.0,
            rec_price       = 80.0,
            rho_pv          = 0.3,
            rho_w           = 0.3,
            bidder_types    = btypes,
            common_shock_sd = 0.10,
            installed_pv    = re_cap.solar_mw,
            installed_w     = re_cap.wind_mw,
            seed            = 2024,
            pw_costs        = pw_costs_r,
            re_pmin_frac    = 0.1,
            epsilon_nonbid  = 100.0,
        )

        for t in 1:24
            push!(penetration_rows, (
                scenario      = scen_name,
                hour          = t - 1,
                smp_pre       = pre_res_r.smp[t],
                mc_mean_smp   = mc.mean_smp[t],
                mc_p5_smp     = mc.p5_smp[t],
                mc_p95_smp    = mc.p95_smp[t],
                mc_delta      = mc.mean_smp[t] - pre_res_r.smp[t],
                mc_mean_curt  = mc.mean_curtailment[t],
            ); promote=true)
        end
    end
    CSV.write(joinpath(OUT_DIR, "penetration_scenarios.csv"), penetration_rows)
    println("  ✓ penetration_scenarios.csv 저장")

    # ================================================================
    # PHASE 5: 민감도 (β / ρ)
    # ================================================================
    println("\n" * "─" ^ 78)
    println("  PHASE 5: 민감도 분석 (β, ρ)")
    println("─" ^ 78)

    println("\n  [β 민감도]")
    beta_results = run_beta_sensitivity(
        pre_in_r, pre_res_r, dd_r.potential_pv, dd_r.potential_w;
        betas        = [1.5, 2.0, 2.5],
        scenario     = "mixed",
        rho_pv       = 0.3, rho_w = 0.3,
        pw_costs     = pw_costs_r,
        re_pmin_frac = 0.1,
        installed_pv = re_cap.solar_mw,
        installed_w  = re_cap.wind_mw,
    )
    if !isempty(beta_results)
        CSV.write(joinpath(OUT_DIR, "sensitivity_beta.csv"),
                  scenario_summary_table(beta_results))
        println("  ✓ sensitivity_beta.csv 저장")
    end

    println("\n  [ρ 민감도]")
    rho_results = run_rho_sensitivity(
        pre_in_r, pre_res_r, dd_r.potential_pv, dd_r.potential_w;
        rhos         = [0.1, 0.2, 0.3, 0.5],
        scenario     = "mixed",
        beta         = 2.0,
        pw_costs     = pw_costs_r,
        re_pmin_frac = 0.1,
        installed_pv = re_cap.solar_mw,
        installed_w  = re_cap.wind_mw,
    )
    if !isempty(rho_results)
        CSV.write(joinpath(OUT_DIR, "sensitivity_rho.csv"),
                  scenario_summary_table(rho_results))
        println("  ✓ sensitivity_rho.csv 저장")
    end

    # ================================================================
    # PHASE 6: CHANGELOG + 완료
    # ================================================================
    println("\n" * "=" ^ 78)
    println("  파이프라인 완료")
    println("=" ^ 78)

    open(joinpath(OUT_DIR, "CHANGELOG.md"), "w") do io
        println(io, "# CHANGELOG")
        println(io)
        println(io, "Generated: $(Dates.now())")
        println(io)
        println(io, CHANGELOG_V2)
    end
    println("  ✓ CHANGELOG.md 저장")

    println("\n  outputs/ 파일 목록:")
    for f in sort(readdir(OUT_DIR))
        fp = joinpath(OUT_DIR, f)
        if isfile(fp)
            kb = round(filesize(fp) / 1024, digits=1)
            println("    $f  ($(kb) KB)")
        end
    end
    println("=" ^ 78)
end

# 실행
main()
