# ============================================================
# verify_blocks.jl — RE 블록 생성·적용·SMP 결정 검증 (실데이터 버전)
# ============================================================
# 실행: julia --project=. all_gen_real_system/all_gen_real_system_src/verify_blocks.jl
# ============================================================

using Printf

include(joinpath(@__DIR__, "types.jl"))
include(joinpath(@__DIR__, "load_data.jl"))
include(joinpath(@__DIR__, "preprocess.jl"))
include(joinpath(@__DIR__, "build_basic_ed.jl"))
include(joinpath(@__DIR__, "build_pre_ed.jl"))
include(joinpath(@__DIR__, "build_post_ed.jl"))
include(joinpath(@__DIR__, "calibrate.jl"))
include(joinpath(@__DIR__, "scenarios.jl"))

println("=" ^ 74)
println("  RE 블록 생성·적용·SMP 결정 상세 검증 (6블록 + Piecewise)")
println("  실데이터 122기 기반")
println("=" ^ 74)

# ── 실제 데이터 준비 ──
@assert has_real_data() "processed/ 에 필수 CSV 가 없습니다."

panel = build_full_year_panel()
generators = load_generators()
gencost_dict = load_gencost()
unit_specs = load_unit_specs()
re_cap = load_renewables_capacity()
fuel_monthly = load_fuel_costs_monthly()
nuc_off_df = load_nuclear_must_off()

# 대표일 선정 → 첫 번째 대표일 사용
using DataFrames, Dates
daily = DataFrame(
    date   = panel.date,
    hour   = panel.hour,
    demand = panel.demand,
    smp    = panel.smp,
    solar  = panel.potential_pv,
    wind   = panel.potential_w,
)
profiles = compute_day_profiles(daily)
rep_days = select_representative_days(profiles)
test_date = Date(rep_days[1])
println("\n  검증 기준일: $test_date")

dd = extract_day_input(panel, test_date, generators)
fp = fuel_prices_for_month(fuel_monthly, dd.year, dd.month)

# Nuclear must-off 적용
day_of_year = Dates.dayofyear(test_date)
adjusted_gens, offline_pairs = apply_nuclear_must_off(generators, nuc_off_df, day_of_year)
if !isempty(offline_pairs)
    println("  Nuclear OFF: $(length(offline_pairs))기")
end

# Piecewise cost & Adder bounds
pw_costs = compute_piecewise_costs(adjusted_gens, gencost_dict; S=4)
adder_bounds = compute_adder_physical_bounds(adjusted_gens, unit_specs)

# Calibration
base_input = EDInput(24, dd.demand, dd.re_gen, adjusted_gens)
adder, _ = estimate_price_adder(base_input, dd.smp;
    fuel_prices=fp, max_iter=15, target_mae=3000.0, learning_rate=0.3,
    l2_shrinkage=0.05, adder_bounds=adder_bounds, pw_costs=pw_costs,
    curtailment_free=true)

mc_matrix = build_effective_mc_matrix(adjusted_gens, gencost_dict, 24)
pre_input = PreEDInput(base_input, mc_matrix, adder)
pre_result = solve_pre_ed(pre_input; pw_costs=pw_costs, curtailment_free=false)

avail_pv = dd.potential_pv
avail_w = dd.potential_w

# ================================================================
# 검증 1: RE 블록 생성 확인 (4개 시나리오 × 6블록 + installed_mw)
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 1: RE 블록 생성 — 시나리오별 6블록 구조 확인 (installed_mw 포함)")
println("─" ^ 74)

