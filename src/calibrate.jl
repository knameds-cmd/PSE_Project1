# ============================================================
# calibrate.jl  ─  Price Adder 추정 및 검증지표 계산
# ============================================================
# 수식 참조: 보고서용 수식정리본 §5 (Calibration)
#
# (C1) MAE  = (1/T) Σ_t |SMP_model_t - SMP_actual_t|
# (C2) RMSE = √[ (1/T) Σ_t (SMP_model_t - SMP_actual_t)² ]
# (C3) ΔSMP_t = SMP_post_t - SMP_pre_t
#
# Price adder A_{g,s,h}는 UC 미모형 요소(기동·무부하·정지 등)를
# 부분 흡수하는 계절-시간대별 보정항.
# 이 모듈은 actual SMP와의 차이를 줄이도록 adder를 반복 추정한다.
#
# [개선 1] 교차검증(cross-validation) + 물리적 bounds 검증 추가
# ============================================================
# 의존: types.jl, build_pre_ed.jl (상위에서 include 완료)
# ============================================================

using Statistics

# ============================================================
# 1. 통합 검증지표 계산
# ============================================================
"""
    ValidationMetrics

검증지표 모음.
"""
struct ValidationMetrics
    mae::Float64                    # 평균 절대오차 [원/MWh]
    rmse::Float64                   # 평균제곱근오차 [원/MWh]
    max_abs_error::Float64          # 최대 절대오차
    mean_model::Float64             # 모형 평균 SMP
    mean_actual::Float64            # 실제 평균 SMP
    hourly_errors::Vector{Float64}  # 시간대별 오차
    hourly_bias::Vector{Float64}    # 시간대별 편향 (양수=과추정)
    smp_model::Vector{Float64}      # 모형 SMP 원본 벡터
    smp_actual::Vector{Float64}     # 실제 SMP 원본 벡터
end

"""
    compute_metrics(smp_model, smp_actual) -> ValidationMetrics

모형 SMP와 실제 SMP의 검증지표를 계산.
"""
function compute_metrics(smp_model::Vector{Float64}, smp_actual::Vector{Float64})
    T = length(smp_model)
    @assert length(smp_actual) == T "SMP 벡터 길이 불일치"

    errors = smp_model .- smp_actual
    abs_errors = abs.(errors)

    mae  = mean(abs_errors)
    rmse = sqrt(mean(errors .^ 2))

    return ValidationMetrics(
        mae, rmse,
        maximum(abs_errors),
        mean(smp_model),
        mean(smp_actual),
        errors,
        errors,  # bias = signed error
        copy(smp_model),
        copy(smp_actual)
    )
end

# ============================================================
# 2. Duration Curve 비교
# ============================================================
"""
    duration_curve(smp::Vector{Float64}) -> Vector{Float64}

SMP를 내림차순 정렬한 지속곡선을 반환.
"""
function duration_curve(smp::Vector{Float64})
    return sort(smp, rev=true)
end

"""
    duration_curve_error(smp_model, smp_actual) -> Float64

지속곡선 간 평균 절대 차이.
분포가 비슷한지 검증하는 보조 지표.
"""
function duration_curve_error(smp_model::Vector{Float64}, smp_actual::Vector{Float64})
    dc_model  = duration_curve(smp_model)
    dc_actual = duration_curve(smp_actual)
    return mean(abs.(dc_model .- dc_actual))
end

# ============================================================
# 3. 연료원별 SMP 결정횟수 비교 [R8]
# ============================================================
"""
    marginal_fuel_share(fuels::Vector{String}) -> Dict{String, Float64}

한계연료원 벡터에서 연료원별 점유율(%) 계산.
"""
function marginal_fuel_share(fuels::Vector{String})
    T = length(fuels)
    counts = Dict{String, Int}()
    for f in fuels
        counts[f] = get(counts, f, 0) + 1
    end
    shares = Dict{String, Float64}()
    for (f, c) in counts
        shares[f] = 100.0 * c / T
    end
    return shares
end

