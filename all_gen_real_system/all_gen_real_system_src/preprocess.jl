# ============================================================
# preprocess.jl  ─  데이터 전처리 및 대표일 12일 선정 (개별 발전기 버전)
# ============================================================
# 주요 변경사항:
# - compute_effective_mc: gencost 기반 MC 계산 (heat_rate×fuel_price 방식 폐기)
# - compute_nuclear_availability: 개별 원전 발전기 on/off 처리
# 의존: types.jl (상위에서 include 완료)
# ============================================================

using DataFrames
using Statistics
using Dates

# ============================================================
# 1. 시간축 통일
# ============================================================
"""
    unify_time_index!(df::DataFrame) -> DataFrame

거래시간(끝점 표시)을 date-hour 형식으로 통일.
hour=1 → 00:00~01:00 구간 → 내부 인덱스 hour_idx=1 (00시)
"""
function unify_time_index!(df::DataFrame)
    if hasproperty(df, :hour)
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
"""
function clean_timeseries!(df::DataFrame)
    unique!(df)
    for col in names(df)
        if eltype(df[!, col]) <: Union{Missing, Number}
            vals = df[!, col]
            for i in 1:length(vals)
                if ismissing(vals[i])
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
# 3. 대표일 12일 선정
# ============================================================
struct DayProfile
    date::String
    season::String
    max_demand::Float64
    mean_smp::Float64
    solar_share::Float64
    wind_share::Float64
    evening_ramp::Float64
end

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

function compute_day_profiles(daily_data::DataFrame)
    profiles = DayProfile[]
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

        d20 = nrow(gdf) >= 21 ? demand_vec[21] : demand_vec[end]
        d14 = nrow(gdf) >= 15 ? demand_vec[15] : demand_vec[1]
        evening_ramp = d20 - d14

        push!(profiles, DayProfile(dt, season, max_demand, mean_smp,
                                   solar_share, wind_share, evening_ramp))
    end
    return profiles
end

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

        peak_day = sp[argmax([p.max_demand for p in sp])]
        push!(already_selected, peak_day.date)

        median_demand = median([p.max_demand for p in sp])
        low_load = filter(p -> p.max_demand <= median_demand && p.date ∉ already_selected, sp)
        if isempty(low_load)
            low_load = filter(p -> p.date ∉ already_selected, sp)
        end
        if !isempty(low_load)
            re_day = low_load[argmax([p.solar_share + p.wind_share for p in low_load])]
            push!(already_selected, re_day.date)
        else
            re_day = peak_day
        end

        remaining = filter(p -> p.date ∉ already_selected, sp)
        if !isempty(remaining)
            target_smp = median([p.mean_smp for p in sp])
            avg_day = remaining[argmin([abs(p.mean_smp - target_smp) for p in remaining])]
        else
            avg_day = peak_day
        end

        push!(selected, re_day.date)
        push!(selected, avg_day.date)
        push!(selected, peak_day.date)
    end

    return unique(selected)
end

# ============================================================
# 4. 대표일 데이터 추출
# ============================================================
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
# 5. 유효 한계비용 — gencost 기반 (heat_rate 방식 폐기)
# ============================================================
"""
    compute_effective_mc_from_gencost(gencost_coeff, P) -> Float64

gencost의 2차 비용함수에서 운전점 P에서의 한계비용을 계산.
C(P) = a·P² + b·P + c  (천원/h 단위)
MC = dC/dP = 2a·P + b  (천원/MWh)
→ × 1000 = 원/MWh
"""
function compute_effective_mc_from_gencost(gencost_coeff::Tuple{Float64,Float64,Float64},
                                            P::Float64)
    a, b, _ = gencost_coeff
    return (2.0 * a * P + b) * 1000.0
end

"""
    build_effective_mc_matrix(generators, gencost_dict, T) -> Matrix{Float64}

발전기×시간 유효 한계비용 행렬 **초기값** 생성 [G × T].

주의: 이 함수는 solve 전 초기 추정용.
한국 전력시장운영규칙 제2.4.2조에 따르면 증분가격은
  IP = (2 × QPC × DAOS + LPC) / TLF / 1000
으로 **실제 운전점(DAOS)**에서 계산해야 함.

따라서 이 함수의 결과는:
- solve_pre_ed에서 pw_costs 사용 시: 목적함수에 직접 사용되지 않음
  (piecewise linear이 정확한 MC를 구간별로 적용)
