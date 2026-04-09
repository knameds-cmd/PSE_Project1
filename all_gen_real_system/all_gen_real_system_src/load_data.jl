# ============================================================
# load_data.jl  ─  CSV 데이터 로딩 (개별 발전기 122기 버전)
# ============================================================
# processed/ 폴더의 CSV 파일을 읽어 Julia 자료형으로 변환.
# 의존: types.jl (상위에서 include 완료)
# ============================================================

using CSV
using DataFrames
using Dates

# ── 상수: 데이터 폴더 경로 ──
const DATA_RAW       = joinpath(@__DIR__, "..", "all_gen_real_system_data", "raw_data")
const DATA_PROCESSED = joinpath(@__DIR__, "..", "all_gen_real_system_data", "processed")

# ============================================================
# 1. SMP·수요 시계열 로딩
# ============================================================
"""
    load_smp_demand(filepath) -> DataFrame

smp_demand.csv 로딩.
컬럼: date, hour, smp_mainland (원/MWh), demand_mainland (MW)
"""
function load_smp_demand(filepath::String=joinpath(DATA_PROCESSED, "smp_demand.csv"))
    df = CSV.read(filepath, DataFrame)
    # 컬럼명 정규화
    rename_map = Dict{String,Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("date", lc) || occursin("날짜", lc)
            rename_map[col] = :date
        elseif occursin("hour", lc) || occursin("시간", lc)
            rename_map[col] = :hour
        elseif occursin("smp", lc)
            rename_map[col] = :smp_mainland
        elseif occursin("demand", lc)
            rename_map[col] = :demand_mainland
        end
    end
    for (old, new) in rename_map
        if old != String(new)
            rename!(df, old => new)
        end
    end
    return df
end

# ============================================================
# 2. 재생에너지 발전량 로딩
# ============================================================
"""
    load_renewable(filepath) -> DataFrame

renewables_generation_mwh.csv 로딩.
컬럼: date, hour, solar_mainland (MW), wind_mainland (MW)
"""
function load_renewable(filepath::String=joinpath(DATA_PROCESSED, "renewables_generation_mwh.csv"))
    df = CSV.read(filepath, DataFrame)
    rename_map = Dict{String,Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("date", lc)
            rename_map[col] = :date
        elseif occursin("hour", lc)
            rename_map[col] = :hour
        elseif occursin("solar", lc)
            rename_map[col] = :solar_mainland
        elseif occursin("wind", lc)
            rename_map[col] = :wind_mainland
        end
    end
    for (old, new) in rename_map
        if old != String(new)
            rename!(df, old => new)
        end
    end
    return df
end

# ============================================================
# 3. 개별 발전기 122기 로딩
# ============================================================
"""
    load_generators(filepath) -> Vector{ThermalGenerator}

generators.csv에서 122기의 개별 발전기 데이터를 로딩하여 ThermalGenerator 벡터로 반환.
컬럼: name, fuel, pmin, pmax, ramp_up, ramp_down, marginal_cost
must_run은 fuel == "Nuclear" 인 경우 true.
"""
function load_generators(filepath::String=joinpath(DATA_PROCESSED, "generators.csv"))
    df = CSV.read(filepath, DataFrame)
    generators = ThermalGenerator[]

    for row in eachrow(df)
        gen = ThermalGenerator(
            String(row.name),
            String(row.fuel),
            Float64(row.pmin),
            Float64(row.pmax),
            Float64(row.ramp_up),
            Float64(row.ramp_down),
            lowercase(String(row.fuel)) == "nuclear",  # must_run
            Float64(row.marginal_cost)
        )
        push!(generators, gen)
    end

    println("  발전기 $(length(generators))기 로딩 완료")
    fuel_counts = Dict{String,Int}()
    for g in generators
        fuel_counts[g.fuel] = get(fuel_counts, g.fuel, 0) + 1
    end
    for (fuel, cnt) in sort(collect(fuel_counts))
        total_cap = sum(g.pmax for g in generators if g.fuel == fuel)
        println("    $fuel: $(cnt)기, 총용량 $(round(total_cap, digits=0)) MW")
    end

    return generators
end

# ============================================================
# 4. Gencost (2차 비용함수 계수) 로딩
# ============================================================
"""
    load_gencost(filepath) -> Dict{String, Tuple{Float64,Float64,Float64}}

gencost.csv에서 발전기별 비용함수 계수를 로딩.
C(P) = a·P² + b·P + c  (천원/h 단위)
반환: Dict(발전기명 => (a, b, c))
"""
function load_gencost(filepath::String=joinpath(DATA_PROCESSED, "gencost.csv"))
    df = CSV.read(filepath, DataFrame)
    gencost = Dict{String, Tuple{Float64,Float64,Float64}}()
    for row in eachrow(df)
        gencost[String(row.name)] = (Float64(row.a), Float64(row.b), Float64(row.c))
    end
    println("  gencost $(length(gencost))기 로딩 완료")
    return gencost
end

# ============================================================
# 5. Genthermal (기동비·최소가동시간) 로딩
# ============================================================
"""
    load_unit_specs(filepath) -> Vector{ThermalUnitSpec}

genthermal.csv에서 Price Adder 물리적 bounds 검증용 데이터를 로딩.
"""
function load_unit_specs(filepath_thermal::String=joinpath(DATA_PROCESSED, "genthermal.csv"),
                          filepath_gen::String=joinpath(DATA_PROCESSED, "generators.csv"))
    df_t = CSV.read(filepath_thermal, DataFrame)
    df_g = CSV.read(filepath_gen, DataFrame)

    specs = ThermalUnitSpec[]
    for (i, row) in enumerate(eachrow(df_t))
        name = String(row.name)
        startup_cost = Float64(row.startup1)  # 고온기동비 (천원)
        min_up_time = Float64(row.UT)         # 최소가동시간 (시간)
        pmax = Float64(df_g[i, :pmax])        # 발전기 최대출력
        push!(specs, ThermalUnitSpec(name, startup_cost, min_up_time, pmax))
    end
    println("  unit_specs $(length(specs))기 로딩 완료")
    return specs
end

# ============================================================
# 6. 연료비용 로딩
# ============================================================
"""
    load_fuel_costs(filepath) -> DataFrame

fuel_costs.csv 로딩.
컬럼: year_month, fuel, fuel_cost_won_per_gcal
"""
function load_fuel_costs(filepath::String=joinpath(DATA_PROCESSED, "fuel_costs.csv"))
    return CSV.read(filepath, DataFrame)
end

# ============================================================
# 7. Nuclear Must-Off 로딩
# ============================================================
"""
    load_nuclear_must_off(filepath) -> DataFrame

nuclear_must_off.csv 로딩.
컬럼: id, unit_name, off_start_date, off_end_date, off_start_day, off_end_day, duration_days
"""
function load_nuclear_must_off(filepath::String=joinpath(DATA_PROCESSED, "nuclear_must_off.csv"))
    return CSV.read(filepath, DataFrame)
end

# ============================================================
# 8. 연료원별 SMP 결정횟수 로딩
# ============================================================
"""
    load_marginal_fuel_counts(filepath) -> DataFrame
"""
function load_marginal_fuel_counts(filepath::String=joinpath(DATA_PROCESSED, "marginal_fuel_counts.csv"))
    return CSV.read(filepath, DataFrame)
end

# ============================================================
# 9. 통합 로딩
# ============================================================
"""
    load_all_data() -> Dict{String, Any}

processed/ 폴더의 모든 데이터를 로딩하여 Dict로 반환.
"""
function load_all_data()
    result = Dict{String, Any}()

    if !isdir(DATA_PROCESSED)
        @warn "데이터 폴더가 없습니다: $DATA_PROCESSED"
        return result
    end

    result["smp_demand"]       = load_smp_demand()
    result["renewable"]        = load_renewable()
    result["generators"]       = load_generators()
    result["gencost"]          = load_gencost()
    result["unit_specs"]       = load_unit_specs()
    result["fuel_costs"]       = load_fuel_costs()
    result["nuclear_must_off"] = load_nuclear_must_off()

    mf_path = joinpath(DATA_PROCESSED, "marginal_fuel_counts.csv")
    if isfile(mf_path)
        result["marginal_fuel"] = load_marginal_fuel_counts()
    end

    return result
end

# ============================================================
# 10. 데이터 가용 여부 확인
# ============================================================
"""
    has_real_data() -> Bool
"""
function has_real_data()
    return isdir(DATA_PROCESSED) &&
           isfile(joinpath(DATA_PROCESSED, "generators.csv")) &&
           isfile(joinpath(DATA_PROCESSED, "smp_demand.csv"))
end
