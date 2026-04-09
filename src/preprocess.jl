# ============================================================
# preprocess.jl  ─  데이터 전처리 및 대표일 12일 선정
# ============================================================
# 문서 참조: 02_프로젝트_수행 §2.1, §2.2
# 의존: types.jl (상위에서 include 완료)
# ============================================================

using DataFrames
using Statistics
using Dates

# ============================================================
# 1. 시간축 통일 (Step 1)
# ============================================================
"""
    unify_time_index!(df::DataFrame) -> DataFrame

거래시간(끝점 표시)을 date-hour 형식으로 통일.
공공데이터포털은 '각 단위기간의 끝점'으로 시간을 표시 [R7].
예: hour=1 → 00:00~01:00 구간 → 내부 인덱스 hour_idx=1 (00시)
"""
function unify_time_index!(df::DataFrame)
    if hasproperty(df, :hour)
        # 끝점 표시 → 시작점 표시로 변환 (hour 1 → 0시, hour 24 → 23시)
        if minimum(df.hour) >= 1 && maximum(df.hour) <= 24
            df.hour_idx = df.hour .- 1
        else
            df.hour_idx = df.hour
        end
    end
    return df
end

# ============================================================
# 2. 결측·중복 처리
# ============================================================
"""
    clean_timeseries!(df::DataFrame) -> DataFrame

결측치 선형보간, 중복 행 제거.
"""
function clean_timeseries!(df::DataFrame)
    # 중복 제거
    unique!(df)

    # 숫자 컬럼의 결측치를 선형보간
    for col in names(df)
        if eltype(df[!, col]) <: Union{Missing, Number}
            vals = df[!, col]
            for i in 1:length(vals)
                if ismissing(vals[i])
                    # 앞뒤 유효값으로 선형보간
                    prev_idx = findprev(!ismissing, vals, i - 1)
                    next_idx = findnext(!ismissing, vals, i + 1)
                    if !isnothing(prev_idx) && !isnothing(next_idx)
                        w = (i - prev_idx) / (next_idx - prev_idx)
                        vals[i] = vals[prev_idx] * (1 - w) + vals[next_idx] * w
                    elseif !isnothing(prev_idx)
                        vals[i] = vals[prev_idx]
                    elseif !isnothing(next_idx)
                        vals[i] = vals[next_idx]
                    end
                end
            end
        end
    end

    return df
end

# ============================================================
# 3. 대표일 12일 선정 (Step 3)  ─  문서 §2.1
# ============================================================
"""
    DayProfile

일별 지표 구조체 (대표일 선정용).
"""
struct DayProfile
    date::String
    season::String          # "spring", "summer", "fall", "winter"
    max_demand::Float64     # 일별 최대부하 [MW]
    mean_smp::Float64       # 일평균 SMP [원/MWh]
    solar_share::Float64    # 태양광 점유율 = sum(Solar)/sum(Demand)
    wind_share::Float64     # 풍력 점유율 = sum(Wind)/sum(Demand)
    evening_ramp::Float64   # 저녁 램프 = D_20 - D_14
end

"""
    get_season(month::Int) -> String

월→계절 매핑. 봄(3~5), 여름(6~8), 가을(9~11), 겨울(12~2).
"""
function get_season(month::Int)
    if month in [3, 4, 5]
        return "spring"
    elseif month in [6, 7, 8]
        return "summer"
    elseif month in [9, 10, 11]
        return "fall"
    else
        return "winter"
    end
end

"""
    compute_day_profiles(daily_data::DataFrame) -> Vector{DayProfile}

일별 데이터에서 대표일 선정용 지표를 계산.
daily_data는 date, hour(0~23), demand, smp, solar, wind 컬럼 필요.
"""
function compute_day_profiles(daily_data::DataFrame)
    profiles = DayProfile[]

    # 날짜별 그룹
    for gdf in groupby(daily_data, :date)
        dt = string(first(gdf.date))
        month = Dates.month(Date(dt))
        season = get_season(month)

        demand_vec = Float64.(gdf.demand)
        smp_vec    = Float64.(gdf.smp)
        solar_vec  = hasproperty(gdf, :solar) ? Float64.(gdf.solar) : zeros(nrow(gdf))
        wind_vec   = hasproperty(gdf, :wind) ? Float64.(gdf.wind) : zeros(nrow(gdf))

        max_demand   = maximum(demand_vec)
        mean_smp     = mean(smp_vec)
        total_demand = sum(demand_vec)
        solar_share  = total_demand > 0 ? sum(solar_vec) / total_demand : 0.0
        wind_share   = total_demand > 0 ? sum(wind_vec) / total_demand : 0.0

        # 저녁 램프: hour 20 - hour 14 (인덱스는 데이터 정렬 기준)
        d20 = nrow(gdf) >= 21 ? demand_vec[21] : demand_vec[end]  # hour=20
        d14 = nrow(gdf) >= 15 ? demand_vec[15] : demand_vec[1]    # hour=14
        evening_ramp = d20 - d14

        push!(profiles, DayProfile(dt, season, max_demand, mean_smp,
                                   solar_share, wind_share, evening_ramp))
    end

    return profiles
