# real_system_src 코드 상세 분석

> 실제 2024년 한국 육지계통 데이터를 사용하는 경제급전 분석 코드

---

## 1. 파일 구성

| 파일 | 역할 | 행 수 |
|------|------|-------|
| `real_load_data.jl` | 실데이터 CSV 로딩 및 구조체 변환 | ~180행 |
| `real_preprocess.jl` | 대표일 선정 및 전처리 | ~140행 |
| `real_run_all.jl` | 6 Phase 파이프라인 실행 및 결과 저장 | ~320행 |

---

## 2. `real_load_data.jl` — 데이터 로딩

### 함수 목록

| 함수 | 입력 | 출력 | 설명 |
|------|------|------|------|
| `load_real_smp_demand(raw_dir)` | CSV 경로 | DataFrame(8,784행) | SMP + 수요 시계열 로딩, 컬럼명 자동 매핑 |
| `load_real_renewable(raw_dir)` | CSV 경로 | DataFrame(8,784행) | 태양광/풍력 발전량, 파일명 패턴 매칭 |
| `load_real_generators(raw_dir)` | CSV 경로 | Vector{ThermalCluster}[8] | 8개 클러스터 (CHP 제거, VOM=0) |
| `load_real_fuel_costs(raw_dir)` | CSV 경로 | (Dict, Dict) | 월별 연료단가 + 연간 평균 |
| `load_real_gencost(raw_dir)` | CSV 경로 | Dict{name→(a,b,c)} | 2차 비용함수 계수 |
| `load_real_genthermal(raw_dir)` | CSV 경로 | Vector{ThermalUnitSpec}[8] | 기동비/최소가동시간 |
| `load_real_nuclear_must_off(raw_dir)` | CSV 경로 | DataFrame(18행) | 원전 정비 일정 |
| `load_real_marginal_fuel_counts(raw_dir)` | CSV 경로 | DataFrame(366행) | 연료원별 SMP 결정횟수 (선택) |
| `load_all_real_data(raw_dir)` | CSV 경로 | NamedTuple | 전체 통합 로딩 |

### 기존 src/load_data.jl과의 차이

| 항목 | 기존 src | real_system_src |
|------|---------|----------------|
| 클러스터 수 | 9 (CHP 포함) | **8** (CHP 제거) |
| VOM | 500~8,000 | **0** (한국 CBP 시장) |
| 연료단가 | 고정값 / 자동탐색 | **월별 실데이터** (fuel_dict) |
| 컬럼 매핑 | 범용 패턴 | **한국어 컬럼 직접 매핑** |
| 출력 | Dict{String, DataFrame} | **NamedTuple** (타입 안전) |

### 컬럼명 매핑 규칙

```
날짜 / date → :date
거래시간 / hour → :hour
smp_육지 / SMP → :smp
수요_육지 / demand → :demand
태양광_합계 / solar → :solar
풍력_육지 / wind → :wind
```

---

## 3. `real_preprocess.jl` — 전처리

### 구조체

```julia
struct RealDayProfile
    date::String        # "2024-01-23"
    month::Int          # 1~12
    season::String      # "spring"/"summer"/"fall"/"winter"
    max_demand::Float64 # 일 최대수요 (MW)
    mean_demand::Float64
    mean_smp::Float64   # 일평균 SMP (원/MWh)
    total_re::Float64   # 일 총 RE 발전량 (MWh)
    re_share::Float64   # RE / Demand 비율
    solar_share::Float64
    wind_share::Float64
end
```

### 함수 목록

| 함수 | 설명 |
|------|------|
| `get_season(month)` | 월 → 계절 매핑 (3-5:봄, 6-8:여름, 9-11:가을, 12-2:겨울) |
| `compute_real_day_profiles(merged)` | 366일 프로파일 생성 |
| `select_real_representative_days(profiles)` | 12일 대표일 선정 (계절별 3일) |
| `extract_real_day(merged, date)` | 특정 날짜 24시간 데이터 추출 |
| `compute_real_effective_mc(clusters, fuel_dict, date, T)` | 유효한계비용 행렬 [G×T] 산출 |
| `adjust_nuclear_for_day(clusters, must_off, date)` | 원전 정비 반영 용량 조정 |

### 대표일 선정 기준

각 계절에서 3일 선정 (총 12일):
1. **최대부하일**: 일 최대수요가 가장 큰 날
2. **경부하·고재생일**: RE 점유율 최대 & 수요 하위 50%
3. **평균SMP일**: 일평균 SMP가 중위수에 가장 가까운 날

