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
#
# [v2] §7 활성 marginal 1/n_marg 정규화
#      §8 Tikhonov L2 shrinkage
#      §9 curtailment_free calibration purity
#      §10 Multi-day 3D adder (G×24×S)
# ============================================================
# 의존: types.jl, build_pre_ed.jl (상위에서 include 완료)
# ============================================================

using Statistics
using Dates
using Random

# ============================================================
# 1. 통합 검증지표 계산
# ============================================================
"""
    ValidationMetrics

검증지표 모음.
"""
struct ValidationMetrics
    mae::Float64
    rmse::Float64
    max_abs_error::Float64
    mean_model::Float64
    mean_actual::Float64
    hourly_errors::Vector{Float64}
    hourly_bias::Vector{Float64}
    smp_model::Vector{Float64}
    smp_actual::Vector{Float64}
end

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
        errors,
        copy(smp_model),
        copy(smp_actual)
    )
end

# ============================================================
# 2. Duration Curve 비교
# ============================================================
function duration_curve(smp::Vector{Float64})
    return sort(smp, rev=true)
end

function duration_curve_error(smp_model::Vector{Float64}, smp_actual::Vector{Float64})
    dc_model  = duration_curve(smp_model)
    dc_actual = duration_curve(smp_actual)
    return mean(abs.(dc_model .- dc_actual))
end

# ============================================================
# 3. 연료원별 SMP 결정횟수 비교
# ============================================================
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
# 4. Price Adder 물리적 검증
# ============================================================
function compute_adder_physical_bounds(clusters::Vector{ThermalCluster},
                                        unit_specs::Vector{ThermalUnitSpec})
    G = length(clusters)
    bounds = fill(Inf, G)

    spec_dict = Dict(s.name => s for s in unit_specs)

    for g in 1:G
        name = clusters[g].name
        if haskey(spec_dict, name)
            spec = spec_dict[name]
            if spec.min_up_time > 0 && spec.pmax_unit > 0
                startup_won = spec.startup_cost * 1000.0
                bounds[g] = startup_won / spec.min_up_time / spec.pmax_unit
            end
        end
    end

    return bounds
end