end

"""
    select_representative_days(profiles::Vector{DayProfile}; per_season=3) -> Vector{String}

계절별 3일씩 총 12일의 대표일을 선정한다.
각 계절에서:
  1. 경부하·고재생일: solar_share + wind_share 최대 & max_demand 하위 50%
  2. 최대부하일: max_demand 최대
  3. 평균일: mean_smp 기준 중앙값에 가장 가까운 날

반환: 선정된 날짜 문자열 목록.
"""
function select_representative_days(profiles::Vector{DayProfile}; per_season::Int=3)
    seasons = ["spring", "summer", "fall", "winter"]
    selected = String[]

    for s in seasons
        sp = filter(p -> p.season == s, profiles)
        if isempty(sp)
            @warn "계절 $s 에 해당하는 데이터가 없습니다."
            continue
        end

        already_selected = Set{String}()

        # (1) 최대부하일
        peak_day = sp[argmax([p.max_demand for p in sp])]
        push!(already_selected, peak_day.date)

        # (2) 경부하·고재생일
        median_demand = median([p.max_demand for p in sp])
        low_load = filter(p -> p.max_demand <= median_demand && p.date ∉ already_selected, sp)
        if isempty(low_load)
            low_load = filter(p -> p.date ∉ already_selected, sp)
        end
        if !isempty(low_load)
            re_day = low_load[argmax([p.solar_share + p.wind_share for p in low_load])]
            push!(already_selected, re_day.date)
        else
            re_day = peak_day  # fallback
        end

        # (3) 평균일: mean_smp 중앙값에 가장 가까운 날
        remaining = filter(p -> p.date ∉ already_selected, sp)
        if !isempty(remaining)
            target_smp = median([p.mean_smp for p in sp])
            avg_day = remaining[argmin([abs(p.mean_smp - target_smp) for p in remaining])]
        else
            avg_day = peak_day  # fallback
        end

        push!(selected, re_day.date)    # 경부하·고재생
        push!(selected, avg_day.date)   # 평균일
        push!(selected, peak_day.date)  # 최대부하
    end

    return unique(selected)
end

# ============================================================
# 4. 대표일 데이터 추출
# ============================================================
"""
    extract_day_data(full_data::DataFrame, date_str::String) -> NamedTuple

특정 날짜의 24시간 데이터를 EDInput용으로 추출.
반환: (demand=Vector, solar=Vector, wind=Vector, smp=Vector)
"""
function extract_day_data(full_data::DataFrame, date_str::String)
    day_df = filter(row -> string(row.date) == date_str, full_data)
    sort!(day_df, :hour)

    T = nrow(day_df)
    demand = Float64.(day_df.demand)
    smp    = hasproperty(day_df, :smp) ? Float64.(day_df.smp) : zeros(T)
    solar  = hasproperty(day_df, :solar) ? Float64.(day_df.solar) : zeros(T)
    wind   = hasproperty(day_df, :wind) ? Float64.(day_df.wind) : zeros(T)

    return (demand=demand, solar=solar, wind=wind, smp=smp, T=T, date=date_str)
end

# ============================================================
# 5. 유효 한계비용 생성 (Step 5)  ─  수식 (P1)
# ============================================================
"""
    compute_effective_mc(cluster::ThermalCluster, fuel_price::Float64) -> Float64

유효 한계비용 = 열소비율 × 연료단가 + VOM [원/MWh].
수식 (P1): c̃_{g,t} = HR_g × FuelPrice_{f,m} + VOM_g + A_{g,s,h}
(price adder는 calibrate.jl에서 별도 처리)
"""
function compute_effective_mc(cluster::ThermalCluster, fuel_price::Float64)
    return cluster.heat_rate * fuel_price + cluster.vom
end

"""
    build_effective_mc_matrix(clusters, fuel_prices, T) -> Matrix{Float64}

클러스터×시간 유효 한계비용 행렬 생성 [G × T].
fuel_prices: Dict(fuel_name => price) 형태.
기본적으로 시간 불변이지만, price adder 적용 시 시간별로 달라짐.
"""
function build_effective_mc_matrix(clusters::Vector{ThermalCluster},
                                   fuel_prices::Dict{String,Float64},
                                   T::Int)
    G = length(clusters)
    mc_matrix = zeros(G, T)

    for g in 1:G
        fuel = clusters[g].fuel
        fp = get(fuel_prices, fuel, 0.0)
        base_mc = compute_effective_mc(clusters[g], fp)
        for t in 1:T
            mc_matrix[g, t] = base_mc
        end
    end

    return mc_matrix
end