### 유효한계비용 산출

```
MC[g,t] = HR[g] × FuelPrice[month, fuel[g]]    (VOM = 0)
```

- 월별 연료단가를 date에서 추출하여 해당 월의 단가 적용
- `heat_rate`는 DATA_SPEC 참조값 사용

### 원전 용량 동적 조정

```
available_pmax = (24기 - 정비호기수) × 1,000 MW
available_pmin = available_pmax × 0.75
```

---

## 4. `real_run_all.jl` — 파이프라인

### 재사용하는 기존 src/ 모듈

| 모듈 | 재사용 함수 |
|------|-----------|
| `types.jl` | ThermalCluster, EDInput, EDResult 등 전체 구조체 |
| `build_basic_ed.jl` | `solve_basic_ed`, `compute_basic_metrics`, `identify_marginal_fuel` |
| `build_pre_ed.jl` | `solve_pre_ed`, `identify_marginal_fuel_pre`, PreEDInput |
| `build_post_ed.jl` | `solve_post_ed`, `build_mainland_re_blocks`, PostEDInput |
| `calibrate.jl` | `estimate_price_adder`, `compute_adder_physical_bounds` |
| `scenarios.jl` | `default_scenarios`, `run_scenarios`, `run_beta/rho_sensitivity`, `run_monte_carlo_scenarios` |
| `preprocess.jl` | `compute_piecewise_costs`, `compute_nuclear_availability` |

### 실행 흐름

```
PHASE 0: 데이터 로딩
  └─ load_all_real_data() → 8,784행 병합 데이터
  └─ compute_real_day_profiles() → 366일 프로파일
  └─ select_real_representative_days() → 12일
  └─ compute_piecewise_costs() → S=4 segment 비용함수
  └─ compute_adder_physical_bounds() → Price Adder 상한

FOR EACH 대표일 (12일):
  ├─ PHASE 1: Basic ED
  │   └─ solve_basic_ed() → SMP, generation
  │
  ├─ PHASE 2: Calibration
  │   └─ estimate_price_adder(max_iter=15, target_mae=3000)
  │
  ├─ PHASE 3: Pre-revision ED
  │   └─ solve_pre_ed(with piecewise costs)
  │
  ├─ PHASE 4: Post-revision ED
  │   ├─ 4 scenarios (zero/floor/mixed/conservative)
  │   └─ Monte Carlo (100 samples)
  │
  └─ PHASE 5: Sensitivity
      ├─ β sweep: [1.5, 2.0, 2.5]
      └─ ρ sweep: [0.1, 0.2, 0.3, 0.5]

결과 저장: outputs_real_system/ (9개 CSV)
```

### 출력 파일

| 파일 | 행 수 | 내용 |
|------|-------|------|
| `basic_result.csv` | 288 (12일×24h) | Basic ED 시간별 결과 |
| `calibration_history.csv` | ~180 | Price Adder 보정 이력 |
| `pre_result.csv` | 288 | Pre-ED 시간별 결과 |
| `scenario_summary.csv` | 48 (12일×4시나리오) | 시나리오별 요약 |
| `scenario_hourly.csv` | 1,152 (12일×24h×4) | 시나리오 시간별 |
| `curtailment_analysis.csv` | 48 | 출력제한 분석 |
| `monte_carlo_result.csv` | 288 | MC 시뮬레이션 결과 |
| `sensitivity_beta.csv` | 36 (12일×3β) | β 민감도 |
| `sensitivity_rho.csv` | 48 (12일×4ρ) | ρ 민감도 |

---

## 5. 기존 src/와의 핵심 차이 요약

| 항목 | 기존 src/ | real_system_src/ |
|------|----------|-----------------|
| 데이터 소스 | `dummy_data.jl` (합성) | **실제 CSV** (EPSIS, KPX, KPG193) |
| 대표일 | 1일 (더미) | **12일** (계절별 3일 자동 선정) |
| 클러스터 | 9개 | **8개** (CHP 제거) |
| VOM | 500~8,000 | **0** |
| 연료단가 | 고정 | **월별 실데이터** |
| 원전 정비 | 더미 5건 | **실제 18건** (한수원) |
| SMP 비교 대상 | 더미 패턴 | **실제 SMP** (2024 EPSIS) |
| 결과 폴더 | `outputs/` | **`outputs_real_system/`** |