function validate_adder_bounds(adder::Matrix{Float64},
                                bounds::Vector{Float64},
                                cluster_names::Vector{String})
    G, T = size(adder)
    all_ok = true

    for g in 1:G
        if bounds[g] < Inf
            max_adder_g = maximum(abs.(adder[g, :]))
            if max_adder_g > bounds[g] * 1.5
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
# 5. Price Adder 추정 ─ 반복 보정법 (§7+§8+§9)
# ============================================================
"""
    estimate_price_adder(base_input::EDInput,
                         actual_smp::Vector{Float64};
                         ...) -> (Matrix{Float64}, Vector{ValidationMetrics})

§7.4 활성 marginal 집합 + 1/n_marg 정규화
§8.2 Tikhonov L2 shrinkage
§9   curtailment_free calibration purity
"""
function estimate_price_adder(base_input::EDInput,
                               actual_smp::Vector{Float64};
                               fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing,
                               max_iter::Int=20,
                               target_mae::Float64=5000.0,
                               learning_rate::Float64=0.3,
                               l2_shrinkage::Float64=0.05,
                               adder_bounds::Union{Nothing, Vector{Float64}}=nothing,
                               pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                               curtailment_free::Bool=true)
    T = base_input.T
    G = length(base_input.clusters)

    if isnothing(fuel_prices)
        fuel_prices = default_fuel_prices()
    end

    adder = zeros(G, T)
    history = ValidationMetrics[]

    for iter in 1:max_iter
        # §9: curtailment-free 로 calibration purity 확보
        pre_input = make_pre_input(base_input; fuel_prices=fuel_prices, adder=adder)
        result = solve_pre_ed(pre_input; pw_costs=pw_costs,
                                          curtailment_free=curtailment_free)

        if result.status != :OPTIMAL
            @warn "Calibration iter $iter: Pre ED 실패"
            break
        end

        metrics = compute_metrics(result.smp, actual_smp)
        push!(history, metrics)

        println("  [Calibration iter $iter] MAE=$(round(metrics.mae, digits=0)) 원/MWh, " *
                "RMSE=$(round(metrics.rmse, digits=0)) 원/MWh")

        if metrics.mae < target_mae
            println("  ✓ 목표 MAE 달성 ($(round(metrics.mae, digits=0)) < $target_mae)")
            break
        end

        # §7.4 활성 marginal 집합 + 1/n_marg 정규화
        for t in 1:T
            error_t = actual_smp[t] - result.smp[t]

            marg_set = Int[]
            for g in 1:G
                gen = result.generation[g, t]
                pmax = base_input.clusters[g].pmax
                pmin_g = base_input.clusters[g].must_run ? base_input.clusters[g].pmin : 0.0
                if gen > pmin_g + 1e-3 && gen < pmax - 1e-3
                    push!(marg_set, g)
                end
            end

            n_marg = length(marg_set)
            if n_marg > 0
                share = error_t / n_marg
                for g in marg_set
                    adder[g, t] += learning_rate * share
                end
            end
        end

        # §8.2 Tikhonov L2 shrinkage
        if l2_shrinkage > 0
            adder .*= (1.0 - l2_shrinkage)
        end

        # 물리적 bounds clamp
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
# 5b. Multi-day Price Adder 추정 — §10
# ============================================================
"""
    estimate_price_adder_multi(base_clusters, panel, train_dates, season_label;
                                ...) -> (Array{Float64,3}, Vector{Float64})

§10 다일(panel) 학습 — 3D adder (G, 24, S=4 seasons).
"""
function estimate_price_adder_multi(base_clusters::Vector{ThermalCluster},
                                     panel,
                                     train_dates::Vector{Date},
                                     season_label::Dict{Date,Int};
                                     fuel_costs_monthly::Union{Nothing,
                                         Dict{Tuple{Int,Int,String}, Float64}}=nothing,
                                     n_epochs::Int=10,
                                     learning_rate::Float64=0.2,
                                     l2_shrinkage::Float64=0.05,
                                     target_mae::Float64=4000.0,
                                     adder_bounds::Union{Nothing, Vector{Float64}}=nothing,
                                     pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                                     S::Int=4,
                                     rng::AbstractRNG=Random.default_rng())
    G = length(base_clusters)
    T = 24
    adder = zeros(G, T, S)
    mae_per_epoch = Float64[]

    if isnothing(fuel_costs_monthly)
        fuel_costs_monthly = load_fuel_costs_monthly()
    end

    # day cache
    day_cache = Dict{Date, NamedTuple}()
    for d in train_dates
        day_cache[d] = extract_day_input(panel, d, base_clusters)
    end

    for epoch in 1:n_epochs
        update_acc  = zeros(G, T, S)
        update_cnt  = zeros(Int, S)
        epoch_err   = 0.0
        n_eval      = 0

        order = shuffle(rng, collect(eachindex(train_dates)))

        for i in order
            d = train_dates[i]
            dd = day_cache[d]
            s_idx = season_label[d]

            fp = fuel_prices_for_month(fuel_costs_monthly, dd.year, dd.month)

            ed_in = EDInput(T, dd.demand, dd.re_gen, base_clusters)
            pre_in = make_pre_input(ed_in; fuel_prices=fp, adder=copy(adder[:, :, s_idx]))
            result = solve_pre_ed(pre_in; pw_costs=pw_costs, curtailment_free=true)

            if result.status != :OPTIMAL
                @warn "Multi-adder epoch $epoch day $d: Pre ED 실패"
                continue
            end

            metrics = compute_metrics(result.smp, dd.smp)
            epoch_err += metrics.mae
            n_eval += 1

            # §7.4 활성 marginal + 1/n_marg → s_idx 계절에 누적
            for t in 1:T
                error_t = dd.smp[t] - result.smp[t]
                marg_set = Int[]
                for g in 1:G
                    gen = result.generation[g, t]
                    pmax = base_clusters[g].pmax
                    pmin_g = base_clusters[g].must_run ? base_clusters[g].pmin : 0.0
                    if gen > pmin_g + 1e-3 && gen < pmax - 1e-3
                        push!(marg_set, g)
                    end
                end
                n_marg = length(marg_set)
                if n_marg > 0
                    share = error_t / n_marg
                    for g in marg_set
                        update_acc[g, t, s_idx] += learning_rate * share
                    end
                end
            end
            update_cnt[s_idx] += 1
        end

        # 계절별 평균 update 적용
        for s in 1:S
            if update_cnt[s] > 0
                @views adder[:, :, s] .+= update_acc[:, :, s] ./ update_cnt[s]
            end
        end

        # §8.2 L2 shrinkage
        if l2_shrinkage > 0
            adder .*= (1.0 - l2_shrinkage)
        end

        # 물리적 bounds clamp
        if !isnothing(adder_bounds)
            for g in 1:G, t in 1:T, s in 1:S
                if adder_bounds[g] < Inf
                    adder[g, t, s] = clamp(adder[g, t, s], -adder_bounds[g], adder_bounds[g])
                end
            end
        end

        avg_mae = n_eval > 0 ? epoch_err / n_eval : Inf
        push!(mae_per_epoch, avg_mae)
        println("  [Multi-adder epoch $epoch] mean train MAE = " *
                "$(round(avg_mae, digits=0)) 원/MWh ($(n_eval) days)")

        if avg_mae < target_mae
            println("  ✓ 목표 train MAE 달성 ($(round(avg_mae, digits=0)) < $target_mae)")
            break
        end
    end

    return adder, mae_per_epoch
