# ============================================================
# run_basic.jl  ─  Basic ED 실행 스크립트
# ============================================================
# 사용법:
#   cd project/
#   julia setup.jl              # 최초 1회: 패키지 설치
#   julia --project=. src/run_basic.jl   # Basic ED 실행
# ============================================================

using Printf
using CSV
using DataFrames
using Dates

# 소스 파일 로드 (include 순서 중요: types → dummy_data → build_basic_ed)
include(joinpath(@__DIR__, "types.jl"))
include(joinpath(@__DIR__, "dummy_data.jl"))
include(joinpath(@__DIR__, "build_basic_ed.jl"))

function main()
    println("=" ^ 70)
    println("  Basic Economic Dispatch  ─  한국 육지계통 SMP 분석")
    println("  실행 시각: $(Dates.now())")
    println("=" ^ 70)

    # ── 1. 입력 데이터 생성 ──
    println("\n[1/5] 더미 데이터 생성 중...")
    input = make_dummy_input(24)
    actual_smp = make_dummy_actual_smp(24)

    println("  · 시간 수: $(input.T)")
    println("  · 클러스터 수: $(length(input.clusters))")
    println("  · 수요 범위: $(minimum(input.demand)) ~ $(maximum(input.demand)) MW")
    println("  · 재생발전 범위: $(minimum(input.re_generation)) ~ $(maximum(input.re_generation)) MW")
    println("  · 순수요 범위: $(minimum(input.demand .- input.re_generation)) ~ " *
            "$(maximum(input.demand .- input.re_generation)) MW")

    # 클러스터 정보 출력
    println("\n  ┌─ 열발전 클러스터 ──────────────────────────────────────────┐")
    @printf("  │ %-16s │ %-8s │ %8s │ %8s │ %10s │\n",
            "Name", "Fuel", "Pmin", "Pmax", "MC(원/MWh)")
    println("  ├──────────────────┼──────────┼──────────┼──────────┼────────────┤")
    for c in input.clusters
        @printf("  │ %-16s │ %-8s │ %8.0f │ %8.0f │ %10.0f │\n",
                c.name, c.fuel, c.pmin, c.pmax, c.marginal_cost)
    end
    println("  └──────────────────┴──────────┴──────────┴──────────┴────────────┘")

    # ── 2. Basic ED 풀기 ──
    println("\n[2/5] Basic ED 최적화 중...")
    result = solve_basic_ed(input)

    if result.status != :OPTIMAL
        println("  ✗ 최적화 실패: $(result.status)")
        println("    → 수요 대비 공급용량이 부족하거나 데이터 오류를 확인하세요.")
        return
    end
    println("  ✓ 최적화 완료 (status: $(result.status))")
    @printf("  · 총 발전비용: %,.0f 원\n", result.total_cost)

    # ── 3. 결과 출력 ──
    println("\n[3/5] 시간대별 결과:")
    println("  ┌──────┬──────────┬──────────┬──────────┬────────────┬────────────┬────────────┐")
    @printf("  │ %4s │ %8s │ %8s │ %8s │ %10s │ %10s │ %10s │\n",
            "Hour", "Demand", "RE", "NetDem", "SMP(모형)", "SMP(실제)", "오차")
    println("  ├──────┼──────────┼──────────┼──────────┼────────────┼────────────┼────────────┤")
    for t in 1:24
        err = result.smp[t] - actual_smp[t]
        @printf("  │ %4d │ %8.0f │ %8.0f │ %8.0f │ %10.0f │ %10.0f │ %+10.0f │\n",
                t-1, input.demand[t], input.re_generation[t],
                input.demand[t] - input.re_generation[t],
                result.smp[t], actual_smp[t], err)
    end
    println("  └──────┴──────────┴──────────┴──────────┴────────────┴────────────┴────────────┘")

    # ── 4. 검증지표 ──
    println("\n[4/5] 검증지표:")
    metrics = compute_basic_metrics(result, actual_smp)
    @printf("  · MAE:  %,.0f 원/MWh\n", metrics["MAE"])
    @printf("  · RMSE: %,.0f 원/MWh\n", metrics["RMSE"])
    @printf("  · 최대 절대오차: %,.0f 원/MWh\n", metrics["max_error"])
    @printf("  · 모형 평균 SMP: %,.0f 원/MWh\n", metrics["mean_smp_model"])
    @printf("  · 실제 평균 SMP: %,.0f 원/MWh\n", metrics["mean_smp_actual"])

    # 한계연료원 분석
    marginal_fuels = identify_marginal_fuel(result, input)
    fuel_counts = Dict{String, Int}()
    for f in marginal_fuels
        fuel_counts[f] = get(fuel_counts, f, 0) + 1
    end
    println("\n  · 한계연료원별 SMP 결정 횟수:")
    for (fuel, count) in sort(collect(fuel_counts), by=x->-x[2])
        @printf("    %-10s : %d시간 (%4.1f%%)\n", fuel, count, 100.0 * count / 24)
    end

    # 클러스터별 발전량 요약
    println("\n  · 클러스터별 일일 발전량 [MWh]:")
    for g in 1:length(input.clusters)
        daily_gen = sum(result.generation[g, :])
        cap_factor = daily_gen / (input.clusters[g].pmax * 24) * 100
        @printf("    %-16s : %12,.0f MWh (이용률 %5.1f%%)\n",
                input.clusters[g].name, daily_gen, cap_factor)
    end

    # ── 5. CSV 저장 ──
    println("\n[5/5] 결과 CSV 저장 중...")
    output_dir = joinpath(@__DIR__, "..", "outputs")
    mkpath(output_dir)

    # 시간대별 결과
    df = DataFrame(
        hour = 0:23,
        demand_MW = input.demand,
        re_MW = input.re_generation,
        net_demand_MW = input.demand .- input.re_generation,
        smp_model = result.smp,
        smp_actual = actual_smp,
        smp_error = result.smp .- actual_smp,
        marginal_fuel = marginal_fuels,
    )

    # 클러스터별 발전량도 추가
    for g in 1:length(input.clusters)
        df[!, Symbol(input.clusters[g].name * "_MW")] = result.generation[g, :]
    end

    csv_path = joinpath(output_dir, "basic_result.csv")
    CSV.write(csv_path, df)
    println("  ✓ 저장 완료: $csv_path")

    # 요약 지표 CSV
    summary_df = DataFrame(
        metric = ["MAE", "RMSE", "max_error", "mean_smp_model", "mean_smp_actual", "total_cost"],
        value = [
            metrics["MAE"], metrics["RMSE"], metrics["max_error"],
            metrics["mean_smp_model"], metrics["mean_smp_actual"],
            result.total_cost
        ]
    )
    summary_path = joinpath(output_dir, "basic_summary.csv")
    CSV.write(summary_path, summary_df)
    println("  ✓ 저장 완료: $summary_path")

    println("\n" * "=" ^ 70)
    println("  Basic ED 완료. Pre-revision ED에서 정합도를 개선할 예정입니다.")
    println("=" ^ 70)
end

# 실행
main()