# ============================================================
# 6. 더미 연료가격 (실제 데이터 전 사용)
# ============================================================
"""
    default_fuel_prices() -> Dict{String, Float64}

더미 연료 단가 [원/Gcal].
실제 데이터 확보 후 월별 연료비용 CSV로 교체.
"""
function default_fuel_prices()
    return Dict(
        "nuclear" => 5000.0,    # 원/Gcal (핵연료)
        "coal"    => 30000.0,   # 원/Gcal (유연탄)
        "lng"     => 55000.0,   # 원/Gcal (LNG)
        "oil"     => 70000.0,   # 원/Gcal (유류)
        "chp"     => 45000.0,   # 원/Gcal (열병합, LNG 기반)
        "hydro"   => 0.0,       # 수력은 연료비 0 (기회비용은 VOM에)
    )
end

# ============================================================
# 7. Nuclear Must-Off 처리 (개선사항 4)
# ============================================================
"""
    load_nuclear_must_off(filepath::String) -> DataFrame

원전 계획정비(must-off) CSV 파일을 로딩.
컬럼: id, off_start_day, off_start_time, off_end_day, off_end_time
"""
function load_nuclear_must_off(filepath::String)
    return CSV.read(filepath, DataFrame)
end

"""
    compute_nuclear_availability(must_off::DataFrame, day::Int;
        unit_capacity=1000.0, total_units=24, min_load_ratio=0.75)
        -> (pmin::Float64, pmax::Float64)

특정 날짜(연중 일수)의 가용 원전 용량을 계산.

## 매개변수
- must_off: 계획정비 데이터 (load_nuclear_must_off 또는 make_dummy_nuclear_must_off)
- day: 연중 일수 (1~365)
- unit_capacity: 호기당 정격용량 [MW] (기본 1,000 MW)
- total_units: 총 원전 호기 수 (기본 24기)
- min_load_ratio: 최소출력 비율 (기본 0.75, 한국 원전 기준)

## 반환
(pmin, pmax) 가용 원전의 최소/최대 출력 [MW]
"""
function compute_nuclear_availability(must_off::DataFrame, day::Int;
                                       unit_capacity::Float64=1000.0,
                                       total_units::Int=24,
                                       min_load_ratio::Float64=0.75)
    offline_count = 0
    for row in eachrow(must_off)
        if row.off_start_day <= day <= row.off_end_day
            offline_count += 1
        end
    end

    available_units = total_units - offline_count
    pmax = available_units * unit_capacity
    pmin = pmax * min_load_ratio

    return (pmin=pmin, pmax=pmax)
end

# ============================================================
# 8. 구간별 선형 근사 (Piecewise Linear) — 개선사항 2
# ============================================================
"""
    compute_piecewise_costs(clusters::Vector{ThermalCluster},
                            gencost::Dict{String, Tuple{Float64,Float64,Float64}};
                            S::Int=4) -> Vector{PiecewiseCost}

2차 비용함수 C(P) = a·P² + b·P + c를 S개 구간으로 선형 근사.

## 매개변수
- clusters: ThermalCluster 목록
- gencost: Dict(클러스터명 => (a, b, c)) 2차 비용함수 계수
- S: 구간 수 (기본 4, 3~4이면 충분히 정확)

## 반환
클러스터별 PiecewiseCost 배열 (길이 = G).
gencost에 없는 클러스터는 1개 구간(상수 MC)으로 처리.
"""
function compute_piecewise_costs(clusters::Vector{ThermalCluster},
                                  gencost::Dict{String, Tuple{Float64,Float64,Float64}};
                                  S::Int=4)
    pw_costs = PiecewiseCost[]

    for (g, c) in enumerate(clusters)
        pmin = c.must_run ? c.pmin : 0.0
        pmax = c.pmax

        if haskey(gencost, c.name) && (pmax - pmin) > 1e-3
            a, b, _ = gencost[c.name]

            if abs(a) < 1e-12
                # 선형 비용함수: 단일 구간
                seg = PiecewiseCostSegment(pmax - pmin, b)
                push!(pw_costs, PiecewiseCost(g, pmin, [seg]))
            else
                # 2차 비용함수: S개 구간으로 분할
                delta_bar = (pmax - pmin) / S
                segments = PiecewiseCostSegment[]

                for s in 1:S
                    # 구간 중점에서의 한계비용
                    p_mid = pmin + (s - 0.5) * delta_bar
                    mc_s = 2.0 * a * p_mid + b
                    push!(segments, PiecewiseCostSegment(delta_bar, mc_s))
                end

                push!(pw_costs, PiecewiseCost(g, pmin, segments))
            end
        else
            # gencost 데이터 없음: 단일 구간, 기존 marginal_cost 사용
            range = pmax - pmin
            if range > 1e-3
                seg = PiecewiseCostSegment(range, c.marginal_cost)
            else
                seg = PiecewiseCostSegment(0.0, c.marginal_cost)
            end
            push!(pw_costs, PiecewiseCost(g, pmin, [seg]))
        end
    end

    return pw_costs
end