# ============================================================
# 4. Price Adder 물리적 검증 (개선사항 1)
# ============================================================
"""
    compute_adder_physical_bounds(clusters::Vector{ThermalCluster},
                                  unit_specs::Vector{ThermalUnitSpec})
                                  -> Vector{Float64}

클러스터별 Price Adder의 물리적 상한을 계산.

기동비/최소가동시간/호기용량에서 도출:
  adder_max = startup_cost_원 / min_up_time / pmax_unit

예: LNG CC: 47,400,000원 / 4h / 880MW ≈ 13,466 원/MWh

반환: 길이 G의 벡터 (클러스터별 adder 상한, 원/MWh)
"""
function compute_adder_physical_bounds(clusters::Vector{ThermalCluster},
                                        unit_specs::Vector{ThermalUnitSpec})
    G = length(clusters)
    bounds = fill(Inf, G)  # 기본값: 무한대 (제한 없음)

    spec_dict = Dict(s.name => s for s in unit_specs)

    for g in 1:G
        name = clusters[g].name
        if haskey(spec_dict, name)
            spec = spec_dict[name]
            if spec.min_up_time > 0 && spec.pmax_unit > 0
                # startup_cost는 천원 단위 → 원 단위 변환
                startup_won = spec.startup_cost * 1000.0
                bounds[g] = startup_won / spec.min_up_time / spec.pmax_unit
            end
        end
    end

    return bounds
end

"""
    validate_adder_bounds(adder::Matrix{Float64},
                          bounds::Vector{Float64},
                          cluster_names::Vector{String}) -> Bool

Price Adder가 물리적 상한 내에 있는지 검증.
위반 시 경고를 출력하고 false를 반환.
"""
function validate_adder_bounds(adder::Matrix{Float64},
                                bounds::Vector{Float64},
                                cluster_names::Vector{String})
    G, T = size(adder)
    all_ok = true

    for g in 1:G
        if bounds[g] < Inf
            max_adder_g = maximum(abs.(adder[g, :]))
            if max_adder_g > bounds[g] * 1.5  # 50% 여유 허용
                @warn "Price Adder 물리적 범위 초과: $(cluster_names[g]) " *
                      "max|adder|=$(round(max_adder_g, digits=0)) > " *
                      "bound=$(round(bounds[g], digits=0)) 원/MWh (×1.5)"
                all_ok = false
            end
        end
    end

    return all_ok
end

# ============================================================
# 5. Price Adder 추정 ─ 반복 보정법 (물리적 bounds 포함)
# ============================================================
"""
    estimate_price_adder(base_input::EDInput,
                         actual_smp::Vector{Float64};
                         fuel_prices=nothing,
                         max_iter=20,
                         target_mae=5000.0,
                         learning_rate=0.3,
                         adder_bounds=nothing,
                         pw_costs=PiecewiseCost[]) -> (Matrix{Float64}, Vector{ValidationMetrics})

actual SMP와의 차이를 줄이도록 price adder를 반복 추정한다.

## 알고리즘
1. adder = 0 으로 시작
2. Pre ED를 풀어 SMP 추출
3. 클러스터별 시간대별 오차를 adder에 반영
   - 한계 클러스터(부분 투입)의 adder만 조정
   - adder[g,t] += learning_rate × (actual_smp[t] - model_smp[t])
4. [개선 1] adder_bounds로 물리적 범위 clamp
5. MAE < target_mae 이면 종료, 아니면 2로

## 반환
- adder: [G × T] 최종 price adder 행렬
- history: 각 반복의 ValidationMetrics 기록
"""
function estimate_price_adder(base_input::EDInput,
                               actual_smp::Vector{Float64};
                               fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing,
                               max_iter::Int=20,
                               target_mae::Float64=5000.0,
                               learning_rate::Float64=0.3,
                               adder_bounds::Union{Nothing, Vector{Float64}}=nothing,
                               pw_costs::Vector{PiecewiseCost}=PiecewiseCost[])
    T = base_input.T
    G = length(base_input.clusters)

    if isnothing(fuel_prices)
        fuel_prices = default_fuel_prices()
    end

    adder = zeros(G, T)
    history = ValidationMetrics[]

    for iter in 1:max_iter
        # Pre ED 풀기
        pre_input = make_pre_input(base_input; fuel_prices=fuel_prices, adder=adder)
        result = solve_pre_ed(pre_input; pw_costs=pw_costs)

        if result.status != :OPTIMAL
            @warn "Calibration iter $iter: Pre ED 실패"
            break
        end

        # 검증지표
        metrics = compute_metrics(result.smp, actual_smp)
        push!(history, metrics)

        println("  [Calibration iter $iter] MAE=$(round(metrics.mae, digits=0)) 원/MWh, " *
                "RMSE=$(round(metrics.rmse, digits=0)) 원/MWh")

        # 수렴 체크
        if metrics.mae < target_mae
            println("  ✓ 목표 MAE 달성 ($(round(metrics.mae, digits=0)) < $target_mae)")
            break
        end

        # Price adder 업데이트
        for t in 1:T
            error_t = actual_smp[t] - result.smp[t]

            for g in 1:G
                gen = result.generation[g, t]
                pmax = base_input.clusters[g].pmax
                pmin = base_input.clusters[g].must_run ? base_input.clusters[g].pmin : 0.0

                # 부분 투입 클러스터 (한계 클러스터)에만 adder 조정
                if gen > pmin + 1e-3 && gen < pmax - 1e-3
                    adder[g, t] += learning_rate * error_t
                end
            end
        end

        # [개선 1] 물리적 bounds로 clamp
        if !isnothing(adder_bounds)
            for g in 1:G, t in 1:T
                if adder_bounds[g] < Inf
                    adder[g, t] = clamp(adder[g, t], -adder_bounds[g], adder_bounds[g])
                end
            end
        end
    end

    return adder, history
