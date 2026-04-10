# all_gen_real_system 소스코드 상세 문서

> **프로젝트**: 전력시스템 경제 프로젝트 -- 재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석
> **버전**: v2 (개별 발전기 122기 + real-data)
> **기반**: MATPOWER KPG193 케이스 (한국 전력계통 193-bus 모형)

---

## 목차

1. [프로젝트 개요 및 파이프라인 아키텍처](#1-프로젝트-개요-및-파이프라인-아키텍처)
2. [types.jl -- 핵심 자료형 정의](#2-typesjl----핵심-자료형-정의)
3. [load_data.jl -- 데이터 로딩](#3-load_datajl----데이터-로딩)
4. [preprocess.jl -- 전처리 및 대표일 선정](#4-preprocessjl----전처리-및-대표일-선정)
5. [build_basic_ed.jl -- Basic Economic Dispatch](#5-build_basic_edjl----basic-economic-dispatch)
6. [build_pre_ed.jl -- Pre-revision Economic Dispatch](#6-build_pre_edjl----pre-revision-economic-dispatch)
7. [build_post_ed.jl -- Post-revision Economic Dispatch](#7-build_post_edjl----post-revision-economic-dispatch)
8. [calibrate.jl -- Price Adder Calibration](#8-calibratejl----price-adder-calibration)
9. [scenarios.jl -- 시나리오 분석 및 Monte Carlo](#9-scenariosjl----시나리오-분석-및-monte-carlo)
10. [run_all.jl -- 메인 파이프라인 오케스트레이션](#10-run_alljl----메인-파이프라인-오케스트레이션)
11. [verify_blocks.jl -- 검증 스크립트](#11-verify_blocksjl----검증-스크립트)
12. [한국 전력시장 특수 적응사항 요약](#12-한국-전력시장-특수-적응사항-요약)
13. [수학적 정형화 총괄](#13-수학적-정형화-총괄)
14. [의존성 그래프](#14-의존성-그래프)

---

## 1. 프로젝트 개요 및 파이프라인 아키텍처

### 1.1 연구 목적

한국 육지계통(mainland)에 재생에너지 입찰제(RE bidding)를 도입할 경우 계통한계가격(SMP, System Marginal Price)이 어떻게 변화하는지를 정량적으로 분석한다. 기존의 변동비 반영 시장(CBP, Cost-Based Pool) 하에서 재생에너지는 음의 부하(negative load)로 처리되지만, 입찰제 도입 시 재생에너지가 공급곡선에 직접 참여하여 가격결정에 영향을 미친다.

### 1.2 파이프라인 구조

```
PHASE 0: 데이터 로딩
  CSV -> 8784시간(2024 윤년) panel DataFrame 구축

PHASE 1: Train/Test/Buffer Split
  계절별 대표일 12일(test) + train 100일 + buffer +/-3일

PHASE 2: Multi-day Calibration
  3D Price Adder (G x 24 x S=4계절) 추정
  -- 활성 marginal 1/n_marg 정규화
  -- Tikhonov L2 shrinkage
  -- curtailment-free calibration purity

PHASE 3: 12 대표일 평가
  Pre-revision ED -> Post-revision ED (4가지 시나리오)
  -- Case_A_zero: rho=0 baseline (입찰 비활성)
  -- Case_B_floor: 하한가 입찰
  -- Case_C_mixed: 혼합 입찰
  -- Case_D_conservative: 보수적 입찰

PHASE 4: 정책 침투도 시나리오 (S1/S2/S3)
  Beta mixture + common shock Monte Carlo (100회)

PHASE 5: 민감도 분석
  beta 민감도 (1.5, 2.0, 2.5) + rho 민감도 (0.1~0.5)
```

### 1.3 한국 시장 핵심 특성 (코드 전반 반영)

| 항목 | 일반적 ED 모형 | 본 프로젝트 (한국 CBP) |
|------|---------------|----------------------|
| 비용함수 | heat_rate x fuel_price + VOM | gencost 2차함수 `C(P) = aP^2 + bP + c` (천원/h) |
| 한계비용 | HR x FP + VOM | `MC = (2aP + b) x 1000` 원/MWh |
| VOM | 비용에 포함 | 별도 정산 (미포함) |
| heat_rate | 별도 파라미터 | gencost에 내포 (필드 없음) |
| 원전 매핑 | index 기반 | 호기명(한글) -> generator_id 이름 매핑 |

### 1.4 include 순서

```
run_all.jl (또는 verify_blocks.jl)
  |-- types.jl           (자료형 정의)
  |-- load_data.jl       (CSV 로딩)
  |-- preprocess.jl      (전처리)
  |-- build_basic_ed.jl  (Basic ED)
  |-- build_pre_ed.jl    (Pre ED)
  |-- build_post_ed.jl   (Post ED)
  |-- calibrate.jl       (보정)
  |-- scenarios.jl       (시나리오)
```

---

## 2. types.jl -- 핵심 자료형 정의

**파일 위치**: `all_gen_real_system_src/types.jl`
**역할**: 프로젝트 전체에서 사용되는 모든 struct를 정의한다. 다른 모든 파일이 이 파일에 의존한다.
**의존성**: 없음 (최상위)

### 2.1 ThermalGenerator

```julia
struct ThermalGenerator
    name::String            # 발전기 이름 (예: "LNG_001", "Coal_015", "Nuclear_001")
    fuel::String            # 연료원 ("LNG", "Coal", "Nuclear")
    pmin::Float64           # 최소출력 [MW]
    pmax::Float64           # 최대출력 [MW]
    ramp_up::Float64        # 상향 램프 한계 [MW/h]
    ramp_down::Float64      # 하향 램프 한계 [MW/h]
    must_run::Bool          # must-run 여부 (Nuclear인 경우 true)
    marginal_cost::Float64  # 중점 한계비용 [원/MWh] (Basic ED용 fallback)
end
```

**한국 시장 적응사항**:
- `heat_rate`, `vom` 필드가 **없다**. 한국 CBP 시장에서 열소비율은 gencost의 2차 비용함수 계수 `a`에 내포되어 있고, VOM(변동운영비)은 별도 정산된다.
- `marginal_cost`는 gencost에서 중점(`P_mid = (pmin + pmax) / 2`)의 MC로 계산된 값이며, Basic ED에서만 직접 사용된다. Pre/Post ED에서는 piecewise linear 비용이나 gencost 기반 MC를 사용한다.
- `must_run`은 `fuel == "Nuclear"`인 경우에만 `true`로 설정된다. 원자력은 기저부하 발전소로 최소출력 이상 의무 가동한다.

**호환 alias**:
```julia
const ThermalCluster = ThermalGenerator
```
기존 cluster 기반 코드에서 마이그레이션 시 호환성을 위해 `ThermalCluster`를 alias로 유지한다.

### 2.2 adjust_generator_capacity

```julia
function adjust_generator_capacity(g::ThermalGenerator;
                                   pmin::Float64=g.pmin,
                                   pmax::Float64=g.pmax) -> ThermalGenerator
```

**목적**: immutable struct인 `ThermalGenerator`의 `pmin`/`pmax`만 변경한 새 인스턴스를 생성한다.

**사용처**: Nuclear must-off 적용 시 정비 중인 원전의 `pmin=0.0, pmax=0.0`으로 설정할 때 호출된다.

**반환**: 새로운 `ThermalGenerator` 인스턴스 (나머지 필드는 원본 유지)

### 2.3 ThermalUnitSpec

```julia
struct ThermalUnitSpec
    name::String            # 발전기 이름
    startup_cost::Float64   # 고온기동비 [천원]
    min_up_time::Float64    # 최소가동시간 [시간]
    pmax_unit::Float64      # 호기별 최대출력 [MW]
end
```

**목적**: Price Adder의 물리적 상한(physical bound)을 계산하기 위한 자료형이다. genthermal 데이터에서 추출된다.

**물리적 상한 공식**:
```
bound_g = startup_cost_g x 1000 / (min_up_time_g x pmax_unit_g)  [원/MWh]
```
이 값은 Price Adder가 기동비를 시간당 출력으로 나눈 값을 초과하면 물리적으로 비합리적이라는 제약이다.

### 2.4 PiecewiseCostSegment

```julia
struct PiecewiseCostSegment
    delta_max::Float64      # 구간 폭 [MW]
    marginal_cost::Float64  # 이 구간의 한계비용 [원/MWh]
end
```

**목적**: 2차 비용함수 `C(P) = aP^2 + bP + c`를 `S`개의 구간으로 선형 근사할 때, 각 구간의 정보를 담는다.

**알고리즘**: Pmin부터 Pmax까지의 범위를 `S`등분하고, 각 구간의 중점에서의 한계비용(`MC = (2a * P_mid + b) * 1000`)을 해당 구간의 비용으로 사용한다. 이는 LP(선형계획법)로 ED를 풀기 위한 표준적인 구간별 선형화(piecewise linearization) 기법이다.

### 2.5 PiecewiseCost

```julia
struct PiecewiseCost
    cluster_idx::Int                        # 발전기 인덱스 (1~G)
    pmin::Float64                           # 최소출력 [MW]
    segments::Vector{PiecewiseCostSegment}  # S개 구간
end
```

**목적**: 발전기 1기의 전체 구간별 선형 근사 비용 정보를 집약한다. `pmin`은 must-run 발전기의 경우 해당 최소출력, 비must-run은 0.0이다.

### 2.6 RenewableBidBlock

```julia
struct RenewableBidBlock
    name::String            # 블록 이름 (예: "PV_low", "W_high")
    tech::String            # 기술 유형 ("solar" 또는 "wind")
    avail::Vector{Float64}  # 시간대별 공급가능량 [MW] (길이 = T)
    bid::Vector{Float64}    # 시간대별 입찰가격 [원/MWh] (길이 = T)
    installed_mw::Float64   # 블록 점유 설비용량 [MW]
end
```

**목적**: Post-revision ED에서 사용되는 재생에너지 입찰블록을 정의한다. 6블록 체계(PV_low, PV_mid, PV_high, W_low, W_mid, W_high)가 기본이다.

**핵심 필드 설명**:
- `avail`: 시간대별 physical availability. 해당 블록이 공급 가능한 최대 전력량이다.
- `bid`: 입찰가격. 음수 가능(하한가 = -beta x REC x 1000). 시나리오별로 다르게 설정된다.
- `installed_mw`: 블록이 점유하는 설비용량. RE Pmin 제약 계산에 사용된다 (`Pmin = min(alpha x installed_mw, avail_t)`). 0.0이면 `avail x alpha`로 fallback한다.

**하위호환 생성자**:
```julia
RenewableBidBlock(name, tech, avail, bid)  # installed_mw = 0.0 (fallback)
```

### 2.7 BidderType

```julia
struct BidderType
    name::String                         # "aggressive" / "moderate" / "conservative" / "PPA_locked"
    share::Float64                       # phi_j (해당 유형 비율; sum = 1)
    beta_dist::Tuple{Float64,Float64}    # Beta(alpha, beta) 분포 파라미터
    w_blocks::NTuple{3,Float64}          # (low, mid, high) 블록 가중치
end
```

**목적**: 재생에너지 입찰사업자 유형을 정의한다. Monte Carlo 시뮬레이션에서 입찰자 이질성(heterogeneity)을 모형화한다.

**유형별 설정 (default)**:

| 유형 | share | Beta(a,b) | w_blocks (low,mid,high) |
|------|-------|-----------|------------------------|
| aggressive | 0.30 | (2.0, 5.0) | (0.6, 0.3, 0.1) |
| moderate | 0.40 | (3.0, 3.0) | (0.4, 0.4, 0.2) |
| conservative | 0.20 | (5.0, 2.0) | (0.2, 0.4, 0.4) |
| PPA_locked | 0.10 | (8.0, 1.5) | (0.1, 0.3, 0.6) |

- `Beta(2,5)`: 왼쪽 치우침 -> 낮은 입찰가 경향 (aggressive)
- `Beta(5,2)`: 오른쪽 치우침 -> 높은 입찰가 경향 (conservative)
- `w_blocks`: low 블록에 가중치가 높으면 하한가 입찰 비중이 큰 것

### 2.8 EDInput

```julia
struct EDInput
    T::Int                              # 시간 수 (보통 24)
    demand::Vector{Float64}             # 시간대별 수요 [MW]
    re_generation::Vector{Float64}      # 시간대별 외생 재생발전량 [MW]
    clusters::Vector{ThermalGenerator}  # 열발전기 목록
end
```

**목적**: Economic Dispatch 입력 데이터를 통합하는 구조체이다. Basic ED와 Pre ED의 기본 입력으로 사용된다.

**주의**: `clusters`라는 필드명은 기존 cluster 기반 코드와의 호환성을 위해 유지되었다. 실제로는 개별 발전기 122기의 벡터이다.

### 2.9 EDResult

```julia
struct EDResult
    T::Int                              # 시간 수
    generation::Matrix{Float64}         # 발전량 [MW] (G x T)
    smp::Vector{Float64}                # SMP [원/MWh] (길이 T)
    total_cost::Float64                 # 총 발전비용 [원]
    cluster_names::Vector{String}       # 발전기 이름 목록
    status::Symbol                      # 최적화 상태 (:OPTIMAL, :INFEASIBLE 등)
    curtailment::Vector{Float64}        # RE 출력제한량 [MW] (길이 T)
end
```

**목적**: ED 최적화 결과를 담는 통합 구조체이다. `smp`는 수급균형 제약의 dual value(쌍대변수)로부터 추출된다.

### 2.10 PostEDResult

```julia
struct PostEDResult
    base::EDResult                      # 열발전 관련 결과
    re_dispatch::Matrix{Float64}        # 입찰블록별 낙찰량 [MW] (K x T)
    re_block_names::Vector{String}      # 블록 이름
    curtailment::Vector{Float64}        # 비입찰 RE 출력제한 [MW]
end
```

**목적**: Post-revision ED 결과를 담는 구조체이다. 열발전 결과(`base`)에 더해 재생에너지 입찰블록의 낙찰량(`re_dispatch`)을 포함한다. `curtailment`는 `re_nonbid - re_net`으로 사후 계산된다.

### 2.11 CurtailmentAnalysis

```julia
struct CurtailmentAnalysis
    total_mwh::Float64         # 총 출력제한량 [MWh]
    hours::Int                 # 출력제한 발생 시간 수
    max_mw::Float64            # 최대 출력제한 [MW]
    by_hour::Vector{Float64}   # 시간대별 출력제한량
    smp_correlation::Float64   # SMP와 curtailment의 상관계수
end
```

### 2.12 MonteCarloResult

```julia
struct MonteCarloResult
    n_samples::Int                # 성공 샘플 수
    mean_smp::Vector{Float64}    # 평균 SMP [원/MWh] (길이 T)
    p5_smp::Vector{Float64}      # 5th percentile SMP
    p95_smp::Vector{Float64}     # 95th percentile SMP
    mean_delta_smp::Float64      # 평균 delta-SMP (Post - Pre)
    all_smp::Matrix{Float64}     # 전체 SMP 샘플 (n_samples x T)
    mean_curtailment::Vector{Float64}  # 평균 curtailment
end
```

---

## 3. load_data.jl -- 데이터 로딩

**파일 위치**: `all_gen_real_system_src/load_data.jl`
**역할**: `processed/` 폴더의 CSV 파일들을 읽어 Julia 자료형으로 변환한다.
**의존성**: `types.jl`, `CSV`, `DataFrames`, `Dates`, `Statistics`

### 3.1 경로 상수

```julia
const DATA_RAW       = joinpath(@__DIR__, "..", "all_gen_real_system_data", "raw_data")
const DATA_PROCESSED = joinpath(@__DIR__, "..", "all_gen_real_system_data", "processed")
```

`@__DIR__`은 `all_gen_real_system_src/`를 가리키므로, 데이터 경로는 `all_gen_real_system/all_gen_real_system_data/processed/`가 된다.

### 3.2 load_smp_demand

```julia
function load_smp_demand(filepath::String=joinpath(DATA_PROCESSED, "smp_demand.csv")) -> DataFrame
```

**입력 파일**: `smp_demand.csv`
**출력 컬럼**: `date`, `hour`, `smp_mainland` (원/MWh), `demand_mainland` (MW)

**컬럼명 정규화 로직**: CSV 파일의 컬럼명이 한글 또는 다른 형태일 수 있으므로, lowercase 변환 후 키워드(`"date"`, `"hour"`, `"smp"`, `"demand"`)를 감지하여 표준명으로 rename한다. 한글 키워드(`"날짜"`, `"시간"`)도 지원한다.

### 3.3 load_renewable

```julia
function load_renewable(filepath::String=joinpath(DATA_PROCESSED, "renewables_generation_mwh.csv")) -> DataFrame
```

**출력 컬럼**: `date`, `hour`, `solar_mainland` (MW), `wind_mainland` (MW)

동일한 컬럼명 정규화 로직을 적용한다. `"solar"`, `"wind"` 키워드를 감지한다.

### 3.4 load_generators

```julia
function load_generators(filepath::String=joinpath(DATA_PROCESSED, "generators.csv")) -> Vector{ThermalGenerator}
```

**입력 파일**: `generators.csv`
**필수 컬럼**: `name`, `fuel`, `pmin`, `pmax`, `ramp_up`, `ramp_down`, `marginal_cost`

**처리 로직**:
1. 각 행을 `ThermalGenerator` struct로 변환
2. `must_run`은 `lowercase(fuel) == "nuclear"`로 자동 판정
3. 로딩 후 연료원별 기수와 총용량을 출력

**출력 예시**:
```
  발전기 122기 로딩 완료
    Coal: 40기, 총용량 28000 MW
    LNG: 52기, 총용량 25000 MW
    Nuclear: 25기, 총용량 23000 MW
    ...
```

### 3.5 load_gencost

```julia
function load_gencost(filepath::String=joinpath(DATA_PROCESSED, "gencost.csv"))
    -> Dict{String, Tuple{Float64,Float64,Float64}}
```

**입력 파일**: `gencost.csv`
**필수 컬럼**: `name`, `a`, `b`, `c`

**반환**: 발전기명 => (a, b, c) 매핑. 2차 비용함수 `C(P) = a*P^2 + b*P + c`의 계수이다. 단위는 **천원/h**이다.

**한국 시장 적응**: 한국 전력시장에서 발전비용은 다음과 같이 구성된다:
- `a`: 2차 열소비율계수 (내재)
- `b`: 1차 열소비율계수 (내재)
- `c`: 고정비
- MC = `dC/dP = 2aP + b` (천원/MWh) -> `x1000 = 원/MWh`

### 3.6 load_unit_specs

```julia
function load_unit_specs(filepath_thermal::String, filepath_gen::String)
    -> Vector{ThermalUnitSpec}
```

**입력 파일**: `genthermal.csv` (기동비, 최소가동시간), `generators.csv` (최대출력)

**처리**: genthermal의 `startup1` (고온기동비, 천원)과 `UT` (최소가동시간, 시간)을 읽고, generators.csv의 `pmax`와 결합하여 `ThermalUnitSpec`을 생성한다.

**주의**: 두 파일의 행 순서가 동일해야 한다 (`df_g[i, :pmax]`로 i번째 행을 직접 참조).

### 3.7 load_fuel_costs

```julia
function load_fuel_costs(filepath::String) -> DataFrame
```

**입력 파일**: `fuel_costs.csv`
**컬럼**: `year_month`, `fuel`, `fuel_cost_won_per_gcal`

### 3.8 load_nuclear_must_off

```julia
function load_nuclear_must_off(filepath::String) -> DataFrame
```

**입력 파일**: `nuclear_must_off.csv`
**컬럼**: `id`, `unit_name`, `off_start_date`, `off_end_date`, `off_start_day`, `off_end_day`, `duration_days`

`unit_name`은 한글 호기명(예: "고리4호기")이다. `off_start_day`, `off_end_day`는 연중 일수(day of year, 1~366)이다.

### 3.9 load_marginal_fuel_counts

```julia
function load_marginal_fuel_counts(filepath::String) -> DataFrame
```

**입력 파일**: `marginal_fuel_counts.csv` (존재 시에만 로딩)

### 3.10 load_all_data

```julia
function load_all_data() -> Dict{String, Any}
```

**목적**: 모든 processed CSV를 한 번에 로딩하여 Dict로 반환하는 통합 로딩 함수이다.

**반환 키**: `"smp_demand"`, `"renewable"`, `"generators"`, `"gencost"`, `"unit_specs"`, `"fuel_costs"`, `"nuclear_must_off"`, `"marginal_fuel"` (선택적)

### 3.11 load_renewables_capacity

```julia
function load_renewables_capacity(filepath::String) -> NamedTuple{(:solar_mw, :wind_mw)}
```

**입력 파일**: `renewables_capacity_mw.csv`
**컬럼**: `energy_type`, `total_capacity_mw`

`energy_type`이 `"solar"` 또는 `"wind"`인 행의 `total_capacity_mw`를 추출한다.

### 3.12 load_fuel_costs_monthly

```julia
function load_fuel_costs_monthly(filepath::String)
    -> Dict{Tuple{Int,Int,String}, Float64}
```

**목적**: 월별 연료비를 `(year, month, fuel) => 원/Gcal` 형태의 Dict로 반환한다.

**날짜 파싱**: `year_month` 컬럼이 `Date` 타입이면 `Dates.year/month`를 사용하고, 문자열이면 `"-"`로 분리하여 파싱한다.

### 3.13 fuel_prices_for_month

```julia
function fuel_prices_for_month(monthly, year, month; default_lng_chp=true)
    -> Dict{String, Float64}
```

**목적**: 특정 (연, 월)의 연료별 가격 Dict를 반환한다.

**처리**: `["nuclear", "coal", "lng", "oil", "hydro"]`에 대해 조회하고, `default_lng_chp=true`이면 `"chp"` 키에 LNG 가격을 복사한다 (CHP는 LNG 연료를 사용하므로).

### 3.14 reconstruct_potential

```julia
function reconstruct_potential(df::DataFrame, installed_capacity::NamedTuple) -> DataFrame
```

**목적**: 재생에너지 발전량을 physical availability(potential)로 재구성한다.

**가정**: 한국 육지계통 2024년에서 peak capacity factor (CF) < 1이므로, 실제 발전량이 곧 potential이라고 가정한다 (`potential = generation`).

**추가 컬럼**:
- `potential_pv`, `potential_w`: potential [MW]
- `cf_pv`, `cf_w`: capacity factor = potential / installed_capacity

**경고**: CF > 1인 데이터가 있으면 warning을 출력한다 (데이터 오류 가능성).

### 3.15 build_full_year_panel

```julia
function build_full_year_panel() -> DataFrame
```

**목적**: 2024년 전체 8784시간(윤년)의 통합 panel DataFrame을 구축한다.

**처리 단계**:
1. `load_smp_demand()` -> SMP/수요 데이터
2. `load_renewable()` -> 재생에너지 발전량
3. `load_renewables_capacity()` -> 설비용량
4. 컬럼명 정규화: `smp_mainland -> smp`, `demand_mainland -> demand`, `solar_mainland -> solar_gen`, `wind_mainland -> wind_gen`
5. date 파싱 (문자열이면 `Date()`로 변환)
6. `hour_idx = hour - 1` 추가 (0-indexed)
7. `innerjoin`으로 SMP/수요와 재생에너지 병합
8. `reconstruct_potential`으로 potential 재구성
9. `year`, `month`, `day_of_year` 컬럼 추가
10. `(date, hour)` 기준 정렬

**출력 컬럼**: `date`, `hour`, `smp`, `demand`, `solar_gen`, `wind_gen`, `potential_pv`, `potential_w`, `cf_pv`, `cf_w`, `year`, `month`, `day_of_year`

### 3.16 extract_day_input

```julia
function extract_day_input(panel::DataFrame, date::Date,
                            clusters::Vector{ThermalGenerator}) -> NamedTuple
```

**목적**: panel에서 특정 날짜의 24시간 데이터를 추출한다.

**반환 NamedTuple**:
- `T = 24`
- `demand`: 수요 벡터 [MW]
- `re_gen`: 태양광 + 풍력 합계 [MW]
- `potential_pv`, `potential_w`: 개별 potential [MW]
- `smp`: 실제 SMP [원/MWh]
- `year`, `month`, `date`

**검증**: `nrow(day) == 24` assertion -- 24시간이 아니면 에러

### 3.17 has_real_data

```julia
function has_real_data() -> Bool
```

`processed/` 폴더와 필수 파일(`generators.csv`, `smp_demand.csv`)의 존재 여부를 확인한다.

---

## 4. preprocess.jl -- 전처리 및 대표일 선정

**파일 위치**: `all_gen_real_system_src/preprocess.jl`
**역할**: 대표일 12일 선정, 한계비용 계산, Nuclear must-off 처리, Piecewise Linear 비용 구간화
**의존성**: `types.jl`, `DataFrames`, `Statistics`, `Dates`

### 4.1 DayProfile (struct)

```julia
struct DayProfile
    date::String          # 날짜 문자열
    season::String        # "spring", "summer", "fall", "winter"
    max_demand::Float64   # 일 최대수요 [MW]
    mean_smp::Float64     # 일 평균 SMP [원/MWh]
    solar_share::Float64  # 태양광 발전/총수요 비율
    wind_share::Float64   # 풍력 발전/총수요 비율
    evening_ramp::Float64 # 저녁 램프: demand[21] - demand[15]
end
```

**목적**: 하루의 주요 특성을 요약하는 프로파일이다. 대표일 선정 기준으로 사용된다.

### 4.2 get_season

```julia
function get_season(month::Int) -> String
```

| 월 | 계절 |
|---|------|
| 3, 4, 5 | spring |
| 6, 7, 8 | summer |
| 9, 10, 11 | fall |
| 12, 1, 2 | winter |

### 4.3 compute_day_profiles

```julia
function compute_day_profiles(daily_data::DataFrame) -> Vector{DayProfile}
```

**입력**: 시간별 DataFrame (컬럼: `date`, `demand`, `smp`, `solar`, `wind`)
**처리**: 날짜별로 그룹화하여 각 날의 DayProfile을 계산한다.

**evening_ramp 계산**: `demand[hour=20] - demand[hour=14]`. 데이터가 부족하면 마지막/첫 번째 값을 사용한다.

### 4.4 select_representative_days

```julia
function select_representative_days(profiles::Vector{DayProfile}; per_season::Int=3)
    -> Vector{String}
```

**목적**: 계절별 3일, 총 12일의 대표일을 선정한다.

**알고리즘** (각 계절에 대해):
1. **Peak day**: 최대수요가 가장 높은 날 (`argmax(max_demand)`)
2. **RE day**: 중간수요 이하인 날 중 재생에너지 비율(`solar_share + wind_share`)이 가장 높은 날 -- 재생에너지 영향을 가장 잘 보여주는 날
3. **Average day**: 나머지 중 평균 SMP에 가장 가까운 날 (`argmin(|mean_smp - median_smp|)`)

**반환**: 최대 12개의 날짜 문자열 (중복 제거 후)

**선정 순서**: RE day, Average day, Peak day (코드에서 `push!` 순서)

### 4.5 split_train_test_buffer

```julia
function split_train_test_buffer(profiles; per_season_test=3, per_season_train=25, buffer_days=3)
    -> NamedTuple
```

**목적**: 시계열 데이터의 train/test leakage를 방지하면서 학습/평가 세트를 분리한다.

**알고리즘**:
1. `select_representative_days`로 test 12일 선정
2. Test 날짜 양쪽 +/-3일을 buffer로 지정 (leakage 방지)
3. Test와 buffer를 제외한 나머지에서 계절별 25일씩 균등 추출 (stratified sampling)
   - 추출 방법: 후보를 정렬 후 `step = length(candidates) / n` 간격으로 추출

**반환**:
- `test_dates`: 12일 (Date 벡터)
- `train_dates`: 약 100일 (계절당 25일)
- `buffer_dates`: 제외된 날짜
- `season_label`: Dict(Date => Int) (1=spring, 2=summer, 3=fall, 4=winter)

### 4.6 extract_day_data

```julia
function extract_day_data(full_data::DataFrame, date_str::String) -> NamedTuple
```

**목적**: 날짜 문자열로 하루의 시간별 데이터를 추출한다.
**반환**: `(demand, solar, wind, smp, T, date)`

### 4.7 compute_effective_mc_from_gencost

```julia
function compute_effective_mc_from_gencost(gencost_coeff::Tuple{Float64,Float64,Float64},
                                            P::Float64) -> Float64
```

**수학적 정형화**:

```
C(P) = a * P^2 + b * P + c    [천원/h]
MC(P) = dC/dP = 2a * P + b    [천원/MWh]
       = (2aP + b) x 1000     [원/MWh]
```

**한국 시장 규정 근거**: 전력시장운영규칙 제2.4.2조 제4호에 따르면, 증분가격(IP)은 다음과 같이 계산된다:
```
IP = (2 x QPC x DAOS + LPC) / TLF / 1000
```
여기서 QPC = a (2차계수), LPC = b (1차계수), DAOS = 실제 운전점, TLF = 송전손실계수 (현재 1.0 가정)

### 4.8 build_effective_mc_matrix

```julia
function build_effective_mc_matrix(generators, gencost_dict, T) -> Matrix{Float64}  # [G x T]
```

**목적**: 발전기 x 시간 유효 한계비용 행렬의 **초기값**을 생성한다.

**처리**: 각 발전기의 중점(`P_mid = (pmin + pmax) / 2`)에서의 MC를 계산하여 모든 시간대에 동일하게 적용한다.

**주의**: 이 함수는 ED solve 전 초기 추정용이다. Piecewise linear 비용을 사용하면 목적함수에 직접 사용되지 않고, solve 후에는 `compute_actual_mc_matrix()`로 실제 운전점 MC를 재계산해야 한다.

### 4.9 compute_actual_mc_matrix

```julia
function compute_actual_mc_matrix(generators, gencost_dict, generation) -> Matrix{Float64}
```

**목적**: ED solve **이후** 실제 운전점에서의 MC 행렬을 계산한다.

**처리**:
- `P > 1e-3` (가동 중): `MC = (2aP + b) x 1000`
- `P <= 1e-3` (미가동): `MC = (2a * pmin + b) x 1000` (가격결정자격 판별용)

**의의**: 실제 운전점 MC는 한계연료원 식별과 SMP 결정에서 중요하다. 초기 중점 MC와 실제 운전점 MC는 다를 수 있다.

### 4.10 default_fuel_prices

```julia
function default_fuel_prices() -> Dict{String, Float64}
```

호환용 더미 연료가격 (원/Gcal):
- nuclear: 2,578
- coal: 34,260
- lng: 80,898
- oil: 139,934
- anthracite: 32,655

**주의**: 실제 파이프라인에서는 월별 연료비(`fuel_costs_monthly`)를 사용하므로, 이 함수는 fallback용이다.

### 4.11 NUCLEAR_NAME_TO_ID (상수)

```julia
const NUCLEAR_NAME_TO_ID = Dict{String,String}(
    "새울1호기"   => "Nuclear_001",
    "고리3호기"   => "Nuclear_002",
    ...
    "한울6호기"   => "Nuclear_025",  # 한울5,6 통합 모델 (fallback)
)
```

**목적**: 원전 정비 데이터(`nuclear_must_off.csv`)의 한글 호기명을 generators.csv의 `name` (예: "Nuclear_003")으로 변환한다.

**한국 시장 적응**: 기존에는 인덱스 기반 매핑을 사용했으나, 이는 generators.csv의 행 순서가 변경되면 오류가 발생한다. 이름 기반 매핑으로 수정하여 안정성을 확보했다.

**매핑 기준**: KPG193 MATPOWER 파일의 bus 번호, 용량, 초기상태로 대응:
- bus 82: 고리/신고리/새울
- bus 124: 한빛
- bus 166: 월성/신월성
- bus 175: 한울/신한울

**특수 케이스**: "한울5호기"와 "한울6호기"가 동일한 "Nuclear_025"에 매핑된다 (통합 모델).

### 4.12 apply_nuclear_must_off

```julia
function apply_nuclear_must_off(generators, must_off, day)
    -> (Vector{ThermalGenerator}, Vector{Tuple{String,String}})
```

**목적**: 특정 날짜의 원전 정비 일정에 따라 해당 발전기를 비가용 상태로 설정한다.

**알고리즘**:
1. `must_off` DataFrame에서 `off_start_day <= day <= off_end_day`인 호기명 수집
2. `NUCLEAR_NAME_TO_ID`로 generator_id 변환
3. 해당 발전기를 `pmin=0.0, pmax=0.0`으로 설정 (`adjust_generator_capacity` 사용)

**반환**:
- `adjusted`: 수정된 generators 벡터 (원본 복사본)
- `offline_pairs`: 정비 중인 `(호기명, generator_id)` 쌍 목록

**매핑 실패 처리**: 매핑 테이블에 없는 호기명은 `@warn`으로 경고하고 건너뛴다.

### 4.13 compute_piecewise_costs

```julia
function compute_piecewise_costs(generators, gencost_dict; S=4)
    -> Vector{PiecewiseCost}
```

**목적**: gencost의 2차 비용함수를 S개(기본 4개) 구간으로 선형 근사한다.

**알고리즘** (발전기 g에 대해):

1. **범위 결정**: `pmin` = must_run이면 `gen.pmin`, 아니면 `0.0`. `pmax = gen.pmax`.
2. **gencost 존재 + 범위 > 0**: 
   - `|a| < 1e-12` (선형 비용): 단일 구간, `mc = b x 1000`
   - 2차 비용: S등분 후 각 구간 중점 MC 계산
     ```
     delta_bar = (pmax - pmin) / S
     P_mid_s = pmin + (s - 0.5) * delta_bar
     MC_s = (2a * P_mid_s + b) * 1000
     ```
3. **gencost 없음**: 단일 구간, `mc = gen.marginal_cost`

**단위 변환**: gencost의 a, b는 천원 단위이므로 MC 계산 시 x1000으로 원/MWh 변환한다.

**활용**: Pre ED와 Post ED에서 piecewise linear 목적함수를 구성할 때 사용된다. 각 구간의 증분 변수 `delta[g, s, t]`에 해당 구간의 MC를 곱하여 비용을 계산한다.

---

## 5. build_basic_ed.jl -- Basic Economic Dispatch

**파일 위치**: `all_gen_real_system_src/build_basic_ed.jl`
**역할**: 가장 단순한 형태의 Economic Dispatch 모형을 구현한다.
**의존성**: `types.jl`, `JuMP`, `HiGHS`, `MathOptInterface`

### 5.1 수학적 정형화

```
(B1) 목적함수:  min  sum_t sum_g  c_g * p_{g,t}
(B2) 수급균형:  sum_g p_{g,t} = D_t - RE_t         for all t
(B3) 출력상한:  0 <= p_{g,t} <= P_g^max             for all g, t
(B4) SMP 해석:  lambda_t = dual(수급균형_t)
```

**특징**:
- 재생에너지를 **음의 부하**(negative load)로 처리: `net_demand = demand - re_generation`
- 시간 불변의 단순 한계비용 `c_g` 사용 (`marginal_cost` 필드)
- 최소출력, 램프, must-run 제약 **없음**

### 5.2 solve_basic_ed

```julia
function solve_basic_ed(input::EDInput) -> EDResult
```

**처리 단계**:

1. **순수요 계산**: `net_demand = demand - re_generation`
   - 음수 체크: `net_demand[t] < 0`이면 0으로 보정하고 warning

2. **JuMP 모델 구성**: HiGHS optimizer 사용 (silent 모드)

3. **결정변수**: `p[g, t]` -- 발전기 g의 시간 t 발전량 [MW]
   - 범위: `0 <= p[g,t] <= clusters[g].pmax`

4. **제약조건**: 수급균형 `sum_g p[g,t] == net_demand[t]`

5. **목적함수**: `min sum c_g * p[g,t]`

6. **SMP 추출**: `dual(balance[t])` -- 수급균형 제약의 쌍대변수
   - 최소화 문제에서 등호 제약의 dual은 수요 1MW 증가 시 비용 증가분

7. **실패 처리**: `status != OPTIMAL`이면 모든 값이 0인 `EDResult(:INFEASIBLE)` 반환

### 5.3 identify_marginal_fuel

```julia
function identify_marginal_fuel(result::EDResult, input::EDInput) -> Vector{String}
```

**목적**: 각 시간대의 한계연료원(가격결정 연료)을 식별한다.

**알고리즘**:
1. **1차 기준**: 부분 투입 클러스터 (`0 < gen < pmax`) 중 비용이 가장 높은 것
2. **Fallback**: 부분 투입이 없으면, 투입된 클러스터 (`gen > 0`) 중 최고비용

**판정 기준**: `gen > 1e-3` (부분 투입), `gen < pmax - 1e-3` (상한 미도달). 1e-3 MW의 허용오차를 사용한다.

---

## 6. build_pre_ed.jl -- Pre-revision Economic Dispatch

**파일 위치**: `all_gen_real_system_src/build_pre_ed.jl`
**역할**: 현행 제도(재생에너지 입찰제 도입 전) 하의 ED 모형. Basic ED에 최소출력, 램프, must-run, piecewise linear 비용을 추가한다.
**의존성**: `types.jl`, `JuMP`, `HiGHS`, `MathOptInterface`

### 6.1 수학적 정형화

```
(P1) 유효 한계비용: c_tilde_{g,t} = effective_mc[g,t] + price_adder[g,t]
(P2) 목적함수:  min  sum_t sum_g  c_tilde_{g,t} * p_{g,t}
     [PW버전]:  min  sum_t sum_g sum_s  MC_s * delta_{g,s,t}
                     + sum_t sum_g  adder_{g,t} * p_total_{g,t}
(P3) 수급균형:  sum_g p_{g,t} = D_t - RE_t                       for all t
(P4) 출력제약:  P_g^min <= p_{g,t} <= P_g^max                    for all g, t
(P5) 램프제약:  -RD_g <= p_{g,t} - p_{g,t-1} <= RU_g             for all g, t>=2
```

### 6.2 PreEDInput (struct)

```julia
struct PreEDInput
    base::EDInput                       # 기본 입력
    effective_mc::Matrix{Float64}       # 유효 한계비용 [G x T]
    price_adder::Matrix{Float64}        # price adder [G x T]
end
```

### 6.3 solve_pre_ed

```julia
function solve_pre_ed(input::PreEDInput;
                      pw_costs::Vector{PiecewiseCost}=PiecewiseCost[],
                      curtailment_free::Bool=false) -> EDResult
```

**핵심 매개변수**:

- `pw_costs`: 비어있지 않고 길이가 G와 같으면 piecewise linear 모드 활성화
- `curtailment_free`: 
  - `false` (default): 현행 시장 규칙. `RE > demand - must_run_pmin`이면 RE를 사전 cap (출력제한 발생)
  - `true`: RE를 must-take 상수로 주입. Calibration 단계에서 사용 -- adder가 curtailment dual pollution을 흡수하지 않도록 함

**처리 단계**:

1. **순수요 및 출력제한 계산**:
   - `curtailment_free=false`: `max_re = demand_t - must_run_pmin_sum`. `RE > max_re`이면 cap.
   - `curtailment_free=true`: `RE > demand_t`인 경우만 demand로 clip.

2. **Piecewise Linear 모드** (`use_piecewise=true`):
   - 증분 변수: `delta[g, s, t] >= 0`, 상한 = `delta_max` (구간 폭)
   - 총 출력: `p_total[g,t] = pw_costs[g].pmin + sum_s delta[g,s,t]`
   - 목적함수: `sum MC_s * delta[g,s,t] + sum adder[g,t] * p_total[g,t]`

3. **단일 변수 모드** (`use_piecewise=false`):
   - 변수: `p[g, t]`
   - must_run: `lower_bound = clusters[g].pmin`
   - 비must-run: `lower_bound = 0.0`
   - 목적함수: `sum (effective_mc[g,t] + adder[g,t]) * p[g,t]`

4. **공통 제약**:
   - 수급균형: `sum p_total[g,t] == net_demand[t]`
   - 램프: `p_total[g,t] - p_total[g,t-1] <= ramp_up` (유한한 경우만)

5. **결과 추출**: 발전량, SMP(dual), 총비용, 출력제한량

**실패 진단**: `status != OPTIMAL`이면 `must_run_pmin_sum`, 전체 `pmin_sum`, 최소 순수요를 출력한다.

### 6.4 make_pre_input

```julia
function make_pre_input(base_input::EDInput;
                        fuel_prices=nothing,
                        adder=nothing,
                        gencost_dict=nothing) -> PreEDInput
```

**목적**: Basic ED의 `EDInput`을 Pre ED 입력으로 확장한다.

**유효 한계비용 결정 우선순위**:
1. `gencost_dict` 제공 시: `build_effective_mc_matrix` 사용 (중점 MC)
2. 미제공 시: `gen.marginal_cost` fallback

**Price Adder**: `adder`가 `nothing`이면 `zeros(G, T)` (calibration 전 초기값)

### 6.5 identify_marginal_fuel_pre

```julia
function identify_marginal_fuel_pre(result, input; actual_mc=nothing) -> Vector{String}
```

**Basic ED 대비 차이**: 유효 한계비용(`effective_mc + price_adder`)을 기준으로 한계연료를 판별한다.

**actual_mc 제공 시**: 실제 운전점에서의 MC를 사용하여 더 정확한 한계연료 식별이 가능하다.

**부분 투입 판별**: `gen > pmin + 1e-3 && gen < pmax - 1e-3`. must_run의 경우 pmin 기준이 다르다.

---

## 7. build_post_ed.jl -- Post-revision Economic Dispatch

**파일 위치**: `all_gen_real_system_src/build_post_ed.jl`
**역할**: 재생에너지 입찰제 도입 후의 ED 모형. 재생에너지가 공급곡선에 참여한다.
**의존성**: `types.jl`, `build_pre_ed.jl`, `JuMP`, `HiGHS`, `MathOptInterface`

### 7.1 수학적 정형화

```
(R1) 목적함수:  min  sum_t [ sum_g c_tilde_{g,t} * p_{g,t}
                            + sum_k b_{k,t} * r_{k,t}
                            + epsilon * re_net_t ]

(R2) 수급균형:  sum_g p_{g,t} + sum_k r_{k,t} + re_net_t = D_t    for all t

(R3) 재생블록:  alpha * R_bar_{k,t} <= r_{k,t} <= R_bar_{k,t}     for all k, t
     (RE Pmin:  Pmin = min(alpha * installed_mw, avail_t))

(R4) 입찰하한:  BidFloor = -beta * REC_price * 1000                [원/MWh]

(R5) 비입찰RE:  0 <= re_net_t <= re_nonbid_t                       (Dual Pollution 방지)
```

### 7.2 PostEDInput (struct)

```julia
struct PostEDInput
    pre::PreEDInput                     # Pre ED 입력
    re_blocks::Vector{RenewableBidBlock} # 입찰 블록 (6블록)
    re_nonbid::Vector{Float64}          # 비입찰 재생발전량 [MW]
    demand::Vector{Float64}             # 총 수요 [MW] (순수요가 아님!)
end
```

**주의**: `demand`는 순수요가 아닌 **총 수요**이다. 비입찰 RE는 `re_net` 변수로 별도 처리된다.

### 7.3 build_mainland_re_blocks

```julia
function build_mainland_re_blocks(avail_pv, avail_w;
    rho_pv=0.3, rho_w=0.3,
    w_pv=(0.4, 0.3, 0.3), w_w=(0.4, 0.3, 0.3),
    rec_price=80.0, beta=2.0,
    scenario="mixed",
    installed_pv=0.0, installed_w=0.0)
    -> (Vector{RenewableBidBlock}, Vector{Float64})
```

**목적**: 육지 맞춤형 6블록 재생에너지 입찰블록을 생성한다.

**6블록 구조**:

| 블록 | tech | 가용량 | 시나리오별 입찰가 |
|------|------|--------|------------------|
| PV_low | solar | w_pv[1] * rho_pv * avail_pv | 시나리오 의존 |
| PV_mid | solar | w_pv[2] * rho_pv * avail_pv | 시나리오 의존 |
| PV_high | solar | w_pv[3] * rho_pv * avail_pv | 시나리오 의존 |
| W_low | wind | w_w[1] * rho_w * avail_w | 시나리오 의존 |
| W_mid | wind | w_w[2] * rho_w * avail_w | 시나리오 의존 |
| W_high | wind | w_w[3] * rho_w * avail_w | 시나리오 의존 |

**비입찰량**: `re_nonbid = (1 - rho_pv) * avail_pv + (1 - rho_w) * avail_w`

**입찰하한가**: `bid_floor = -(beta * rec_price * 1000.0)` [원/MWh]
- `rec_price`는 원/kWh 단위 -> x1000으로 원/MWh 변환
- 예: beta=2.0, REC=80원/kWh -> bid_floor = -160,000 원/MWh

**시나리오별 가격 전략**:

| 시나리오 | Low 블록 | Mid 블록 | High 블록 |
|---------|---------|---------|----------|
| zero | 0 | 0 | 0 |
| floor | bid_floor | bid_floor | bid_floor |
| mixed | bid_floor | 0.5 * bid_floor | 0 |
| conservative | 0.5 * bid_floor | 0.25 * bid_floor | 0 |

**설비용량(installed_mw) 계산**: `w_block * rho * installed_total`
- 예: PV_low의 installed = 0.4 * 0.3 * installed_pv = 0.12 * installed_pv

### 7.4 solve_post_ed

```julia
function solve_post_ed(input::PostEDInput;
                       pw_costs=PiecewiseCost[],
                       re_pmin_frac=0.1,
                       epsilon_nonbid=100.0,
                       bidding_active=true) -> PostEDResult
```

**핵심 매개변수**:

- `re_pmin_frac`: RE Pmin 비율 (0.1 = 10%). 낙찰 시 최소 공급 의무.
  ```
  Pmin_kt = installed_mw > 0 ? min(alpha * installed_mw, avail_kt)
                              : alpha * avail_kt  (fallback)
  ```
- `epsilon_nonbid`: 비입찰 RE의 목적함수 계수 (100 원/MWh). 양수값을 부여하여 degeneracy를 해소하고, LP dual(SMP)이 비입찰 RE의 curtailment에 오염되지 않도록 한다.
- `bidding_active`: `false`이면 `K=0` (입찰 블록 변수를 생성하지 않음). Case_A_zero에서 사용.

**Dual Pollution 방지 (개선 5)**:
- `re_net[t]` 변수를 도입: `0 <= re_net[t] <= re_nonbid[t]`
- Curtailment는 `re_nonbid[t] - re_net[t]`로 사후 계산
- `re_net`에 `epsilon_nonbid` (양수)를 부여하여 SMP와 분리

**이유**: 기존 방식에서 RE를 사전에 수요에서 빼면, must-run과의 충돌 시 LP dual에 curtailment 비용이 혼입되어 SMP가 비정상적으로 높아지는 "dual pollution" 문제가 발생한다.

**처리 단계**:

1. 열발전 변수 구성 (PW/단일 모드, Pre ED와 동일)
2. RE 입찰블록 변수: `r[k, t] >= 0`, 상한 = `avail_kt`, 하한 = `Pmin_kt`
3. 비입찰 RE: `re_net[t]` (0~re_nonbid[t])
4. 수급균형: `sum p_total + sum r + re_net == demand`
5. 목적함수: 열발전 비용 + 입찰가 x 낙찰량 + epsilon x re_net
6. SMP = `dual(balance[t])` (curtailment 오염 없음)
7. Curtailment = `re_nonbid[t] - value(re_net[t])`

### 7.5 make_post_input

```julia
function make_post_input(pre_input::PreEDInput, avail_pv, avail_w; kwargs...)
    -> PostEDInput
```

`build_mainland_re_blocks`를 호출하여 블록과 비입찰량을 생성하고, `PostEDInput`을 구성한다.

### 7.6 determine_post_smp

```julia
function determine_post_smp(post_result, input, pre_input) -> Vector{Float64}
```

**개선 5 반영**: `re_net` 변수 분리로 LP dual이 곧 SMP이다. 단순히 `post_result.base.smp`를 복사하여 반환한다. 별도의 threshold 체크나 fallback이 불필요하다.

### 7.7 compute_delta_smp

```julia
function compute_delta_smp(pre_result, post_result) -> Dict{String, Any}
```

**반환 Dict**:
- `"delta_smp"`: 시간대별 벡터 `SMP_post - SMP_pre`
- `"mean_delta"`: 24시간 평균
- `"max_decrease"`: 최대 하락 (음수)
- `"max_increase"`: 최대 상승 (양수)
- `"hours_down"`: SMP 하락 시간 수 (delta < -1e-3)
- `"hours_up"`: SMP 상승 시간 수 (delta > 1e-3)
- `"hours_same"`: 변동 없는 시간 수

---

## 8. calibrate.jl -- Price Adder Calibration

**파일 위치**: `all_gen_real_system_src/calibrate.jl`
**역할**: LP 기반 ED 모형이 실제 SMP를 재현하도록 Price Adder를 추정하고 검증한다.
**의존성**: `types.jl`, `build_pre_ed.jl`, `Statistics`, `Dates`, `Random`

### 8.1 배경: Price Adder의 필요성

LP 기반 ED 모형은 Unit Commitment(UC)의 정수적 요소(기동비, 무부하비, 정지비, 최소가동시간 등)를 직접 모형화하지 않는다. 이러한 비모형 요소를 보상하기 위해 발전기별-시간대별 보정항인 Price Adder `A_{g,t}`를 도입한다.

### 8.2 ValidationMetrics (struct)

```julia
struct ValidationMetrics
    mae::Float64              # Mean Absolute Error [원/MWh]
    rmse::Float64             # Root Mean Squared Error [원/MWh]
    max_abs_error::Float64    # 최대 절대오차 [원/MWh]
    mean_model::Float64       # 모형 평균 SMP
    mean_actual::Float64      # 실제 평균 SMP
    hourly_errors::Vector{Float64}   # 시간대별 오차
    hourly_bias::Vector{Float64}     # 시간대별 편향
    smp_model::Vector{Float64}       # 모형 SMP 벡터
    smp_actual::Vector{Float64}      # 실제 SMP 벡터
end
```

### 8.3 compute_metrics

```julia
function compute_metrics(smp_model, smp_actual) -> ValidationMetrics
```

**수학적 정의**:
```
MAE  = (1/T) * sum_t |SMP_model_t - SMP_actual_t|
RMSE = sqrt( (1/T) * sum_t (SMP_model_t - SMP_actual_t)^2 )
```

### 8.4 duration_curve / duration_curve_error

```julia
function duration_curve(smp::Vector{Float64}) -> Vector{Float64}
function duration_curve_error(smp_model, smp_actual) -> Float64
```

**목적**: SMP 지속곡선(duration curve)을 비교한다. 내림차순 정렬 후 대응 위치의 차이를 계산한다. 가격 분포의 형태를 비교하는 데 유용하다.

### 8.5 marginal_fuel_share

```julia
function marginal_fuel_share(fuels::Vector{String}) -> Dict{String, Float64}
```

연료원별 SMP 결정 비율(%)을 계산한다. 예: `{"LNG" => 75.0, "Coal" => 25.0}`

### 8.6 compute_adder_physical_bounds

```julia
function compute_adder_physical_bounds(clusters, unit_specs) -> Vector{Float64}
```

**목적**: Price Adder의 물리적 상한을 계산한다.

**공식**:
```
bound_g = (startup_cost_g * 1000) / (min_up_time_g * pmax_unit_g)  [원/MWh]
```

**해석**: Price Adder가 기동비를 최소가동시간 동안 최대출력으로 나눈 값을 초과하면 물리적으로 비합리적이다.

**반환**: 길이 G의 벡터. `unit_specs`에 해당 발전기가 없으면 `Inf` (제약 없음).

### 8.7 validate_adder_bounds

```julia
function validate_adder_bounds(adder, bounds, cluster_names) -> Bool
```

모든 발전기에 대해 `max|adder_g| <= bounds_g * 1.5`를 검사한다. 1.5배 여유를 둔다.

### 8.8 estimate_price_adder (단일일 버전)

```julia
function estimate_price_adder(base_input::EDInput, actual_smp;
                               fuel_prices=nothing,
                               max_iter=20,
                               target_mae=5000.0,
                               learning_rate=0.3,
                               l2_shrinkage=0.05,
                               adder_bounds=nothing,
                               pw_costs=PiecewiseCost[],
                               curtailment_free=true)
    -> (Matrix{Float64}, Vector{ValidationMetrics})
```

**알고리즘 상세 (반복 보정법)**:

각 iteration에서:

1. **ED 풀기**: 현재 adder로 Pre ED 실행 (`curtailment_free=true`)
2. **오차 계산**: `error_t = actual_smp[t] - model_smp[t]`
3. **활성 marginal 집합 식별 (7절)**:
   - 각 시간대에서 `pmin + 1e-3 < gen < pmax - 1e-3`인 발전기를 marginal set으로 식별
   - 이들은 LP의 수급균형 제약에서 능동적으로 가격을 결정하는 발전기
4. **1/n_marg 정규화 (7절)**: 오차를 marginal 발전기 수로 나누어 균등 분배
   ```
   share = error_t / n_marg
   adder[g, t] += learning_rate * share    (g in marg_set)
   ```
5. **Tikhonov L2 shrinkage (8절)**: `adder *= (1 - l2_shrinkage)`
   - 과적합을 방지하고 adder의 크기를 제어한다
6. **물리적 bounds clamp**: `adder[g,t] = clamp(adder[g,t], -bound, bound)`
7. **수렴 판정**: `MAE < target_mae`이면 종료

**curtailment_free=true의 의의 (9절)**: Calibration 시 RE를 must-take로 주입하면, 출력제한으로 인한 dual pollution이 adder에 흡수되는 것을 방지한다. 이렇게 추정된 "순수한" adder를 실제 평가(curtailment_free=false)에서 사용한다.

### 8.9 estimate_price_adder_multi (Multi-day 3D adder)

```julia
function estimate_price_adder_multi(base_clusters, panel, train_dates, season_label;
                                     fuel_costs_monthly=nothing,
                                     n_epochs=10,
                                     learning_rate=0.2,
                                     l2_shrinkage=0.05,
                                     target_mae=4000.0,
                                     adder_bounds=nothing,
                                     pw_costs=PiecewiseCost[],
                                     S=4,
                                     rng=Random.default_rng())
    -> (Array{Float64,3}, Vector{Float64})
```

**목적**: 다수의 학습일에서 3D adder `(G x 24 x S=4계절)`을 추정한다.

**알고리즘**:

각 epoch에서:

1. 학습일 순서를 랜덤 셔플 (`shuffle(rng, ...)`)
2. 각 학습일에 대해:
   a. 해당 날짜의 계절 인덱스(`s_idx`) 확인
   b. 해당 계절의 adder slice(`adder[:, :, s_idx]`)로 Pre ED 실행
   c. 활성 marginal + 1/n_marg 정규화로 update 누적
3. 계절별 평균 update 적용: `adder[:, :, s] += update_acc[:, :, s] / update_cnt[s]`
4. L2 shrinkage 적용
5. 물리적 bounds clamp
6. 수렴 판정: 평균 train MAE < target_mae

**반환**: `(adder3, mae_per_epoch)` -- 3D adder 행렬과 epoch별 평균 MAE

### 8.10 adder_slice_for_date

```julia
function adder_slice_for_date(adder3, date, season_label) -> Matrix{Float64}
```

3D adder에서 특정 날짜의 계절에 해당하는 `(G x 24)` 슬라이스를 반환한다.

**Fallback**: `season_label`에 해당 날짜가 없으면 월(month)로 계절을 추정한다.

### 8.11 CrossValidationResult (struct)

```julia
struct CrossValidationResult
    train_metrics::Vector{ValidationMetrics}
    test_metrics::Vector{ValidationMetrics}
    mean_train_mae::Float64
    mean_test_mae::Float64
    overfitting_ratio::Float64    # mean_test / mean_train (>1.5이면 과적합 의심)
end
```

### 8.12 cross_validate_adder

```julia
function cross_validate_adder(base_input, day_data;
                               fuel_prices=nothing,
                               max_iter=15,
                               learning_rate=0.4,
                               l2_shrinkage=0.05,
                               target_mae=3000.0,
                               adder_bounds=nothing,
                               pw_costs=PiecewiseCost[],
                               curtailment_free=true) -> CrossValidationResult
```

**목적**: Leave-One-Out Cross Validation으로 adder의 일반화 성능을 평가한다.

**알고리즘**: N개 대표일 중 1개를 test로 남기고 나머지로 adder를 추정, 이를 N번 반복.

### 8.13 print_calibration_summary

```julia
function print_calibration_summary(metrics, label="")
```

검증지표(MAE, RMSE, 최대오차, 평균 SMP, 지속곡선 오차)를 포맷팅하여 출력한다.

---

## 9. scenarios.jl -- 시나리오 분석 및 Monte Carlo

**파일 위치**: `all_gen_real_system_src/scenarios.jl`
**역할**: 4개 시나리오 정의, beta/rho 민감도 분석, Beta mixture Monte Carlo 시뮬레이션
**의존성**: `types.jl`, `build_pre_ed.jl`, `build_post_ed.jl`, `Printf`, `DataFrames`, `Statistics`, `Random`, `Distributions`

### 9.1 ScenarioConfig (struct)

```julia
struct ScenarioConfig
    name::String        # 시나리오 이름
    scenario::String    # 입찰 모드 ("zero", "floor", "mixed", "conservative")
    beta::Float64       # 하한가 계수
    rho_pv::Float64     # 태양광 입찰참여율
    rho_w::Float64      # 풍력 입찰참여율
    rec_price::Float64  # REC 가격 [원/kWh]
end
```

### 9.2 default_scenarios

```julia
function default_scenarios(; beta=2.0, rho_pv=0.3, rho_w=0.3, rec_price=80.0)
    -> Vector{ScenarioConfig}
```

**4개 기본 시나리오**:

| 시나리오 | rho_pv | rho_w | 입찰 모드 | 설명 |
|---------|--------|-------|-----------|------|
| Case_A_zero | 0.0 | 0.0 | zero | 입찰참여 없음 (baseline) |
| Case_B_floor | 0.3 | 0.3 | floor | 전량 하한가 입찰 |
| Case_C_mixed | 0.3 | 0.3 | mixed | Low=하한가, Mid=50%, High=0 |
| Case_D_conservative | 0.3 | 0.3 | conservative | Low=50%, Mid=25%, High=0 |

**Case_A_zero의 특별한 역할**: rho=0이므로 모든 RE가 비입찰이다. `bidding_active=false`로 실행되어 입찰 블록 변수가 생성되지 않는다. 이는 Pre ED와 SMP가 동치여야 한다 (11절 sanity check).

### 9.3 default_bidder_types

```julia
function default_bidder_types() -> Vector{BidderType}
```

4가지 입찰자 유형 (aggressive, moderate, conservative, PPA_locked)의 기본 설정을 반환한다. 상세는 2.7절 참조.

### 9.4 POLICY_PENETRATION_SCENARIOS (상수)

```julia
const POLICY_PENETRATION_SCENARIOS = Dict{String, NTuple{4,Float64}}(
    "S1_Early"      => (0.50, 0.30, 0.15, 0.05),
    "S2_Mature"     => (0.30, 0.40, 0.20, 0.10),
    "S3_Aggressive" => (0.15, 0.35, 0.30, 0.20),
)
```

**목적**: 정책 침투 단계별 입찰자 유형 비율을 정의한다.

| 시나리오 | aggressive | moderate | conservative | PPA_locked | 해석 |
|---------|-----------|----------|-------------|-----------|------|
| S1_Early | 50% | 30% | 15% | 5% | 초기: 공격적 입찰 지배 |
| S2_Mature | 30% | 40% | 20% | 10% | 성숙: 균형 |
| S3_Aggressive | 15% | 35% | 30% | 20% | 심화: 보수적+PPA 증가 |

### 9.5 bidder_types_for_scenario

```julia
function bidder_types_for_scenario(name::String) -> Vector{BidderType}
```

지정된 정책 침투 시나리오에 맞는 `BidderType` 벡터를 생성한다.

### 9.6 analyze_curtailment

```julia
function analyze_curtailment(curtailment, smp) -> CurtailmentAnalysis
```

출력제한량과 SMP의 통계(총량, 시간수, 최대값)를 계산하고, 두 벡터의 상관계수를 구한다. 상관계수가 음수이면 "SMP가 낮을 때 출력제한이 많다"는 경제학적 직관과 일치한다.

### 9.7 ScenarioResult (struct)

```julia
struct ScenarioResult
    config::ScenarioConfig
    post_result::PostEDResult
    delta_smp::Dict{String, Any}
    metrics::ValidationMetrics      # Post SMP vs Pre SMP 비교
    curtailment::CurtailmentAnalysis
end
```

### 9.8 run_scenarios

```julia
function run_scenarios(pre_input, pre_result, avail_pv, avail_w;
                       scenarios=nothing,
                       pw_costs=PiecewiseCost[],
                       re_pmin_frac=0.1,
                       installed_pv=0.0,
                       installed_w=0.0,
                       epsilon_nonbid=100.0) -> Vector{ScenarioResult}
```

**목적**: 다수의 시나리오를 일괄 실행한다.

**각 시나리오 처리**:
1. `rho_pv == 0 && rho_w == 0`이면 `is_zero_case = true`
2. `make_post_input`으로 PostEDInput 생성
3. `solve_post_ed(bidding_active=!is_zero_case)`
4. `determine_post_smp`로 SMP 결정
5. `compute_delta_smp`로 Pre/Post 차이 분석
6. `analyze_curtailment`로 출력제한 분석
7. **11절 sanity check**: Case_A_zero에서 `max|SMP_post - SMP_pre| < 1.0` 검증

### 9.9 run_beta_sensitivity

```julia
function run_beta_sensitivity(pre_input, pre_result, avail_pv, avail_w;
                               betas=[1.5, 2.0, 2.5], scenario="mixed", ...) -> Vector{ScenarioResult}
```

beta(하한가 계수) 값을 변화시키며 시나리오를 실행한다.

### 9.10 run_rho_sensitivity

```julia
function run_rho_sensitivity(pre_input, pre_result, avail_pv, avail_w;
                              rhos=[0.1, 0.2, 0.3, 0.5], scenario="mixed", ...) -> Vector{ScenarioResult}
```

rho(입찰참여율)를 변화시키며 시나리오를 실행한다. PV와 Wind에 동일 rho를 적용한다.

### 9.11 run_monte_carlo_scenarios

```julia
function run_monte_carlo_scenarios(pre_input, pre_result, avail_pv, avail_w;
                                    n_samples=200,
                                    beta=2.0, rec_price=80.0,
                                    rho_pv=0.3, rho_w=0.3,
                                    bidder_types=nothing,
                                    common_shock_sd=0.10,
                                    installed_pv=0.0, installed_w=0.0,
                                    seed=42,
                                    pw_costs=PiecewiseCost[],
                                    re_pmin_frac=0.1,
                                    epsilon_nonbid=100.0) -> MonteCarloResult
```

**목적**: Beta mixture + common shock Monte Carlo 시뮬레이션으로 SMP 분포를 추정한다.

**알고리즘 상세 (6절)**:

각 샘플 s에 대해:

1. **입찰자별 난수 생성**: `u_j ~ Beta(alpha_j, beta_j)` (j = 1..J)
   - aggressive: `Beta(2,5)` -- 낮은 값 경향 (0 쪽으로 치우침)
   - conservative: `Beta(5,2)` -- 높은 값 경향 (1 쪽으로 치우침)

2. **Common shock**: `kappa ~ Normal(1.0, common_shock_sd)`
   - 모든 입찰자에게 공통으로 적용되는 시장 전체 충격 (kappa < 0이면 0으로 clamp)

3. **블록별 가중 평균**: 
   ```
   u_blk[b] = sum_j (share_j * w_blocks_j[b] * u_j) / norm_w[b]
   ```
   여기서 `norm_w[b] = sum_j (share_j * w_blocks_j[b])`

4. **입찰가 결정**:
   ```
   b_blk[b] = clamp(kappa * (u_blk[b] - 1.0) * |bid_floor|, bid_floor, 0)
   ```
   - `u_blk[b] < 1`이면 음수 입찰가 (하한가 방향)
   - `u_blk[b] = 1`이면 0 (상한)
   - `kappa`가 변동성을 조절

5. **Post ED 실행**: 해당 샘플의 블록 구성으로 ED 풀기

6. **결과 집계**: 성공 샘플의 SMP에서 평균, 5th/95th percentile 계산

**출력 통계**:
- `mean_smp`: 시간대별 평균 SMP
- `p5_smp`, `p95_smp`: 90% 신뢰구간
- `mean_delta_smp`: 평균 SMP 변화 (Post - Pre)

### 9.12 scenario_summary_table

```julia
function scenario_summary_table(results::Vector{ScenarioResult}) -> DataFrame
```

시나리오 결과를 요약 DataFrame으로 변환한다.

**컬럼**: `scenario`, `beta`, `rho_pv`, `rho_w`, `bid_mode`, `mean_smp_post`, `mean_delta_smp`, `max_decrease`, `max_increase`, `hours_down`, `hours_up`, `total_re_bid_MWh`, `total_cost`, `curtailment_MWh`, `curtailment_hours`, `max_curtailment_MW`, `smp_curt_corr`

### 9.13 compare_pre_post_curtailment

```julia
function compare_pre_post_curtailment(pre_result, scenario_results) -> DataFrame
```

Pre(baseline) vs Post 시나리오별 출력제한 비교 테이블을 생성한다.

**컬럼**: `scenario`, `curtailment_MWh`, `curtailment_hours`, `reduction_pct`

### 9.14 print_scenario_summary

```julia
function print_scenario_summary(results, pre_result)
```

ASCII 테이블 형태로 시나리오 비교 결과를 콘솔에 출력한다.

---

## 10. run_all.jl -- 메인 파이프라인 오케스트레이션

**파일 위치**: `all_gen_real_system_src/run_all.jl`
**역할**: 전체 분석 파이프라인을 순차적으로 실행하고 결과를 CSV로 저장한다.
**의존성**: 모든 소스 파일, `Printf`, `CSV`, `DataFrames`, `Dates`, `Statistics`, `Random`

**실행 방법**:
```bash
cd PSE_Project1/
julia --project=. all_gen_real_system/all_gen_real_system_src/run_all.jl
```

### 10.1 상수

```julia
const SRC_DIR = @__DIR__        # 소스 파일 디렉토리
const OUT_DIR = joinpath(SRC_DIR, "..", "all_gen_real_system_outputs")
```

### 10.2 CHANGELOG_V2

v2의 모든 개선사항을 문서화한 문자열 상수이다. 1~11절의 개선계획서 항목이 나열되어 있다.

### 10.3 main() 함수 -- 파이프라인 흐름

#### PHASE 0: 데이터 로딩

```julia
panel = build_full_year_panel()           # 8784시간 통합 패널
generators = load_generators()             # 122기 발전기
unit_specs = load_unit_specs()             # 기동비/최소가동시간
gencost_dict = load_gencost()             # 2차 비용함수 계수
nuc_off_df = load_nuclear_must_off()      # 원전 정비 일정
re_cap = load_renewables_capacity()       # RE 설비용량
fuel_monthly = load_fuel_costs_monthly()  # 월별 연료비

pw_costs = compute_piecewise_costs(generators, gencost_dict; S=4)  # PW 비용
adder_bounds = compute_adder_physical_bounds(generators, unit_specs)  # 물리적 상한
```

#### PHASE 1: Train/Test/Buffer Split

```julia
profiles = compute_day_profiles(daily)
split = split_train_test_buffer(profiles;
    per_season_test=3, per_season_train=25, buffer_days=3)
```

결과: test 12일, train 약100일, buffer 약72일

#### PHASE 2: Multi-day Calibration

```julia
adder3, mae_history = estimate_price_adder_multi(
    generators, panel, split.train_dates, split.season_label;
    fuel_costs_monthly=fuel_monthly,
    n_epochs=10, learning_rate=0.2, l2_shrinkage=0.05,
    target_mae=4000.0, adder_bounds=adder_bounds,
    pw_costs=pw_costs, S=4, rng=MersenneTwister(2024))
```

3D adder `(G=122 x T=24 x S=4)` 출력. Epoch별 MAE를 `calibration_history.csv`로 저장.

#### PHASE 3: 12 대표일 평가

각 test date에 대해:

1. `extract_day_input`으로 해당일 데이터 추출
2. `fuel_prices_for_month`로 월별 연료비 조회
3. `apply_nuclear_must_off`로 원전 정비 반영
4. `compute_piecewise_costs`로 PW cost 재계산 (원전 용량 변경)
5. `adder_slice_for_date`로 해당 계절의 adder 추출
6. `build_effective_mc_matrix`로 MC matrix 생성
7. `solve_pre_ed(curtailment_free=false)` 실행
8. `compute_metrics`로 검증지표 계산
9. `run_scenarios(default_scenarios)` -- 4개 시나리오 실행

**출력 CSV**:
- `pre_result.csv`: 시간대별 Pre ED 결과 (date, hour, season, demand, pv_pot, wind_pot, smp_pre, smp_actual, error_pre, curt_pre)
- `scenario_hourly.csv`: 시나리오별 시간대별 결과 (date, hour, season, scenario, smp_pre, smp_post, delta, curt_post)

**11절 Sanity Check**: 모든 12일에서 Case_A_zero의 `max|SMP_post - SMP_pre| < 1.0` 검증

#### PHASE 4: 정책 침투도 시나리오

첫 번째 test date를 기준으로 S1_Early, S2_Mature, S3_Aggressive 시나리오에 대해 Monte Carlo 시뮬레이션(100회)을 실행한다.

```julia
mc = run_monte_carlo_scenarios(
    pre_in_r, pre_res_r, dd_r.potential_pv, dd_r.potential_w;
    n_samples=100, bidder_types=btypes, seed=2024, ...)
```

**출력 CSV**: `penetration_scenarios.csv` (scenario, hour, smp_pre, mc_mean_smp, mc_p5_smp, mc_p95_smp, mc_delta, mc_mean_curt)

#### PHASE 5: 민감도 분석

```julia
beta_results = run_beta_sensitivity(betas=[1.5, 2.0, 2.5], scenario="mixed")
rho_results = run_rho_sensitivity(rhos=[0.1, 0.2, 0.3, 0.5], scenario="mixed")
```

**출력 CSV**: `sensitivity_beta.csv`, `sensitivity_rho.csv`

#### PHASE 6: CHANGELOG + 완료

`CHANGELOG.md`를 생성하고, outputs/ 디렉토리의 파일 목록과 크기를 출력한다.

---

## 11. verify_blocks.jl -- 검증 스크립트

**파일 위치**: `all_gen_real_system_src/verify_blocks.jl`
**역할**: RE 블록 생성, Post ED SMP 결정, Dual Pollution 확인 등을 상세 검증한다.
**의존성**: 모든 소스 파일 (run_all.jl과 동일 include 구조)

**실행 방법**:
```bash
julia --project=. all_gen_real_system/all_gen_real_system_src/verify_blocks.jl
```

### 11.1 검증 1: RE 블록 생성 확인

4개 시나리오(zero, floor, mixed, conservative)에서 6블록의 입찰가, 정오(12시) 가용량, installed_mw를 출력한다.

**확인 사항**:
- 블록 수가 6개인지
- 시나리오별 가격 패턴이 올바른지 (zero=0, floor=하한가, mixed=단계적, conservative=보수적)
- installed_mw가 양수인지
- re_nonbid가 올바르게 계산되는지

### 11.2 검증 2: Post-ED SMP (Dual Pollution 수정 확인)

각 시나리오에서 Post ED를 풀고:
- `max|SMP| < 400,000`이면 Dual 오염 없음으로 판정
- Case_A_zero(zero)에서 `max|SMP_post - SMP_pre| < 1.0`이면 PASS (11절 호환성 검증)

### 11.3 검증 3: 시나리오별 SMP 비교

24시간에 대해 Pre SMP, Case_A(zero), Case_B(floor), Case_C(mixed), Case_D(conservative)의 SMP를 테이블로 출력한다. 시나리오 간 차이가 1원/MWh 이상이면 별표로 표시한다.

---

## 12. 한국 전력시장 특수 적응사항 요약

### 12.1 비용함수 체계

**일반적 ED 모형**:
```
Cost_g = heat_rate_g * fuel_price_g + vom_g
```

**본 프로젝트 (한국 CBP)**:
```
C(P) = a * P^2 + b * P + c     [천원/h]
MC(P) = (2aP + b) * 1000       [원/MWh]
```

`heat_rate`와 `vom` 필드가 struct에서 제거되었다. 한국 CBP 시장에서:
- 열소비율(Heat Rate)은 gencost의 2차 비용함수 계수 `a`에 이미 반영되어 있다
- 변동운영비(VOM)는 별도 정산되므로 발전비용에 포함하지 않는다

### 12.2 원전 정비 이름 매핑

인덱스 기반 매핑에서 **이름 기반 매핑**으로 전환하였다:

```julia
"고리4호기" => "Nuclear_003"
"한빛1호기" => "Nuclear_008"
```

이유: generators.csv의 행 순서가 변경되어도 안정적으로 매핑되도록 하기 위함이다. MATPOWER KPG193 파일의 bus 번호와 용량으로 대응 관계를 확인하였다.

### 12.3 REC 기반 입찰하한가

```
BidFloor = -beta * REC_price * 1000   [원/MWh]
```

한국의 신재생에너지 인증서(REC) 가격을 기반으로 입찰 하한가를 결정한다. 제주도형 규정(beta=2.5)을 참고하여 시나리오별 beta(1.5/2.0/2.5)를 분석한다.

### 12.4 전력시장운영규칙 근거

증분가격(IP) 계산식 (제2.4.2조 제4호):
```
IP_{i,t} = (2 * QPC_i * DAOS_{i,t} + LPC_i) / TLF / 1000
```
- QPC: 2차 비용함수 계수 (= a)
- DAOS: 실제 운전점 발전량
- LPC: 1차 비용함수 계수 (= b)
- TLF: 송전손실계수 (현재 1.0 가정)

---

## 13. 수학적 정형화 총괄

### 13.1 Basic ED

```
min   sum_{t=1}^{T} sum_{g=1}^{G}  c_g * p_{g,t}

s.t.  sum_g p_{g,t} = D_t - RE_t             (수급균형)
      0 <= p_{g,t} <= Pmax_g                  (출력범위)

SMP_t = dual(수급균형_t)
```

### 13.2 Pre-revision ED

```
min   sum_t sum_g (MC_{g,t} + A_{g,t}) * p_{g,t}

[PW 버전]
min   sum_t sum_g sum_s MC_s * delta_{g,s,t}
      + sum_t sum_g A_{g,t} * (pmin_g + sum_s delta_{g,s,t})

s.t.  sum_g p_total_{g,t} = D_t - RE_t^{eff}   (수급균형)
      Pmin_g <= p_total_{g,t} <= Pmax_g          (출력범위, must_run)
      |p_total_{g,t} - p_total_{g,t-1}| <= Ramp  (램프)
      0 <= delta_{g,s,t} <= delta_max_s           (PW 구간)
      p_total = pmin + sum_s delta_{g,s,t}        (PW 총출력)
```

### 13.3 Post-revision ED

```
min   [열발전 비용] + sum_t sum_k b_{k,t} * r_{k,t} + epsilon * sum_t re_net_t

s.t.  sum_g p_total_{g,t} + sum_k r_{k,t} + re_net_t = D_t   (수급균형)
      Pmin_kt <= r_{k,t} <= avail_{k,t}                       (RE 블록)
      0 <= re_net_t <= re_nonbid_t                             (비입찰 RE)
      + Pre ED의 모든 열발전 제약

Pmin_kt = min(alpha * installed_mw_k, avail_{k,t})
BidFloor = -beta * REC * 1000

SMP_t = dual(수급균형_t)
Curtailment_t = re_nonbid_t - re_net_t
```

### 13.4 Price Adder Calibration

```
반복 (iter = 1, ..., max_iter):
  1. Pre ED 실행 (현재 adder)
  2. error_t = SMP_actual_t - SMP_model_t
  3. marginal_set_t = {g : pmin + eps < gen_{g,t} < pmax - eps}
  4. share_t = error_t / |marginal_set_t|
  5. adder[g, t] += lr * share_t   (g in marginal_set_t)
  6. adder *= (1 - lambda_L2)       (L2 shrinkage)
  7. adder[g,t] = clamp(adder[g,t], -bound_g, bound_g)
  8. if MAE < target: break
```

### 13.5 Monte Carlo (Beta Mixture + Common Shock)

```
for s = 1, ..., N_samples:
  u_j ~ Beta(alpha_j, beta_j)          (j = 1..J, 입찰자 유형)
  kappa ~ max(0, Normal(1, sigma))      (common shock)

  u_blk[b] = sum_j (phi_j * w_j[b] * u_j) / sum_j (phi_j * w_j[b])

  bid_blk[b] = clamp(kappa * (u_blk[b] - 1) * |BidFloor|, BidFloor, 0)

  Post ED 실행 with bid_blk[b]
  SMP_s = result.smp

통계:
  mean_SMP = mean(SMP_s, dims=1)
  p5_SMP  = quantile(SMP_s[:, t], 0.05)
  p95_SMP = quantile(SMP_s[:, t], 0.95)
```

---

## 14. 의존성 그래프

```
types.jl
  |
  +-- load_data.jl
  |     |
  |     +-- preprocess.jl
  |           |
  |           +-- build_basic_ed.jl
  |           |
  |           +-- build_pre_ed.jl
  |           |     |
  |           |     +-- build_post_ed.jl
  |           |     |
  |           |     +-- calibrate.jl
  |           |           |
  |           |           +-- scenarios.jl
  |           |                 |
  |           |                 +-- run_all.jl (메인 파이프라인)
  |           |                 |
  |           |                 +-- verify_blocks.jl (검증)
```

**외부 패키지 의존성**:

| 패키지 | 사용처 | 용도 |
|--------|--------|------|
| JuMP | build_*.jl | 수리최적화 모델링 |
| HiGHS | build_*.jl | LP/MIP solver |
| MathOptInterface | build_*.jl | solver interface |
| CSV | load_data.jl, run_all.jl | CSV 읽기/쓰기 |
| DataFrames | 전체 | 데이터 조작 |
| Dates | 전체 | 날짜 처리 |
| Statistics | preprocess.jl, calibrate.jl, scenarios.jl | 통계 계산 |
| Random | calibrate.jl, scenarios.jl | 난수 생성 |
| Distributions | scenarios.jl | Beta, Normal 분포 |
| Printf | scenarios.jl, verify_blocks.jl | 포맷팅 출력 |

---

## 부록: 출력 파일 목록

| 파일명 | 생성 PHASE | 내용 |
|--------|-----------|------|
| calibration_history.csv | 2 | epoch별 train MAE |
| pre_result.csv | 3 | 12일 x 24시간 Pre ED 결과 |
| scenario_hourly.csv | 3 | 12일 x 24시간 x 4시나리오 결과 |
| penetration_scenarios.csv | 4 | S1/S2/S3 Monte Carlo 결과 |
| sensitivity_beta.csv | 5 | beta 민감도 요약 |
| sensitivity_rho.csv | 5 | rho 민감도 요약 |
| CHANGELOG.md | 6 | 버전 변경이력 |
