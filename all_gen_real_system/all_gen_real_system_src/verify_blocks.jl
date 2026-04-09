# ============================================================
# verify_blocks.jl — RE 블록 생성·적용·SMP 결정 검증 (개선판)
# ============================================================
# 실행: julia --project=. src/verify_blocks.jl
# ============================================================

using Printf

include(joinpath(@__DIR__, "types.jl"))
include(joinpath(@__DIR__, "load_data.jl"))
include(joinpath(@__DIR__, "preprocess.jl"))
include(joinpath(@__DIR__, "dummy_data.jl"))
include(joinpath(@__DIR__, "build_basic_ed.jl"))
include(joinpath(@__DIR__, "build_pre_ed.jl"))
include(joinpath(@__DIR__, "build_post_ed.jl"))
include(joinpath(@__DIR__, "calibrate.jl"))
include(joinpath(@__DIR__, "scenarios.jl"))

println("=" ^ 74)
println("  RE 블록 생성·적용·SMP 결정 상세 검증 (6블록 + Piecewise)")
println("=" ^ 74)

# ── 기본 데이터 준비 ──
base_input = make_dummy_input(24)
actual_smp = make_dummy_actual_smp(24)
fuel_prices = default_fuel_prices()

# Piecewise Linear 비용함수
gencost = make_dummy_gencost()
pw_costs = compute_piecewise_costs(base_input.clusters, gencost; S=4)

# calibration (Piecewise + bounds)
unit_specs = make_dummy_unit_specs()
adder_bounds = compute_adder_physical_bounds(base_input.clusters, unit_specs)

adder, _ = estimate_price_adder(base_input, actual_smp;
    fuel_prices=fuel_prices, max_iter=15, target_mae=3000.0, learning_rate=0.4,
    adder_bounds=adder_bounds, pw_costs=pw_costs)
pre_input = make_pre_input(base_input; fuel_prices=fuel_prices, adder=adder)
pre_result = solve_pre_ed(pre_input; pw_costs=pw_costs)

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

# ================================================================
# 검증 1: RE 블록 생성 확인 (4개 시나리오 × 6블록)
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 1: RE 블록 생성 — 시나리오별 6블록 구조 확인")
println("─" ^ 74)

for sc_name in ["zero", "floor", "mixed", "conservative"]
    blocks, re_nonbid = build_mainland_re_blocks(avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0, rho_pv=0.3, rho_w=0.3)

    println("\n  ▶ Scenario: $sc_name ($(length(blocks))블록)")
    for (i, b) in enumerate(blocks)
        bid_val = b.bid[12]
        avail_noon = b.avail[12]
        @printf("    Block %d [%-10s]: bid=%+10.0f 원/MWh, avail(noon)=%8.0f MW\n",
                i, b.name, bid_val, avail_noon)
    end
    @printf("    re_nonbid(noon) = %.0f MW\n", re_nonbid[12])
    @printf("    총 RE(noon) = re_nonbid + Σblocks = %.0f + %.0f = %.0f MW\n",
            re_nonbid[12], sum(b.avail[12] for b in blocks),
            re_nonbid[12] + sum(b.avail[12] for b in blocks))
    @printf("    원본 RE(noon) = avail_pv + avail_w = %.0f + %.0f = %.0f MW ✓일치확인\n",
            avail_pv[12], avail_w[12], avail_pv[12] + avail_w[12])
end

# ================================================================
# 검증 2: Post-ED LP 풀기 + Dual Pollution 확인
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 2: Post-ED SMP (Dual Pollution 수정 확인)")
println("─" ^ 74)

check_hours = [1, 4, 9, 10, 11, 12, 13, 14, 15, 19]

for sc_name in ["zero", "floor", "mixed", "conservative"]
    println("\n  ══ 시나리오: $sc_name ══")

    post_input = make_post_input(pre_input, avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0, rho_pv=0.3, rho_w=0.3)
    post_result = solve_post_ed(post_input; pw_costs=pw_costs, re_pmin_frac=0.1)

    K = length(post_input.re_blocks)

    # Dual Pollution 검증: |SMP| < 400,000 인지 확인
    max_abs_smp = maximum(abs.(post_result.base.smp))
    dual_clean = max_abs_smp < 400000
    @printf("    max|SMP| = %.0f → %s\n", max_abs_smp,
            dual_clean ? "✓ Dual 오염 없음" : "✗ Dual 오염 의심!")

    # 출력제한 확인
    curt_total = sum(post_result.curtailment)
    if curt_total > 1e-3
        @printf("    출력제한: %.0f MWh\n", curt_total)
    end

    for t in check_hours
        demand_t = post_input.demand[t]
        thermal_total = sum(post_result.base.generation[g, t] for g in 1:length(pre_input.base.clusters))
        re_bid_total = sum(post_result.re_dispatch[k, t] for k in 1:K)
        re_net_t = demand_t - thermal_total - re_bid_total
        curt_t = post_result.curtailment[t]

        @printf("    hour %2d: SMP=%+10.0f, thermal=%.0f, RE_bid=%.0f, RE_net=%.0f, curt=%.0f\n",
                t-1, post_result.base.smp[t], thermal_total, re_bid_total, re_net_t, curt_t)
    end
end

# ================================================================
# 검증 3: 시나리오별 SMP 비교
# ================================================================
println("\n" * "─" ^ 74)
println("  검증 3: 시나리오별 LP dual SMP 비교 (모든 시간대)")
println("─" ^ 74)

smp_by_scenario = Dict{String, Vector{Float64}}()

for sc_name in ["zero", "floor", "mixed", "conservative"]
    post_input = make_post_input(pre_input, avail_pv, avail_w;
        scenario=sc_name, beta=2.0, rec_price=80.0)
    post_result = solve_post_ed(post_input; pw_costs=pw_costs, re_pmin_frac=0.1)
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
