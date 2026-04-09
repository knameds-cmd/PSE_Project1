# ============================================================
# build_basic_ed.jl  ─  Basic Economic Dispatch 모델
# ============================================================
# 수식 참조: 보고서용 수식정리본 §2 (Basic ED)
#
# (B1) 목적함수:  min Σ_t Σ_g  c_g · p_{g,t}
# (B2) 수급균형:  Σ_g p_{g,t} = D_t - RE_t        ∀t
# (B3) 출력상한:  0 ≤ p_{g,t} ≤ P_g^max            ∀g,t
# (B4) SMP 해석:  λ_t = dual(수급균형_t)
#
# 특징:
# - 재생에너지는 음의 부하(negative load)로 처리
# - 단순 선형 비용 c_g 사용 (시간 불변)
# - 최소출력, 램프, must-run 없음 (Pre ED에서 추가)
# ============================================================

using JuMP
using HiGHS
import MathOptInterface as MOI

# types.jl은 run_basic.jl에서 먼저 include됨 (중복 include 방지)

"""
    solve_basic_ed(input::EDInput) -> EDResult

Basic ED를 풀고 결과를 반환한다.

## 모델 설명
- 재생에너지를 음의 부하로 처리 (net_demand = demand - re_generation)
- 열발전 클러스터의 단순 한계비용으로 경제급전
- 수급균형 제약의 dual value를 SMP로 해석

## 인자
- `input`: EDInput 구조체 (수요, 재생발전량, 클러스터 정보)

## 반환값
- `EDResult`: 발전량, SMP, 총비용, 상태
"""
function solve_basic_ed(input::EDInput)
    T = input.T
    G = length(input.clusters)
    clusters = input.clusters

    # ── 순수요 계산: 재생에너지를 음의 부하로 처리 ──
    net_demand = input.demand .- input.re_generation

    # 순수요가 음수가 되는 시간대 체크 (재생 > 수요인 경우)
    for t in 1:T
        if net_demand[t] < 0.0
            @warn "시간 $t: 순수요가 음수 ($(net_demand[t]) MW). " *
                  "재생발전($(input.re_generation[t]) MW) > 수요($(input.demand[t]) MW). " *
                  "순수요를 0으로 보정합니다."
            net_demand[t] = 0.0
        end
    end

    # ── JuMP 모델 구성 ──
    model = Model(HiGHS.Optimizer)
    set_silent(model)  # 솔버 출력 억제

    # 결정변수: p[g, t] = 클러스터 g의 시간 t 발전량 [MW]
    @variable(model, 0 <= p[g=1:G, t=1:T] <= clusters[g].pmax)

    # (B2) 수급균형 제약: Σ_g p[g,t] = D_t - RE_t
    balance = @constraint(model, [t=1:T],
        sum(p[g, t] for g in 1:G) == net_demand[t]
    )

    # (B1) 목적함수: 총 발전비용 최소화
    @objective(model, Min,
        sum(clusters[g].marginal_cost * p[g, t] for g in 1:G, t in 1:T)
    )

    # ── 최적화 실행 ──
    optimize!(model)

    status = termination_status(model)
    if status != MOI.OPTIMAL
        @error "Basic ED 최적화 실패: status = $status"
        # 빈 결과 반환
        return EDResult(
            T,
            zeros(G, T),
            zeros(T),
            0.0,
            [c.name for c in clusters],
            :INFEASIBLE,
            zeros(T)
        )
    end

    # ── 결과 추출 ──

    # 발전량 행렬 [G × T]
    gen_matrix = zeros(G, T)
    for g in 1:G, t in 1:T
        gen_matrix[g, t] = value(p[g, t])
    end

    # SMP: 수급균형 제약의 dual value (shadow price)
    # JuMP에서 등호 제약의 dual은 부호에 주의:
    # Min 문제의 등호 제약 dual은 양수 = 수요 1MW 증가 시 비용 증가분
    smp = zeros(T)
    for t in 1:T
        smp[t] = dual(balance[t])
    end

    # 총 비용
    total_cost = objective_value(model)

    return EDResult(
        T,
        gen_matrix,
        smp,
        total_cost,
        [c.name for c in clusters],
        :OPTIMAL,
        zeros(T)  # Basic ED에서는 curtailment 없음
    )
end

"""
    compute_basic_metrics(result::EDResult, actual_smp::Vector{Float64}) -> Dict

Basic ED 결과와 실제 SMP를 비교하는 검증지표 계산.
- MAE:  평균 절대오차 [원/MWh]
- RMSE: 평균제곱근오차 [원/MWh]
- 시간대별 오차 벡터
"""
function compute_basic_metrics(result::EDResult, actual_smp::Vector{Float64})
    T = result.T
    @assert length(actual_smp) == T "actual_smp 길이($( length(actual_smp)))가 T($T)와 불일치"

    errors = result.smp .- actual_smp
    abs_errors = abs.(errors)

    mae  = sum(abs_errors) / T
    rmse = sqrt(sum(errors .^ 2) / T)

    return Dict(
        "MAE"    => mae,
        "RMSE"   => rmse,
        "errors" => errors,
        "abs_errors" => abs_errors,
        "max_error"  => maximum(abs_errors),
        "mean_smp_model"  => sum(result.smp) / T,
        "mean_smp_actual" => sum(actual_smp) / T,
    )
end

"""
    identify_marginal_fuel(result::EDResult, input::EDInput) -> Vector{String}

각 시간대의 한계연료원(가격결정 연료)을 식별.
한계연료원 = 발전량이 0 < p < pmax 인 클러스터 중 비용이 가장 높은 것.
모든 클러스터가 0 또는 pmax에 있으면, 마지막으로 투입된 클러스터를 한계연료로 간주.
"""
function identify_marginal_fuel(result::EDResult, input::EDInput)
    T = result.T
    G = length(input.clusters)
    marginal_fuels = Vector{String}(undef, T)

    for t in 1:T
        marginal_g = 0
        marginal_cost = -Inf

        for g in 1:G
            gen = result.generation[g, t]
            pmax = input.clusters[g].pmax

            # 한계 클러스터: 0보다 크고 pmax 미만인 클러스터 (부분 투입)
            if gen > 1e-3 && gen < pmax - 1e-3
                if input.clusters[g].marginal_cost > marginal_cost
                    marginal_cost = input.clusters[g].marginal_cost
                    marginal_g = g
                end
            end
        end

        # 부분 투입 클러스터가 없으면, 투입된 클러스터 중 최고비용
        if marginal_g == 0
            for g in 1:G
                if result.generation[g, t] > 1e-3
                    if input.clusters[g].marginal_cost > marginal_cost
                        marginal_cost = input.clusters[g].marginal_cost
                        marginal_g = g
                    end
                end
            end
        end

        marginal_fuels[t] = marginal_g > 0 ? input.clusters[marginal_g].fuel : "none"
    end

    return marginal_fuels
end