- solve 후: compute_actual_mc_matrix()로 실제 운전점 MC를 재계산해야 함
"""
function build_effective_mc_matrix(generators::Vector{ThermalGenerator},
                                   gencost_dict::Dict{String,Tuple{Float64,Float64,Float64}},
                                   T::Int)
    G = length(generators)
    mc_matrix = zeros(G, T)

    for g in 1:G
        gen = generators[g]
        if haskey(gencost_dict, gen.name)
            # 초기값: 중점 MC (solve 전 추정용)
            p_mid = (gen.pmin + gen.pmax) / 2.0
            base_mc = compute_effective_mc_from_gencost(gencost_dict[gen.name], p_mid)
        else
            base_mc = gen.marginal_cost
        end
        for t in 1:T
            mc_matrix[g, t] = base_mc
        end
    end

    return mc_matrix
end

"""
    compute_actual_mc_matrix(generators, gencost_dict, generation) -> Matrix{Float64}

ED solve **이후** 실제 운전점에서의 MC 행렬 계산 [G × T].

전력시장운영규칙 제2.4.2조 제4호:
  IP_{i,t} = [(2 × QPC_i × DAOS_{i,t} + LPC_i) / TLF] / 1,000

여기서 DAOS_{i,t} = generation[g, t] (ED 결과의 실제 발전량).
TLF(송전손실계수)는 현재 1.0으로 가정.
"""
function compute_actual_mc_matrix(generators::Vector{ThermalGenerator},
                                   gencost_dict::Dict{String,Tuple{Float64,Float64,Float64}},
                                   generation::Matrix{Float64})
    G, T = size(generation)
    mc_matrix = zeros(G, T)

    for g in 1:G
        gen = generators[g]
        if haskey(gencost_dict, gen.name)
            a, b, _ = gencost_dict[gen.name]
            for t in 1:T
                P = generation[g, t]
                if P > 1e-3
                    # 실제 운전점에서의 MC: (2aP + b) × 1000 원/MWh
                    mc_matrix[g, t] = (2.0 * a * P + b) * 1000.0
                else
                    # 미가동: MC를 pmin 기준으로 설정 (가격결정자격 판별용)
                    mc_matrix[g, t] = (2.0 * a * gen.pmin + b) * 1000.0
                end
            end
        else
            mc_matrix[g, :] .= gen.marginal_cost
        end
    end

    return mc_matrix
end

# 기존 코드 호환: fuel_prices 기반 함수
function build_effective_mc_matrix(generators::Vector{ThermalGenerator},
                                   fuel_prices::Dict{String,Float64},
                                   T::Int)
    G = length(generators)
    mc_matrix = zeros(G, T)
    for g in 1:G
        mc_matrix[g, :] .= generators[g].marginal_cost
    end
    return mc_matrix
end

# compute_effective_mc 호환 (calibrate.jl에서 호출됨)
function compute_effective_mc(cluster::ThermalGenerator, fuel_price::Float64)
    return cluster.marginal_cost
end

# ============================================================
# 6. 더미 연료가격 (호환용)
# ============================================================
function default_fuel_prices()
    return Dict(
        "nuclear" => 2578.0,
        "coal"    => 34260.0,
        "lng"     => 80898.0,
        "oil"     => 139934.0,
        "anthracite" => 32655.0,
    )
end

# ============================================================
# 7. Nuclear Must-Off 처리 (이름 매핑 기반)
# ============================================================

# ── 호기명 → generator_id 매핑 테이블 ──
# KPG193 .m 파일의 bus 번호 + 용량 + 초기상태로 대응
# bus 82=고리/신고리/새울, bus 124=한빛, bus 166=월성/신월성, bus 175=한울/신한울
const NUCLEAR_NAME_TO_ID = Dict{String,String}(
    "새울1호기"   => "Nuclear_001",
    "고리3호기"   => "Nuclear_002",
    "고리4호기"   => "Nuclear_003",
    "신고리1호기" => "Nuclear_004",
    "신고리2호기" => "Nuclear_005",
    "새울2호기"   => "Nuclear_006",
    "새울3호기"   => "Nuclear_007",
    "한빛1호기"   => "Nuclear_008",
    "한빛2호기"   => "Nuclear_009",
    "한빛3호기"   => "Nuclear_010",
    "한빛4호기"   => "Nuclear_011",
    "한빛5호기"   => "Nuclear_012",
    "한빛6호기"   => "Nuclear_013",
    "신한울1호기" => "Nuclear_014",
    "신한울2호기" => "Nuclear_015",
    "신월성2호기" => "Nuclear_016",
    "신월성1호기" => "Nuclear_017",
    "월성2호기"   => "Nuclear_018",
    "월성3호기"   => "Nuclear_019",
    "월성4호기"   => "Nuclear_020",
    "한울1호기"   => "Nuclear_021",
    "한울2호기"   => "Nuclear_022",
    "한울3호기"   => "Nuclear_023",
    "한울4호기"   => "Nuclear_024",
    "한울5호기"   => "Nuclear_025",
    "한울6호기"   => "Nuclear_025",  # 한울5,6 통합 모델 (fallback)
)

"""
    apply_nuclear_must_off(generators, must_off, day) -> (adjusted, offline_names)