for sc_name in ["zero", "floor", "mixed", "conservative"]
    blocks, re_nonbid = build_mainland_re_blocks(avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0, rho_pv=0.3, rho_w=0.3,
        installed_pv=re_cap.solar_mw, installed_w=re_cap.wind_mw)

    println("\n  ▶ Scenario: $sc_name ($(length(blocks))블록)")
    for (i, b) in enumerate(blocks)
        bid_val = b.bid[12]
        avail_noon = b.avail[12]
        @printf("    Block %d [%-10s]: bid=%+10.0f 원/MWh, avail(noon)=%8.0f MW, inst=%.0f MW\n",
                i, b.name, bid_val, avail_noon, b.installed_mw)
    end
    @printf("    re_nonbid(noon) = %.0f MW\n", re_nonbid[12])
end

# ================================================================
# 검증 2: Post-ED LP 풀기 + Dual Pollution 확인 (epsilon_nonbid + bidding_active)
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 2: Post-ED SMP (Dual Pollution 수정 + epsilon_nonbid + bidding_active)")
println("─" ^ 74)

for sc_name in ["zero", "floor", "mixed", "conservative"]
    println("\n  ══ 시나리오: $sc_name ══")

    is_zero = sc_name == "zero"
    rho_pv_sc = is_zero ? 0.0 : 0.3
    rho_w_sc = is_zero ? 0.0 : 0.3

    post_input = make_post_input(pre_input, avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0,
        rho_pv=rho_pv_sc, rho_w=rho_w_sc,
        installed_pv=re_cap.solar_mw, installed_w=re_cap.wind_mw)
    post_result = solve_post_ed(post_input; pw_costs=pw_costs, re_pmin_frac=0.1,
        epsilon_nonbid=100.0, bidding_active=!is_zero)

    max_abs_smp = maximum(abs.(post_result.base.smp))
    dual_clean = max_abs_smp < 400000
    @printf("    max|SMP| = %.0f → %s\n", max_abs_smp,
            dual_clean ? "✓ Dual 오염 없음" : "✗ Dual 오염 의심!")

    # §11 Case_A_zero 검증
    if is_zero
        max_dev = maximum(abs.(post_result.base.smp .- pre_result.smp))
        @printf("    §11 Case_A_zero: max|SMP_post - SMP_pre| = %.4f 원/MWh → %s\n",
                max_dev, max_dev < 1.0 ? "✓ PASS" : "✗ FAIL")
    end
end

# ================================================================
# 검증 3: 시나리오별 SMP 비교
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 3: 시나리오별 LP dual SMP 비교")
println("─" ^ 74)

smp_by_scenario = Dict{String, Vector{Float64}}()

for sc_name in ["zero", "floor", "mixed", "conservative"]
    is_zero = sc_name == "zero"
    rho_pv_sc = is_zero ? 0.0 : 0.3
    rho_w_sc = is_zero ? 0.0 : 0.3

    post_input = make_post_input(pre_input, avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0,
        rho_pv=rho_pv_sc, rho_w=rho_w_sc,
        installed_pv=re_cap.solar_mw, installed_w=re_cap.wind_mw)
    post_result = solve_post_ed(post_input; pw_costs=pw_costs, re_pmin_frac=0.1,
        epsilon_nonbid=100.0, bidding_active=!is_zero)
    smp_by_scenario[sc_name] = post_result.base.smp
end

@printf("  %4s │ %12s │ %12s │ %12s │ %12s │ %12s │\n",
        "Hour", "Pre SMP", "A(zero)", "B(floor)", "C(mixed)", "D(conserv)")
println("  " * "─" ^ 82)
for t in 1:24
    a = smp_by_scenario["zero"][t]
    b = smp_by_scenario["floor"][t]
    c = smp_by_scenario["mixed"][t]
    d = smp_by_scenario["conservative"][t]
    diff_marker = (abs(a-b) > 1 || abs(c-d) > 1 || abs(a-c) > 1) ? " ★차이" : ""
    @printf("  %4d │ %12.0f │ %12.0f │ %12.0f │ %12.0f │ %12.0f │%s\n",
            t-1, pre_result.smp[t], a, b, c, d, diff_marker)
end

println("\n" * "=" ^ 74)
println("  검증 완료")
println("=" ^ 74)