end

# ============================================================
# 6. 교차검증 (Cross-Validation) — 개선사항 1
# ============================================================
"""
    CrossValidationResult

교차검증 결과 구조체.
"""
struct CrossValidationResult
    train_metrics::Vector{ValidationMetrics}  # fold별 train 지표
    test_metrics::Vector{ValidationMetrics}   # fold별 test 지표
    mean_train_mae::Float64
    mean_test_mae::Float64
    overfitting_ratio::Float64  # test_mae / train_mae, >1.5 시 과적합 의심
end

"""
    cross_validate_adder(base_input::EDInput,
                         day_data::Vector{NamedTuple};
                         fuel_prices=nothing,
                         max_iter=15,
                         learning_rate=0.4,
                         target_mae=3000.0,
                         adder_bounds=nothing,
                         pw_costs=PiecewiseCost[]) -> CrossValidationResult

여러 대표일에서 Leave-One-Out 교차검증을 수행.

## 매개변수
- day_data: [(demand=..., re_generation=..., actual_smp=..., T=24), ...] 대표일 목록
  각 원소는 NamedTuple with :demand, :re_generation, :actual_smp fields

## 반환
- CrossValidationResult: train/test MAE, overfitting ratio
"""
function cross_validate_adder(base_input::EDInput,
                               day_data::Vector;
                               fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing,
                               max_iter::Int=15,
                               learning_rate::Float64=0.4,
                               target_mae::Float64=3000.0,
                               adder_bounds::Union{Nothing, Vector{Float64}}=nothing,
                               pw_costs::Vector{PiecewiseCost}=PiecewiseCost[])
    if isnothing(fuel_prices)
        fuel_prices = default_fuel_prices()
    end

    N = length(day_data)
    if N < 2
        @warn "교차검증에는 최소 2개 대표일이 필요합니다."
        return nothing
    end

    train_metrics_list = ValidationMetrics[]
    test_metrics_list = ValidationMetrics[]

    for hold_out in 1:N
        println("  [CV fold $hold_out/$N] 테스트일: $hold_out")

        # 훈련 데이터: hold_out 제외한 나머지
        train_days = [day_data[i] for i in 1:N if i != hold_out]
        test_day = day_data[hold_out]

        # 훈련: 각 훈련일에서 adder를 평균 누적
        G = length(base_input.clusters)
        T = base_input.T
        adder = zeros(G, T)

        for iter in 1:max_iter
            total_error = 0.0
            count_updates = 0

            for dd in train_days
                # 훈련일 데이터로 EDInput 구성
                train_input = EDInput(T, dd.demand, dd.re_generation, base_input.clusters)
                pre_input = make_pre_input(train_input; fuel_prices=fuel_prices, adder=adder)
                result = solve_pre_ed(pre_input; pw_costs=pw_costs)

                if result.status != :OPTIMAL
                    continue
                end

                # adder 업데이트
                for t in 1:T
                    error_t = dd.actual_smp[t] - result.smp[t]
                    total_error += abs(error_t)
                    count_updates += 1

                    for g in 1:G
                        gen = result.generation[g, t]
                        pmax = base_input.clusters[g].pmax
                        pmin_g = base_input.clusters[g].must_run ? base_input.clusters[g].pmin : 0.0
                        if gen > pmin_g + 1e-3 && gen < pmax - 1e-3
                            adder[g, t] += learning_rate * error_t / length(train_days)
                        end
                    end
                end
            end

            # 물리적 bounds clamp
            if !isnothing(adder_bounds)
                for g in 1:G, t in 1:T
                    if adder_bounds[g] < Inf
                        adder[g, t] = clamp(adder[g, t], -adder_bounds[g], adder_bounds[g])
                    end
                end
            end

            avg_error = count_updates > 0 ? total_error / count_updates : Inf
            if avg_error < target_mae
                break
            end
        end

        # 훈련 성능: 첫 번째 훈련일에서 평가
        dd_train = train_days[1]
        train_input = EDInput(T, dd_train.demand, dd_train.re_generation, base_input.clusters)
        pre_train = make_pre_input(train_input; fuel_prices=fuel_prices, adder=adder)
        res_train = solve_pre_ed(pre_train; pw_costs=pw_costs)
        if res_train.status == :OPTIMAL
            push!(train_metrics_list, compute_metrics(res_train.smp, dd_train.actual_smp))
        end

        # 테스트 성능
        test_input = EDInput(T, test_day.demand, test_day.re_generation, base_input.clusters)
        pre_test = make_pre_input(test_input; fuel_prices=fuel_prices, adder=adder)
        res_test = solve_pre_ed(pre_test; pw_costs=pw_costs)
        if res_test.status == :OPTIMAL
            push!(test_metrics_list, compute_metrics(res_test.smp, test_day.actual_smp))
        end
    end

    if isempty(train_metrics_list) || isempty(test_metrics_list)
        @warn "교차검증 실패: 유효한 결과가 없습니다."
        return nothing
    end

    mean_train = mean(m.mae for m in train_metrics_list)
    mean_test = mean(m.mae for m in test_metrics_list)
    ratio = mean_train > 0 ? mean_test / mean_train : Inf

    println("  ── 교차검증 결과 ──")
    println("  · Train MAE: $(round(mean_train, digits=0)) 원/MWh")
    println("  · Test MAE:  $(round(mean_test, digits=0)) 원/MWh")
    println("  · Overfitting ratio: $(round(ratio, digits=2))")
    if ratio > 1.5
        @warn "과적합 의심: test/train ratio = $(round(ratio, digits=2)) > 1.5"
    end

    return CrossValidationResult(train_metrics_list, test_metrics_list,
                                  mean_train, mean_test, ratio)