특정 날짜(연중 일수)의 원전 정비 일정에 따라 **이름 매핑 기반으로**
해당 발전기를 pmin=0, pmax=0 으로 설정.

## 매핑 과정
1. must_off에서 해당 날짜에 정비 중인 호기명 수집 (예: "고리4호기")
2. NUCLEAR_NAME_TO_ID로 generator_id 변환 (예: "Nuclear_003")
3. generators 벡터에서 해당 name을 찾아 용량을 0으로 설정

## 반환
- adjusted: 수정된 generators 벡터
- offline_names: 정비 중인 (호기명, generator_id) 쌍 목록
"""
function apply_nuclear_must_off(generators::Vector{ThermalGenerator},
                                must_off::DataFrame,
                                day::Int)
    # 1. 해당 날짜에 정비 중인 호기명 수집
    offline_unit_names = String[]
    for row in eachrow(must_off)
        if row.off_start_day <= day <= row.off_end_day
            push!(offline_unit_names, String(row.unit_name))
        end
    end

    # 2. 호기명 → generator_id 변환
    offline_gen_ids = Set{String}()
    offline_pairs = Tuple{String,String}[]
    for uname in offline_unit_names
        if haskey(NUCLEAR_NAME_TO_ID, uname)
            gen_id = NUCLEAR_NAME_TO_ID[uname]
            push!(offline_gen_ids, gen_id)
            push!(offline_pairs, (uname, gen_id))
        else
            @warn "원전 매핑 실패: '$uname' → 매핑 테이블에 없음"
        end
    end

    # 3. 해당 generator를 pmin=0, pmax=0 으로 설정
    adjusted = copy(generators)
    for (i, gen) in enumerate(generators)
        if gen.name in offline_gen_ids
            adjusted[i] = adjust_generator_capacity(gen; pmin=0.0, pmax=0.0)
        end
    end

    return adjusted, offline_pairs
end

# 하위 호환: compute_nuclear_availability (총량 기반)
function compute_nuclear_availability(must_off::DataFrame, day::Int;
                                       unit_capacity::Float64=1000.0,
                                       total_units::Int=25,
                                       min_load_ratio::Float64=0.95)
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
# 8. 구간별 선형 근사 (Piecewise Linear) — gencost 기반
# ============================================================
"""
    compute_piecewise_costs(generators, gencost_dict; S=4) -> Vector{PiecewiseCost}

gencost의 2차 비용함수를 S개 구간으로 선형 근사.
단위 변환: gencost는 천원 → ×1000 → 원/MWh
"""
function compute_piecewise_costs(generators::Vector{ThermalGenerator},
                                  gencost_dict::Dict{String,Tuple{Float64,Float64,Float64}};
                                  S::Int=4)
    pw_costs = PiecewiseCost[]

    for (g, gen) in enumerate(generators)
        pmin = gen.must_run ? gen.pmin : 0.0
        pmax = gen.pmax

        if haskey(gencost_dict, gen.name) && (pmax - pmin) > 1e-3
            a, b, _ = gencost_dict[gen.name]

            if abs(a) < 1e-12
                # 선형 비용함수: 단일 구간
                mc = b * 1000.0  # 천원→원
                seg = PiecewiseCostSegment(pmax - pmin, mc)
                push!(pw_costs, PiecewiseCost(g, pmin, [seg]))
            else
                # 2차 비용함수: S개 구간으로 분할
                delta_bar = (pmax - pmin) / S
                segments = PiecewiseCostSegment[]

                for s in 1:S
                    p_mid = pmin + (s - 0.5) * delta_bar
                    mc_s = (2.0 * a * p_mid + b) * 1000.0  # 천원→원
                    push!(segments, PiecewiseCostSegment(delta_bar, mc_s))
                end

                push!(pw_costs, PiecewiseCost(g, pmin, segments))
            end
        else
            # gencost 없음: 단일 구간
            range = pmax - pmin
            if range > 1e-3
                seg = PiecewiseCostSegment(range, gen.marginal_cost)
            else
                seg = PiecewiseCostSegment(0.0, gen.marginal_cost)
            end
            push!(pw_costs, PiecewiseCost(g, pmin, [seg]))
        end
    end

    return pw_costs
end