end

"""
    adder_slice_for_date(adder3, date, season_label) -> Matrix{Float64}

(G,24,S) adder 에서 date 에 해당하는 (G,24) 슬라이스를 반환.
"""
function adder_slice_for_date(adder3::Array{Float64,3}, date::Date,
                               season_label::Dict{Date,Int})
    s_idx = if haskey(season_label, date)
        season_label[date]
    else
        m = Dates.month(date)
        m in [3,4,5]   ? 1 :
        m in [6,7,8]   ? 2 :
        m in [9,10,11] ? 3 : 4
    end
    return adder3[:, :, s_idx]
end

# ============================================================
# 6. 교차검증 (Cross-Validation) — §7+§8+§9 반영
# ============================================================
struct CrossValidationResult
    train_metrics::Vector{ValidationMetrics}
    test_metrics::Vector{ValidationMetrics}
    mean_train_mae::Float64
    mean_test_mae::Float64
    overfitting_ratio::Float64
end

function cross_validate_adder(base_input::EDInput,
                               day_data::Vector;
                               fuel_prices::Union{Nothing, Dict{String,Float64}}=nothing,
                               max_iter::Int=15,
                               learning_rate::Float64=0.4,
                               l2_shrinkage::Float64=0.05,
                               target_mae::Float64=3000.0,
                               adder_bounds::Union{Nothing, Vector{Float64}}=nothing,
                               pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                               curtailment_free::Bool=true)
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

        train_days = [day_data[i] for i in 1:N if i != hold_out]
        test_day = day_data[hold_out]

        G = length(base_input.clusters)
        T = base_input.T
        adder = zeros(G, T)

        for iter in 1:max_iter
            total_error = 0.0
            count_updates = 0

            for dd in train_days
                train_input = EDInput(T, dd.demand, dd.re_generation, base_input.clusters)
                pre_input = make_pre_input(train_input; fuel_prices=fuel_prices, adder=adder)
                result = solve_pre_ed(pre_input; pw_costs=pw_costs,
                                                  curtailment_free=curtailment_free)

                if result.status != :OPTIMAL
                    continue
                end

                # §7.4 활성 marginal + 1/n_marg 정규화
                for t in 1:T
                    error_t = dd.actual_smp[t] - result.smp[t]
                    total_error += abs(error_t)
                    count_updates += 1

                    marg_set = Int[]
                    for g in 1:G
                        gen = result.generation[g, t]
                        pmax = base_input.clusters[g].pmax
                        pmin_g = base_input.clusters[g].must_run ? base_input.clusters[g].pmin : 0.0
                        if gen > pmin_g + 1e-3 && gen < pmax - 1e-3
                            push!(marg_set, g)
                        end
                    end
                    n_marg = length(marg_set)
                    if n_marg > 0
                        share = error_t / (n_marg * length(train_days))
                        for g in marg_set
                            adder[g, t] += learning_rate * share
                        end
                    end
                end
            end

            # §8.2 L2 shrinkage
            if l2_shrinkage > 0
                adder .*= (1.0 - l2_shrinkage)
            end

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

        dd_train = train_days[1]
        train_input = EDInput(T, dd_train.demand, dd_train.re_generation, base_input.clusters)
        pre_train = make_pre_input(train_input; fuel_prices=fuel_prices, adder=adder)
        res_train = solve_pre_ed(pre_train; pw_costs=pw_costs,
                                            curtailment_free=curtailment_free)
        if res_train.status == :OPTIMAL
            push!(train_metrics_list, compute_metrics(res_train.smp, dd_train.actual_smp))
        end

        test_input = EDInput(T, test_day.demand, test_day.re_generation, base_input.clusters)
        pre_test = make_pre_input(test_input; fuel_prices=fuel_prices, adder=adder)
        res_test = solve_pre_ed(pre_test; pw_costs=pw_costs,
                                          curtailment_free=curtailment_free)
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
# 7. Calibration 결과 요약 출력
# ============================================================
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
