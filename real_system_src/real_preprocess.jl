## real_preprocess.jl — 실데이터 전처리 및 대표일 선정
#
# 8,784시간 데이터에서 계절별 3일 x 4계절 = 12일 대표일 선정
# 유효한계비용(effective MC) 산출 (VOM=0, 월별 연료단가 반영)
# 원전 정비에 따른 Nuclear_base 용량 동적 조정

using Statistics

# ── 계절 구분 ────────────────────────────────────────────────
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

# ── 일별 프로파일 계산 ───────────────────────────────────────
struct RealDayProfile
    date::String
    month::Int
    season::String
    max_demand::Float64
    mean_demand::Float64
    mean_smp::Float64
    total_re::Float64
    re_share::Float64       # RE / Demand 비율
    solar_share::Float64
    wind_share::Float64
end

function compute_real_day_profiles(merged::DataFrame)
    dates = unique(merged.date)
    profiles = RealDayProfile[]

    for d in dates
        day_data = filter(r -> r.date == d, merged)
        nrow(day_data) == 24 || continue

        month = parse(Int, split(d, "-")[2])
        season = get_season(month)

        total_demand = sum(day_data.demand)
        total_solar = sum(day_data.solar)
        total_wind = sum(day_data.wind)
        total_re = total_solar + total_wind

        push!(profiles, RealDayProfile(
            d, month, season,
            maximum(day_data.demand),
            mean(day_data.demand),
            mean(day_data.smp),
            total_re,
            total_re / total_demand,
            total_solar / max(total_re, 1.0),
            total_wind / max(total_re, 1.0),
        ))
    end

    println("  Day profiles computed: $(length(profiles)) days")
    return profiles
end

# ── 대표일 12일 선정 ─────────────────────────────────────────
function select_real_representative_days(profiles::Vector{RealDayProfile}; per_season::Int=3)
    selected = String[]

    for season in ["spring", "summer", "fall", "winter"]
        sp = filter(p -> p.season == season, profiles)
        isempty(sp) && continue

        # 1. 최대부하일: 일 최대수요가 가장 큰 날
        max_load_day = sp[argmax([p.max_demand for p in sp])].date

        # 2. 경부하·고재생일: RE점유율 최대 & 수요 하위 50%
        demand_median = median([p.mean_demand for p in sp])
        low_load = filter(p -> p.mean_demand <= demand_median, sp)
        if !isempty(low_load)
            high_re_day = low_load[argmax([p.re_share for p in low_load])].date
        else
            high_re_day = sp[argmax([p.re_share for p in sp])].date
        end

        # 3. 평균SMP일: 일평균 SMP가 중위수에 가장 가까운 날
        smp_median = median([p.mean_smp for p in sp])
        avg_smp_day = sp[argmin([abs(p.mean_smp - smp_median) for p in sp])].date

        # 중복 제거하면서 추가
        candidates = unique([max_load_day, high_re_day, avg_smp_day])
        for c in candidates
            if !(c in selected)
                push!(selected, c)
            end
        end

        # 이 계절에서 선정된 수 확인
        season_count = count(d -> d in [p.date for p in sp], selected)
        if season_count < per_season
            remaining = filter(p -> p.season == season && !(p.date in selected), sp)
            sort!(remaining, by=p -> abs(p.mean_smp - smp_median))
            for r in remaining
                push!(selected, r.date)
                season_count += 1
                season_count >= per_season && break
            end
        end
    end

    sort!(selected)
    println("  Representative days selected: $(length(selected)) days")
    for d in selected
        prof = first(filter(p -> p.date == d, profiles))  # profiles is in scope from caller
        println("    $d ($(prof.season)): demand=$(round(prof.max_demand))MW, SMP=$(round(prof.mean_smp))원/MWh, RE_share=$(round(prof.re_share*100, digits=1))%")
    end
    return selected
end

# ── 단일 날짜의 24시간 데이터 추출 ───────────────────────────
function extract_real_day(merged::DataFrame, date_str::String)
    day = filter(r -> r.date == date_str, merged)
    sort!(day, :hour)
    nrow(day) == 24 || error("$date_str 에 24시간 데이터가 없습니다: $(nrow(day))행")

    return (
        date = date_str,
        T = 24,
        demand = Float64.(day.demand),
        solar = Float64.(day.solar),
        wind = Float64.(day.wind),
        re_total = Float64.(day.re_total),
        smp_actual = Float64.(day.smp),
    )
end

# ── 유효한계비용(Effective MC) 산출 ──────────────────────────
# MC = HR × FuelPrice (VOM=0, 한국 CBP 시장)
function compute_real_effective_mc(clusters::Vector{ThermalCluster},
                                    fuel_dict::Dict, date_str::String, T::Int)
    G = length(clusters)
    mc_matrix = zeros(Float64, G, T)

    month_str = date_str[1:7]  # "2024-01"

    for g in 1:G
        fuel = clusters[g].fuel
        # 월별 연료단가 조회
        fuel_price = get(fuel_dict, (month_str, fuel), 0.0)

        # MC = HR × FuelPrice (VOM=0)
        mc = clusters[g].heat_rate * fuel_price

        for t in 1:T
            mc_matrix[g, t] = mc
        end
    end

    return mc_matrix
end

# ── 원전 정비에 따른 용량 조정 ────────────────────────────────
function adjust_nuclear_for_day(clusters::Vector{ThermalCluster},
                                must_off::DataFrame, date_str::String;
                                unit_cap::Float64=1000.0, total_units::Int=24,
                                min_ratio::Float64=0.75)
    # 날짜 → 연중 일수 (Day of Year)
    d = Date(date_str, "yyyy-mm-dd")
    doy = Dates.dayofyear(d)

    # 정비 중인 호기 수
    offline = 0
    for row in eachrow(must_off)
        if row.off_start_day <= doy <= row.off_end_day
            offline += 1
        end
    end

    available_units = total_units - offline
    new_pmax = available_units * unit_cap
    new_pmin = new_pmax * min_ratio

    # Nuclear_base 클러스터 찾아서 조정
    adjusted = ThermalCluster[]
    for c in clusters
        if c.fuel == "nuclear"
            push!(adjusted, adjust_cluster_capacity(c; pmin=new_pmin, pmax=new_pmax))
        else
            push!(adjusted, c)
        end
    end

    return adjusted, offline
end
