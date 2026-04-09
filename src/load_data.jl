# ============================================================
# load_data.jl  ─  CSV 데이터 로딩 모듈
# ============================================================
# 공공데이터포털·KPX에서 확보한 CSV 파일을 읽어 EDInput으로 변환.
# 파일이 아직 없으면 dummy_data.jl의 합성 데이터를 사용.
# ============================================================
# 의존: types.jl (상위에서 include 완료)
# ============================================================

using CSV
using DataFrames
using Dates

# ── 상수: 데이터 폴더 경로 ──
const DATA_RAW       = joinpath(@__DIR__, "..", "data", "raw")
const DATA_PROCESSED = joinpath(@__DIR__, "..", "data", "processed")

# ============================================================
# 1. SMP·수요 시계열 로딩  [R7]
# ============================================================
"""
    load_smp_demand(filepath) -> DataFrame

계통한계가격 및 수요예측 CSV를 읽는다.
예상 컬럼: date, hour, smp_mainland (원/MWh), demand_mainland (MW)
거래시간은 각 단위기간의 끝점이므로, hour=1은 00:00~01:00 구간을 의미.
"""
function load_smp_demand(filepath::String)
    df = CSV.read(filepath, DataFrame)

    # 컬럼명 정규화 (유연하게 대응)
    rename_map = Dict{String,Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("date", lc) || occursin("날짜", lc)
            rename_map[col] = :date
        elseif occursin("hour", lc) || occursin("시간", lc) || occursin("거래시간", lc)
            rename_map[col] = :hour
        elseif (occursin("smp", lc) || occursin("가격", lc)) && occursin("육지", lc)
            rename_map[col] = :smp_mainland
        elseif (occursin("smp", lc) || occursin("가격", lc)) && !occursin("제주", lc)
            if !haskey(rename_map, col)  # 이미 매핑된 게 없을 때만
                rename_map[col] = :smp_mainland
            end
        elseif (occursin("demand", lc) || occursin("수요", lc)) && occursin("육지", lc)
            rename_map[col] = :demand_mainland
        elseif (occursin("demand", lc) || occursin("수요", lc)) && !occursin("제주", lc)
            if !haskey(rename_map, col)
                rename_map[col] = :demand_mainland
            end
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
# 2. 재생에너지 발전량 로딩  [R12]
# ============================================================
"""
    load_renewable(filepath) -> DataFrame

지역별 시간별 태양광·풍력 발전량 CSV를 읽는다.
결과: date, hour, solar_mainland (MW), wind_mainland (MW)
"""
function load_renewable(filepath::String)
    df = CSV.read(filepath, DataFrame)

    rename_map = Dict{String,Symbol}()
    for col in names(df)
        lc = lowercase(col)
        if occursin("date", lc) || occursin("날짜", lc)
            rename_map[col] = :date
        elseif occursin("hour", lc) || occursin("시간", lc)
            rename_map[col] = :hour
        elseif occursin("solar", lc) || occursin("태양광", lc)
            rename_map[col] = :solar_mainland
        elseif occursin("wind", lc) || occursin("풍력", lc)
            # 육지 풍력만 사용
            if occursin("육지", lc) || occursin("mainland", lc) || !occursin("제주", lc)
                rename_map[col] = :wind_mainland
            end
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
# 3. 발전설비 정보 로딩  [R11][R13]
# ============================================================
"""
    load_generators(filepath) -> DataFrame

발전설비 정보 CSV를 읽는다.
예상 컬럼: name, fuel, capacity_MW, region, central_dispatch(중앙급전여부)
"""
function load_generators(filepath::String)
    df = CSV.read(filepath, DataFrame)
    return df
end

# ============================================================
# 4. 월간 연료비용 로딩  [R9]
# ============================================================
"""
    load_fuel_costs(filepath) -> DataFrame

월간 연료비용 CSV를 읽는다.
예상 컬럼: year_month, fuel_type, fuel_cost (원/Gcal 또는 원/MWh)
"""
function load_fuel_costs(filepath::String)
    df = CSV.read(filepath, DataFrame)
    return df
end

# ============================================================
# 5. 연료원별 SMP 결정 횟수 로딩  [R8]
# ============================================================
"""
    load_marginal_fuel_counts(filepath) -> DataFrame

연료원별 SMP 결정 횟수(일별) CSV를 읽는다.
예상 컬럼: date, nuclear, coal, lng, oil, ...
"""
function load_marginal_fuel_counts(filepath::String)
    df = CSV.read(filepath, DataFrame)
    return df
end

# ============================================================
# 6. 통합 로딩 함수
# ============================================================
"""
    load_all_data(raw_dir=DATA_RAW) -> Dict{String, DataFrame}

raw/ 폴더 내 모든 CSV를 자동 탐지하여 로딩.
파일명 패턴으로 데이터 종류를 판별한다.

반환: Dict("smp_demand" => df, "renewable" => df, ...)
"""
function load_all_data(raw_dir::String=DATA_RAW)
    result = Dict{String, DataFrame}()

    if !isdir(raw_dir)
        @warn "데이터 폴더가 없습니다: $raw_dir"
        return result
    end

    csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(raw_dir))

    for f in csv_files
        fpath = joinpath(raw_dir, f)
        lf = lowercase(f)

        if occursin("smp", lf) || occursin("가격", lf) || occursin("수요", lf)
            result["smp_demand"] = load_smp_demand(fpath)
            println("  ✓ SMP·수요 로딩: $f ($(nrow(result["smp_demand"]))행)")

        elseif occursin("solar", lf) || occursin("wind", lf) || occursin("태양광", lf) || occursin("풍력", lf) || occursin("재생", lf) || occursin("renewable", lf)
            result["renewable"] = load_renewable(fpath)
            println("  ✓ 재생에너지 로딩: $f ($(nrow(result["renewable"]))행)")

        elseif occursin("설비", lf) || occursin("generator", lf) || occursin("plant", lf)
            result["generators"] = load_generators(fpath)
            println("  ✓ 발전설비 로딩: $f ($(nrow(result["generators"]))행)")

        elseif occursin("연료비", lf) || occursin("fuel_cost", lf) || occursin("fuel", lf)
            result["fuel_costs"] = load_fuel_costs(fpath)
            println("  ✓ 연료비용 로딩: $f ($(nrow(result["fuel_costs"]))행)")

        elseif occursin("결정횟수", lf) || occursin("marginal", lf)
            result["marginal_fuel"] = load_marginal_fuel_counts(fpath)
            println("  ✓ 연료원별 결정횟수 로딩: $f ($(nrow(result["marginal_fuel"]))행)")

        else
            println("  ? 미분류 파일: $f")
        end
    end

    return result
end

# ============================================================
# 7. 데이터 가용 여부 확인
# ============================================================
"""
    has_real_data(raw_dir=DATA_RAW) -> Bool

실제 CSV 데이터가 raw/ 폴더에 존재하는지 확인.
"""
function has_real_data(raw_dir::String=DATA_RAW)
    if !isdir(raw_dir)
        return false
    end
    csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(raw_dir))
    return length(csv_files) > 0
end