end

# ============================================================
# 7. 간편 보정: 시간대별 균일 adder
# ============================================================
"""
    estimate_uniform_adder(base_input::EDInput,
                           actual_smp::Vector{Float64};
                           fuel_prices=nothing) -> Matrix{Float64}

1회 Pre ED를 풀고, 시간대별 오차를 전체 투입 클러스터에
균등하게 분배하는 단순 adder.
빠른 초기 보정이나 반복법 초기값으로 사용.
"""
function estimate_uniform_adder(base_input::EDInput,
                                 actual_smp::Vector{Float64};
                                 fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing)
    T = base_input.T
    G = length(base_input.clusters)

    if isnothing(fuel_prices)
        fuel_prices = default_fuel_prices()
    end

    # adder 없이 1회 풀기
    pre_input = make_pre_input(base_input; fuel_prices=fuel_prices)
    result = solve_pre_ed(pre_input)

    adder = zeros(G, T)
    if result.status != :OPTIMAL
        @warn "Uniform adder 추정 실패: Pre ED infeasible"
        return adder
    end

    # 시간대별 오차를 투입 클러스터에 균등 분배
    for t in 1:T
        error_t = actual_smp[t] - result.smp[t]
        active_count = count(g -> result.generation[g, t] > 1e-3, 1:G)
        if active_count > 0
            share = error_t / active_count
            for g in 1:G
                if result.generation[g, t] > 1e-3
                    adder[g, t] = share
                end
            end
        end
    end

    return adder
end

# ============================================================
# 8. Calibration 결과 요약 출력
# ============================================================
"""
    print_calibration_summary(metrics::ValidationMetrics, label::String)

검증지표를 포맷팅하여 출력.
"""
function print_calibration_summary(metrics::ValidationMetrics, label::String="")
    println("  ── $label 검증지표 ──")
    println("  · MAE:  $(round(metrics.mae, digits=0)) 원/MWh")
    println("  · RMSE: $(round(metrics.rmse, digits=0)) 원/MWh")
    println("  · 최대 절대오차: $(round(metrics.max_abs_error, digits=0)) 원/MWh")
    println("  · 모형 평균 SMP: $(round(metrics.mean_model, digits=0)) 원/MWh")
    println("  · 실제 평균 SMP: $(round(metrics.mean_actual, digits=0)) 원/MWh")
    println("  · 지속곡선 오차: $(round(duration_curve_error(
        metrics.smp_model, metrics.smp_actual
    ), digits=0)) 원/MWh")
end
