## real_load_data.jl — 실제 2024년 데이터 로딩
#
# project/data/raw/ CSV 파일들을 로딩하여
# 기존 src/types.jl 구조체(ThermalCluster, ThermalUnitSpec 등)로 변환
#
# 2차 수정 반영: 8개 클러스터, VOM=0, CHP 제거

using CSV, DataFrames, Dates

# ── SMP + 수요 시계열 (8,784행) ──────────────────────────────
function load_real_smp_demand(raw_dir::String)
    path = joinpath(raw_dir, "smp_demand.csv")
    df = CSV.read(path, DataFrame)

    # 컬럼명 정규화
    rename_map = Dict{String, Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("날짜", lc) || occursin("date", lc)
            rename_map[col] = :date
        elseif occursin("거래시간", lc) || occursin("hour", lc)
            rename_map[col] = :hour
        elseif occursin("smp", lc)
            rename_map[col] = :smp
        elseif occursin("수요", lc) || occursin("demand", lc)
            rename_map[col] = :demand
        end
    end
    rename!(df, rename_map)

    df.date = string.(df.date)
    df.hour = Int.(df.hour)
    df.smp = Float64.(df.smp)
    df.demand = Float64.(df.demand)

    sort!(df, [:date, :hour])
    println("  SMP/Demand loaded: $(nrow(df)) rows, dates $(df.date[1]) ~ $(df.date[end])")
    return df
end

# ── 재생에너지 발전량 (8,784행) ──────────────────────────────
function load_real_renewable(raw_dir::String)
    # 파일명 패턴 매칭
    files = readdir(raw_dir)
    re_file = ""
    for f in files
        if occursin("재생", f) || (occursin("renew", lowercase(f)))
            re_file = f
            break
        end
    end
    isempty(re_file) && error("재생에너지 발전량 CSV를 찾을 수 없습니다: $raw_dir")

    df = CSV.read(joinpath(raw_dir, re_file), DataFrame)

    rename_map = Dict{String, Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("날짜", lc) || occursin("date", lc)
            rename_map[col] = :date
        elseif occursin("거래시간", lc) || occursin("hour", lc)
            rename_map[col] = :hour
        elseif occursin("태양광", lc) || occursin("solar", lc)
            rename_map[col] = :solar
        elseif occursin("풍력", lc) || occursin("wind", lc)
            rename_map[col] = :wind
        end
    end
    rename!(df, rename_map)

    df.date = string.(df.date)
    df.hour = Int.(df.hour)
    df.solar = Float64.(df.solar)
    df.wind = Float64.(df.wind)

    sort!(df, [:date, :hour])
    println("  Renewable loaded: $(nrow(df)) rows, solar max=$(round(maximum(df.solar), digits=1)) MW")
    return df
end

# ── 발전기 클러스터 (8행) ────────────────────────────────────
function load_real_generators(raw_dir::String)
    df = CSV.read(joinpath(raw_dir, "generators.csv"), DataFrame)

    clusters = ThermalCluster[]
    for row in eachrow(df)
        push!(clusters, ThermalCluster(
            string(row.name),
            string(row.fuel),
            Float64(row.pmin),
            Float64(row.pmax),
            Float64(row.ramp_up),
            Float64(row.ramp_down),
            Float64(row.heat_rate),
            Float64(row.vom),       # 0 (한국 CBP 시장)
            Bool(row.must_run),
            Float64(row.marginal_cost)
        ))
    end

    total_pmax = sum(c.pmax for c in clusters)
    println("  Generators loaded: $(length(clusters)) clusters, total Pmax=$(round(total_pmax, digits=0)) MW")
    return clusters
end

# ── 월별 연료 단가 (60행) ────────────────────────────────────
function load_real_fuel_costs(raw_dir::String)
    df = CSV.read(joinpath(raw_dir, "fuel_costs.csv"), DataFrame)

    # Dict: (year_month, fuel) → fuel_cost (원/Gcal)
    fuel_dict = Dict{Tuple{String,String}, Float64}()
    for row in eachrow(df)
        fuel_dict[(string(row.year_month), string(row.fuel))] = Float64(row.fuel_cost)
    end

    # 연간 평균도 계산
    avg_prices = Dict{String, Float64}()
    for fuel in unique(string.(df.fuel))
        vals = [row.fuel_cost for row in eachrow(df) if string(row.fuel) == fuel]
        avg_prices[fuel] = sum(vals) / length(vals)
    end

    println("  Fuel costs loaded: $(nrow(df)) rows, fuels: $(join(sort(collect(keys(avg_prices))), ", "))")
    return fuel_dict, avg_prices
end

# ── gencost (8행) ────────────────────────────────────────────
function load_real_gencost(raw_dir::String)
    df = CSV.read(joinpath(raw_dir, "gencost.csv"), DataFrame)

    gencost = Dict{String, Tuple{Float64,Float64,Float64}}()
    for row in eachrow(df)
        gencost[string(row.name)] = (Float64(row.a), Float64(row.b), Float64(row.c))
    end

    println("  Gencost loaded: $(length(gencost)) clusters")
    return gencost
end

# ── genthermal (8행) ─────────────────────────────────────────
function load_real_genthermal(raw_dir::String)
    df = CSV.read(joinpath(raw_dir, "genthermal.csv"), DataFrame)

    specs = ThermalUnitSpec[]
    for row in eachrow(df)
        push!(specs, ThermalUnitSpec(
            string(row.name),
            Float64(row.startup_cost),
            Float64(row.min_up_time),
            Float64(row.pmax_unit)
        ))
    end

    println("  Genthermal loaded: $(length(specs)) unit specs")
    return specs
end

# ── 원전 정비 일정 (18행) ────────────────────────────────────
function load_real_nuclear_must_off(raw_dir::String)
    df = CSV.read(joinpath(raw_dir, "nuclear_must_off.csv"), DataFrame)
    println("  Nuclear must-off loaded: $(nrow(df)) maintenance events")
    return df
end

# ── 연료원별 SMP 결정횟수 (366행, 선택) ──────────────────────
function load_real_marginal_fuel_counts(raw_dir::String)
    path = joinpath(raw_dir, "marginal_fuel_counts.csv")
    if !isfile(path)
        println("  Marginal fuel counts: not found (optional)")
        return nothing
    end
    df = CSV.read(path, DataFrame)
    println("  Marginal fuel counts loaded: $(nrow(df)) rows")
    return df
end

# ── 통합 로딩 함수 ───────────────────────────────────────────
function load_all_real_data(raw_dir::String)
    println("=== 실데이터 로딩 시작: $raw_dir ===")

    smp_demand = load_real_smp_demand(raw_dir)
    renewable = load_real_renewable(raw_dir)
    clusters = load_real_generators(raw_dir)
    fuel_dict, avg_fuel = load_real_fuel_costs(raw_dir)
    gencost = load_real_gencost(raw_dir)
    unit_specs = load_real_genthermal(raw_dir)
    must_off = load_real_nuclear_must_off(raw_dir)
    marginal_counts = load_real_marginal_fuel_counts(raw_dir)

    # SMP/Demand와 Renewable 병합
    merged = innerjoin(smp_demand, renewable, on=[:date, :hour])
    merged.re_total = merged.solar .+ merged.wind
    println("\n  Merged timeseries: $(nrow(merged)) rows")
    println("  Demand range: $(round(minimum(merged.demand))) ~ $(round(maximum(merged.demand))) MW")
    println("  SMP range: $(round(minimum(merged.smp))) ~ $(round(maximum(merged.smp))) 원/MWh")
    println("  RE range: $(round(minimum(merged.re_total), digits=1)) ~ $(round(maximum(merged.re_total), digits=1)) MW")

    println("=== 실데이터 로딩 완료 ===\n")

    return (
        merged = merged,
        clusters = clusters,
        fuel_dict = fuel_dict,
        avg_fuel = avg_fuel,
        gencost = gencost,
        unit_specs = unit_specs,
        must_off = must_off,
        marginal_counts = marginal_counts,
    )
end
