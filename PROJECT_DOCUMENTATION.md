# 재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석

## 프로젝트 구현 전체 문서

---

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [시스템 구조 및 파일 구성](#2-시스템-구조-및-파일-구성)
3. [자료형 정의 (types.jl)](#3-자료형-정의)
4. [데이터 파이프라인](#4-데이터-파이프라인)
5. [PHASE 1: Basic ED 모델](#5-phase-1-basic-ed-모델)
6. [PHASE 2: Calibration (Price Adder 추정)](#6-phase-2-calibration)
7. [PHASE 3: Pre-revision ED 모델](#7-phase-3-pre-revision-ed-모델)
8. [PHASE 4: Post-revision ED 모델](#8-phase-4-post-revision-ed-모델)
9. [PHASE 5: 시나리오 분석](#9-phase-5-시나리오-분석)
10. [PHASE 6: 민감도 분석](#10-phase-6-민감도-분석)
11. [SMP 결정 메커니즘 상세](#11-smp-결정-메커니즘-상세)
12. [실행 결과 요약](#12-실행-결과-요약)
13. [전체 파이프라인 실행 흐름](#13-전체-파이프라인-실행-흐름)

---

## 1. 프로젝트 개요

### 1.1 연구 목적

한국 전력시장에서 재생에너지 입찰제(제주 시범사업 방식)를 **육지계통에 확대 적용**했을 때, 계통한계가격(SMP)이 어떻게 변화하는지를 경제급전(Economic Dispatch) 모델로 분석한다.

### 1.2 분석 프레임워크

```
Basic ED (교과서형 기준선)
    ↓
Calibration (Price Adder로 실제 SMP에 보정)
    ↓
Pre-revision ED (현행 제도 하의 SMP 재현)
    ↓
Post-revision ED (재생에너지 입찰제 도입 후 SMP)
    ↓
DELTA SMP = Post SMP - Pre SMP (입찰제 효과 측정)
```

### 1.3 기술 스택

- **언어**: Julia 1.12.5
- **최적화**: JuMP + HiGHS (선형계획법 솔버)
- **SMP 도출**: LP dual (수급균형 제약의 쌍대변수)
- **데이터**: CSV.jl, DataFrames.jl

### 1.4 핵심 용어

| 용어 | 정의 |
|------|------|
| **SMP** | System Marginal Price, 계통한계가격 (원/MWh) |
| **ED** | Economic Dispatch, 경제급전 |
| **LP dual** | 선형계획법의 쌍대변수 = 수요 1MW 추가 시 총비용 변화 |
| **RE** | Renewable Energy, 재생에너지 (태양광 + 풍력) |
| **REC** | Renewable Energy Certificate, 신재생에너지 공급인증서 |
| **must-run** | 최소출력 이상 반드시 발전해야 하는 발전기 |
| **Price Adder** | 기동/정지 비용 등 UC 미모형 요소를 흡수하는 보정항 |

---

## 2. 시스템 구조 및 파일 구성

### 2.1 디렉토리 구조

```
project/
  src/
    types.jl           # 핵심 자료형 정의
    load_data.jl       # CSV 데이터 로딩
    preprocess.jl      # 전처리, 대표일 선정, 유효 한계비용 계산
    dummy_data.jl      # 합성 더미 데이터 생성
    build_basic_ed.jl  # Basic ED 모델 (PHASE 1)
    build_pre_ed.jl    # Pre-revision ED 모델 (PHASE 3)
    build_post_ed.jl   # Post-revision ED 모델 (PHASE 4)
    calibrate.jl       # Price Adder 추정 (PHASE 2)
    scenarios.jl       # 4개 시나리오 + 민감도 분석 (PHASE 5-6)
    run_all.jl         # 전체 파이프라인 통합 실행
  data/
    raw/               # 원본 CSV 데이터
    processed/         # 전처리된 데이터
  outputs/             # 분석 결과 CSV
```

### 2.2 include 순서 및 의존관계

```
run_all.jl
  ├── types.jl           (모든 모듈의 기반)
  ├── load_data.jl       (types.jl에 의존)
  ├── preprocess.jl      (types.jl에 의존)
  ├── dummy_data.jl      (types.jl에 의존)
  ├── build_basic_ed.jl  (types.jl에 의존)
  ├── build_pre_ed.jl    (types.jl에 의존)
  ├── build_post_ed.jl   (types.jl, build_pre_ed.jl에 의존)
  ├── calibrate.jl       (types.jl, build_pre_ed.jl에 의존)
  └── scenarios.jl       (types.jl, build_pre_ed.jl, build_post_ed.jl에 의존)
```

---

## 3. 자료형 정의

> 파일: `src/types.jl`

### 3.1 ThermalCluster (열발전 클러스터)

```julia
struct ThermalCluster
    name::String            # 클러스터 이름 (예: "Nuclear_base")
    fuel::String            # 연료원 ("nuclear", "coal", "lng", "oil", "chp", "hydro")
    pmin::Float64           # 최소출력 [MW]
    pmax::Float64           # 최대출력 [MW]
    ramp_up::Float64        # 상향 램프 한계 [MW/h]
    ramp_down::Float64      # 하향 램프 한계 [MW/h]
    heat_rate::Float64      # 열소비율 [Gcal/MWh]
    vom::Float64            # 변동운영비 [원/MWh]
    must_run::Bool          # must-run 여부
    marginal_cost::Float64  # 단순 한계비용 [원/MWh] (Basic ED용)
end
```

### 3.2 RenewableBidBlock (재생에너지 입찰 블록)

```julia
struct RenewableBidBlock
    name::String            # 블록 이름 ("PV_low", "PV_high", "W_low", "W_high")
    tech::String            # 기술 유형 ("solar" 또는 "wind")
    avail::Vector{Float64}  # 시간대별 공급가능량 [MW] (길이 = T)
    bid::Vector{Float64}    # 시간대별 입찰가격 [원/MWh] (길이 = T)
end
```

### 3.3 EDInput / EDResult (입출력 구조체)

```julia
struct EDInput
    T::Int                              # 시간 수 (24)
    demand::Vector{Float64}             # 시간대별 수요 [MW]
    re_generation::Vector{Float64}      # 시간대별 외생 재생발전량 [MW]
    clusters::Vector{ThermalCluster}    # 열발전 클러스터 목록
end

struct EDResult
    T::Int                              # 시간 수
    generation::Matrix{Float64}         # 클러스터별 발전량 [G x T]
    smp::Vector{Float64}                # 시간대별 SMP [원/MWh]
    total_cost::Float64                 # 총 발전비용 [원]
    cluster_names::Vector{String}
    status::Symbol                      # :OPTIMAL 등
end
```

### 3.4 Pre-ED / Post-ED 확장 구조체

```julia
struct PreEDInput
    base::EDInput                       # 기본 입력
    effective_mc::Matrix{Float64}       # 유효 한계비용 [G x T] (원/MWh)
    price_adder::Matrix{Float64}        # price adder [G x T] (원/MWh)
end

struct PostEDInput
    pre::PreEDInput                     # Pre ED 입력
    re_blocks::Vector{RenewableBidBlock} # 입찰 블록 (4개)
    re_nonbid::Vector{Float64}          # 비입찰 재생발전량 [MW]
    demand::Vector{Float64}             # 총 수요 [MW] (순수요가 아닌 전체)
end

struct PostEDResult
    base::EDResult                      # 기본 ED 결과
    re_dispatch::Matrix{Float64}        # 입찰블록별 낙찰량 [K x T]
    re_block_names::Vector{String}
end
```

---

## 4. 데이터 파이프라인

### 4.1 데이터 로딩 (load_data.jl)

`data/raw/` 폴더에 CSV 파일이 있으면 자동 탐지하여 로딩한다.

| 파일 패턴 | 로딩 대상 | 키 |
|-----------|----------|-----|
| `*smp*`, `*가격*`, `*수요*` | SMP-수요 시계열 | `"smp_demand"` |
| `*solar*`, `*wind*`, `*재생*` | 재생에너지 발전량 | `"renewable"` |
| `*설비*`, `*generator*` | 발전설비 정보 | `"generators"` |
| `*연료비*`, `*fuel*` | 월간 연료비용 | `"fuel_costs"` |
| `*결정횟수*`, `*marginal*` | 연료원별 SMP 결정횟수 | `"marginal_fuel"` |

CSV가 없으면 `dummy_data.jl`의 합성 데이터를 자동 사용한다.

### 4.2 전처리 (preprocess.jl)

#### 4.2.1 시간축 통일

공공데이터포털의 거래시간은 "끝점 표시" (hour=1 → 00:00~01:00). 이를 "시작점 표시"로 변환:

```
hour_idx = hour - 1
```

#### 4.2.2 결측/중복 처리

- 중복 행 제거 (`unique!`)
- 숫자 컬럼의 결측치를 선형보간:

```
vals[i] = vals[prev] * (1 - w) + vals[next] * w
where w = (i - prev) / (next - prev)
```

#### 4.2.3 대표일 12일 선정

계절별(봄/여름/가을/겨울) 3일씩, 총 12개 대표일 선정:

| 유형 | 선정 기준 |
|------|----------|
| **경부하-고재생일** | `solar_share + wind_share` 최대, `max_demand` 하위 50% |
| **최대부하일** | `max_demand` 최대 |
| **평균일** | `mean_smp` 중앙값에 가장 가까운 날 |

#### 4.2.4 유효 한계비용 (수식 P1)

```
c_tilde_{g,t} = HR_g * FuelPrice_{f,m} + VOM_g
```

여기서:
- `HR_g` = 열소비율 [Gcal/MWh]
- `FuelPrice_{f,m}` = 연료 f의 월 m 단가 [원/Gcal]
- `VOM_g` = 변동운영비 [원/MWh]

**기본 연료 단가** (원/Gcal):

| 연료 | 단가 |
|------|------|
| nuclear | 5,000 |
| coal | 30,000 |
| lng | 55,000 |
| oil | 70,000 |
| chp | 45,000 |
| hydro | 0 |

### 4.3 더미 데이터 (dummy_data.jl)

실제 데이터 확보 전 구조 검증용 합성 데이터.

#### 4.3.1 수요 패턴

- 기저 부하: 48,000 MW (봄철 경부하일)
- 시간대별 비율 패턴:

```
pattern = [
    0.82, 0.78, 0.76, 0.75, 0.76, 0.80,  # 00-05시: 야간 저부하
    0.85, 0.92, 0.98, 1.02, 1.05, 1.06,  # 06-11시: 오전 증가
    1.04, 1.06, 1.08, 1.07, 1.05, 1.04,  # 12-17시: 오후 피크
    1.06, 1.08, 1.05, 1.00, 0.94, 0.88   # 18-23시: 저녁->야간
]
demand[t] = 48000 * pattern[t]
```

범위: 36,000 MW (새벽) ~ 51,840 MW (저녁 피크)

#### 4.3.2 재생에너지 패턴

태양광 (최대 30,000 MW, 2024 설비용량 반영):
```
solar = [0, 0, 0, 0, 0, 200, 1500, 6000, 14000, 22000, 28000, 30000,
         30000, 29000, 25000, 18000, 10000, 3000, 300, 0, 0, 0, 0, 0]
```

풍력 (야간 약간 높음, 평균 ~3,500 MW):
```
wind = [3750, 3900, 4050, 4200, 4050, 3750, 3300, 3000, 2700, 2550, 2400, 2250,
        2100, 2250, 2400, 2700, 3000, 3300, 3600, 3900, 4200, 4350, 4200, 4050]
```

RE 합산 범위: 3,750 MW (야간) ~ 32,250 MW (정오)

#### 4.3.3 열발전 클러스터 (9개)

| 클러스터 | 연료 | pmin | pmax | ramp | must_run | MC (원/MWh) |
|---------|------|------|------|------|----------|-------------|
| Nuclear_base | nuclear | 18,000 | 24,000 | 600 | Yes | 55,000 |
| Coal_lowcost | coal | 6,000 | 16,000 | 2,000 | No | 75,000 |
| Coal_highcost | coal | 3,000 | 10,000 | 1,500 | No | 90,000 |
| LNG_CC_low | lng | 2,000 | 12,000 | 4,000 | No | 110,000 |
| LNG_CC_mid | lng | 1,500 | 10,000 | 3,500 | No | 130,000 |
| CHP_mustrun | chp | 4,000 | 6,000 | 1,000 | Yes | 95,000 |
| LNG_GT_peak | lng | 0 | 5,000 | 5,000 | No | 180,000 |
| Oil_peak | oil | 0 | 2,000 | 2,000 | No | 250,000 |
| Hydro_fixed | hydro | 0 | 4,000 | 4,000 | No | 60,000 |

- 용량 합계: ~89,000 MW
- must-run 합계: 22,000 MW (Nuclear 18,000 + CHP 4,000)

#### 4.3.4 검증용 실제 SMP (더미)

봄철 경부하일 + 고RE 침투를 반영한 패턴:
```
actual_smp = [80000, 78000, 76000, 75000, 76000, 80000,
              82000, 85000, 75000, 65000, 58000, 55000,
              55000, 58000, 65000, 80000, 100000, 125000,
              145000, 140000, 130000, 115000, 100000, 88000]
```

---

## 5. PHASE 1: Basic ED 모델

> 파일: `src/build_basic_ed.jl`

### 5.1 모델 정의

가장 단순한 형태의 경제급전. 교과서적 기준선으로 사용한다.

### 5.2 수식

#### (B1) 목적함수: 총 발전비용 최소화

```
min  SUM_t SUM_g  c_g * p_{g,t}
```

- `c_g`: 클러스터 g의 단순 한계비용 [원/MWh] (시간 불변)
- `p_{g,t}`: 클러스터 g의 시간 t 발전량 [MW]

#### (B2) 수급균형 제약

```
SUM_g p_{g,t} = D_t - RE_t    for all t
```

- `D_t`: 시간 t 수요 [MW]
- `RE_t`: 시간 t 재생에너지 발전량 [MW] (음의 부하 처리)
- 순수요 = `D_t - RE_t`

#### (B3) 출력 상한 제약

```
0 <= p_{g,t} <= P_g^max    for all g, t
```

#### (B4) SMP 해석

```
SMP_t = dual(수급균형_t) = lambda_t
```

LP의 수급균형 제약의 쌍대변수(shadow price)가 SMP이다. 이것은 **수요가 1 MW 증가할 때 총비용의 변화량**, 즉 한계비용을 나타낸다.

### 5.3 구현 로직

```
1. 순수요 계산: net_demand = demand - re_generation
2. 순수요 음수 보정: net_demand[t] = max(0, net_demand[t])
3. JuMP 모델 구성 (HiGHS 솔버)
4. 결정변수: p[g, t] in [0, pmax_g]
5. 제약: SUM_g p[g,t] == net_demand[t]
6. 목적함수: Min SUM c_g * p[g,t]
7. optimize!
8. SMP 추출: smp[t] = dual(balance[t])
```

### 5.4 한계연료원 식별

```
for each time t:
    한계 클러스터 = 부분투입(0 < gen < pmax) 상태인 클러스터 중 비용 최고
    if 부분투입 없음: 투입된 클러스터 중 비용 최고
    marginal_fuel[t] = 해당 클러스터의 연료
```

### 5.5 검증지표

```
MAE  = (1/T) * SUM_t |SMP_model_t - SMP_actual_t|
RMSE = sqrt( (1/T) * SUM_t (SMP_model_t - SMP_actual_t)^2 )
```

---

## 6. PHASE 2: Calibration

> 파일: `src/calibrate.jl`

### 6.1 목적

Basic ED는 기동/정지 비용, 무부하 비용 등 Unit Commitment(UC) 요소를 모형하지 않아 실제 SMP와 괴리가 발생한다. **Price Adder**를 도입하여 이 괴리를 보정한다.

### 6.2 Price Adder 개념

유효 한계비용에 보정항을 추가:

```
c_total_{g,t} = c_tilde_{g,t} + A_{g,t}
```

- `c_tilde_{g,t}`: 유효 한계비용 (= HR_g * FuelPrice + VOM_g)
- `A_{g,t}`: Price Adder [원/MWh] (클러스터별, 시간대별)

### 6.3 반복 보정 알고리즘

```
입력: base_input, actual_smp
매개변수: max_iter=15, target_mae=3000, learning_rate=0.4

1. adder[G, T] = 0 으로 초기화

2. for iter = 1 to max_iter:
    a. pre_input = make_pre_input(base_input, adder=adder)
    b. result = solve_pre_ed(pre_input)
    c. 검증지표 계산: MAE, RMSE
    d. if MAE < target_mae: break (수렴)
    e. for each time t:
        error_t = actual_smp[t] - model_smp[t]
        for each cluster g:
            if g가 부분투입 상태 (pmin < gen < pmax):
                adder[g, t] += learning_rate * error_t

3. return adder, history
```

**핵심**: 한계 클러스터(부분투입)만 보정한다. 한계 클러스터의 비용이 SMP를 결정하므로, 그 클러스터의 adder를 조정해야 SMP가 변한다.

### 6.4 보조 도구

**Duration Curve 비교**:
```
dc = sort(smp, reverse=true)
dc_error = mean(|dc_model - dc_actual|)
```

**연료원별 SMP 결정횟수**:
```
share[fuel] = (fuel이 한계연료인 시간 수) / T * 100%
```

---

## 7. PHASE 3: Pre-revision ED 모델

> 파일: `src/build_pre_ed.jl`

### 7.1 모델 정의

현행 한국 전력시장 제도를 모사한다. Basic ED 대비 추가 사항:
- **유효 한계비용** (시간가변, 열소비율 x 연료비 + VOM + price_adder)
- **최소출력 제약** (must-run)
- **시간간 램프 제약**
- **RE 출력제한** (초과공급 시 사전 cap)

### 7.2 수식

#### (P1) 유효 한계비용

```
c_total_{g,t} = HR_g * FuelPrice_{f,m} + VOM_g + A_{g,t}
```

#### (P2) 목적함수

```
min  SUM_t SUM_g  c_total_{g,t} * p_{g,t}
```

#### (P3) 수급균형

```
SUM_g p_{g,t} = net_demand_t    for all t
```

여기서 `net_demand_t = D_t - RE_effective_t` (RE는 사전 cap 후)

#### (P4) 최소-최대 출력 제약

```
if must_run:   P_g^min <= p_{g,t} <= P_g^max
else:          0       <= p_{g,t} <= P_g^max
```

#### (P5) 램프 제약 (t >= 2)

```
p_{g,t} - p_{g,t-1} <= RU_g   (상향 램프)
p_{g,t-1} - p_{g,t} <= RD_g   (하향 램프)
```

### 7.3 RE 출력제한 (Pre-cap) 로직

현행 시장에서는 초과공급 시 RE에 출력제한 명령을 발동한다. 이를 LP 풀기 전에 사전 처리한다.

```
must_run_min = SUM(c.pmin for c in clusters if c.must_run)
# 더미 데이터: 18,000 (Nuclear) + 4,000 (CHP) = 22,000 MW

for each time t:
    max_re = demand[t] - must_run_min
    if RE[t] > max_re and max_re > 0:
        curtailed[t] = RE[t] - max_re
        effective_re[t] = max_re
    elif max_re <= 0:
        curtailed[t] = RE[t]
        effective_re[t] = 0

net_demand = demand - effective_re
```

**이유**: 만약 RE를 LP 내의 결정변수(curtailment slack)로 넣으면, 슬랙의 페널티(500,000원)가 LP dual에 포함되어 SMP가 왜곡된다. LP 외부에서 사전 cap하면 깨끗한 dual을 얻을 수 있다.

### 7.4 SMP 도출

```
SMP_t = dual(balance[t])
```

Basic ED와 동일하게 수급균형 제약의 LP dual을 SMP로 사용.

---

## 8. PHASE 4: Post-revision ED 모델

> 파일: `src/build_post_ed.jl`

### 8.1 모델 정의

재생에너지 입찰제 도입 후의 시장을 모사한다. **Pre-revision ED와의 핵심 차이점**:

1. RE의 일부(입찰참여분 rho)가 **입찰블록**으로 공급곡선에 직접 참여
2. 입찰블록이 **가격결정 자격**을 가짐 (제주 시범사업 규칙 [R4])
3. 수급균형에 **총수요**(순수요가 아닌)를 사용

### 8.2 RE 분리 구조

```
총 RE = 비입찰분(nonbid) + 입찰분(bid blocks)

비입찰분: (1-rho) * RE_total → 음의 부하로 처리 (현행과 동일)
입찰분:   rho * RE_total → 4개 블록으로 분할하여 공급곡선에 참여
```

### 8.3 입찰블록 생성 (build_mainland_re_blocks)

#### 8.3.1 참여분/비참여분 분리

```
pv_bid_total = rho_pv * avail_pv
w_bid_total  = rho_w  * avail_w
re_nonbid = (1 - rho_pv) * avail_pv + (1 - rho_w) * avail_w
```

기본값: `rho_pv = rho_w = 0.3` (30% 입찰참여)

#### 8.3.2 Low/High 블록 분할

각 기술(PV, Wind)의 입찰분을 Low/High 두 블록으로 분할:

```
PV_low_avail  = w_pv_low  * pv_bid_total   (w_pv = (0.6, 0.4))
PV_high_avail = w_pv_high * pv_bid_total
W_low_avail   = w_w_low   * w_bid_total    (w_w = (0.6, 0.4))
W_high_avail  = w_w_high  * w_bid_total
```

결과: **4개 블록** (PV_low, PV_high, W_low, W_high)

#### 8.3.3 입찰 하한가 (수식 R4)

```
BidFloor = -beta * REC_price * 1000
```

- `beta`: 하한가 계수 (기본 2.0, 민감도 분석에서 1.5/2.5)
- `REC_price`: REC 평균가격 (80 원/kWh)
- `* 1000`: 원/kWh → 원/MWh 변환

기본값: `BidFloor = -2.0 * 80 * 1000 = -160,000 원/MWh`

#### 8.3.4 시나리오별 입찰가격

| 시나리오 | Low 블록 입찰가 | High 블록 입찰가 |
|---------|---------------|-----------------|
| Case A (zero) | 0 | 0 |
| Case B (floor) | BidFloor (-160,000) | BidFloor (-160,000) |
| Case C (mixed) | BidFloor (-160,000) | 0 |
| Case D (conservative) | 0.5 * BidFloor (-80,000) | 0 |

### 8.4 수식

#### (R1) 목적함수

```
min  SUM_t [ SUM_g c_total_{g,t} * p_{g,t}
           + SUM_k b_{k,t} * r_{k,t}
           + M * re_curt_t ]
```

- `p_{g,t}`: 열발전 출력 [MW]
- `r_{k,t}`: RE 입찰블록 k의 낙찰량 [MW]
- `b_{k,t}`: RE 입찰블록 k의 입찰가 [원/MWh]
- `re_curt_t`: 비입찰 RE 출력제한량 [MW]
- `M = 500,000`: 출력제한 페널티 [원/MWh]

#### (R2) 수급균형

```
SUM_g p_{g,t} + SUM_k r_{k,t} + RE_nonbid_t - re_curt_t = D_t    for all t
```

**핵심**: 총수요 `D_t`를 사용한다 (Pre-ED의 순수요가 아님). 열발전, RE 입찰블록, 비입찰 RE가 모두 공급측에서 통합 최적화된다.

#### (R3) RE 블록 출력 제약

```
0 <= r_{k,t} <= R_bar_{k,t}    for all k, t
```

- `R_bar_{k,t}`: 블록 k의 시간 t 공급가능량 [MW]

#### (R4) 열발전 제약 (Pre-ED와 동일)

```
P_g^min <= p_{g,t} <= P_g^max   (must_run)
0       <= p_{g,t} <= P_g^max   (otherwise)
```

#### (R5) 램프 제약 (Pre-ED와 동일)

```
p_{g,t} - p_{g,t-1} <= RU_g
p_{g,t-1} - p_{g,t} <= RD_g
```

#### (R6) 비입찰 RE 출력제한

```
0 <= re_curt_t <= RE_nonbid_t
```

### 8.5 SMP 결정: LP dual 기반

> 함수: `determine_post_smp()`

Post-ED의 SMP는 **수급균형 제약의 LP dual**을 직접 사용한다.

#### 8.5.1 LP dual의 경제학적 의미

```
SMP_t = dual(balance_t) = dC*/dD_t
```

이것은 **수요가 1 MW 증가할 때 총비용의 변화량**이다. LP 최적해에서 자동으로 도출되며, 열발전과 RE 입찰블록이 통합된 상태에서의 정확한 한계비용이다.

#### 8.5.2 시나리오별 차별화 원리

초과공급 시간대(RE가 풍부한 낮 시간)에서:

- RE 블록이 **한계유닛**(부분 낙찰 상태)이 되면, LP dual은 해당 RE 블록의 입찰가를 반영한다.
- 시나리오별로 RE 입찰가가 다르므로 LP dual도 달라진다.

```
Case A: RE bid=0          → LP dual ≈ 0
Case B: RE bid=-160,000   → LP dual ≈ -160,000
Case C: Low bid=-160,000  → LP dual ≈ -160,000 (Low가 한계일 때)
                             LP dual ≈ 0 (High가 한계일 때)
Case D: Low bid=-80,000   → LP dual ≈ -80,000 (Low가 한계일 때)
```

#### 8.5.3 Curtailment 오염 보정

비입찰 RE의 curtailment가 활성화되면 페널티(500,000원)가 LP dual에 포함될 수 있다. 이 경우 보조 휴리스틱으로 대체한다:

```
if |LP_dual| > 400,000:   # curtailment 오염 의심
    SMP = _find_marginal_from_dispatch(...)  # 부분투입 유닛 기반 폴백
else:
    SMP = LP_dual
```

폴백 순서:
1. RE 부분투입 블록의 입찰가 (우선)
2. 열발전 부분투입 클러스터의 비용
3. 투입된 유닛 중 최고비용

### 8.6 DELTA SMP 분석

```
delta_smp_t = SMP_post_t - SMP_pre_t

mean_delta   = (1/T) * SUM_t delta_smp_t
max_decrease = min(delta_smp)    # 최대 하락
max_increase = max(delta_smp)    # 최대 상승
hours_down   = count(delta < 0)  # SMP 하락 시간 수
hours_up     = count(delta > 0)  # SMP 상승 시간 수
```

---

## 9. PHASE 5: 시나리오 분석

> 파일: `src/scenarios.jl`

### 9.1 4개 시나리오 정의

| 시나리오 | 코드명 | Low 블록 | High 블록 | 정책적 의미 |
|---------|--------|---------|----------|-----------|
| **Case A** | `zero` | 0원 | 0원 | RE가 0원으로 입찰 (가격결정 최소 영향) |
| **Case B** | `floor` | -160,000원 | -160,000원 | 모든 블록이 하한가로 공격적 입찰 |
| **Case C** | `mixed` | -160,000원 | 0원 | Low=하한가, High=0 (현실적 혼합) |
| **Case D** | `conservative` | -80,000원 | 0원 | Low=50%하한가, High=0 (보수적) |

### 9.2 시나리오 실행 흐름

```
for each scenario:
    1. post_input = make_post_input(pre_input, avail_pv, avail_w; scenario=...)
       → build_mainland_re_blocks()로 4개 블록 생성
       → re_nonbid 계산

    2. post_result = solve_post_ed(post_input)
       → 열발전 + RE블록 통합 LP 최적화
       → LP dual 추출

    3. post_smp = determine_post_smp(post_result, post_input, pre_input)
       → LP dual 기반 SMP 결정
       → curtailment 오염 시 폴백

    4. delta = compute_delta_smp(pre_result, adjusted_post)
       → DELTA SMP = Post SMP - Pre SMP

    5. metrics = compute_metrics(post_smp, pre_smp)
       → MAE, RMSE 등 검증지표
```

---

## 10. PHASE 6: 민감도 분석

### 10.1 beta 민감도

하한가 계수 beta를 변경하여 입찰 하한가의 영향을 분석한다.

```
beta 값: [1.5, 2.0, 2.5]
고정: scenario="mixed", rho=0.3, rec_price=80

BidFloor = -beta * 80 * 1000
  beta=1.5: BidFloor = -120,000 원/MWh
  beta=2.0: BidFloor = -160,000 원/MWh
  beta=2.5: BidFloor = -200,000 원/MWh
```

### 10.2 rho 민감도

입찰참여율 rho를 변경하여 참여 규모의 영향을 분석한다.

```
rho 값: [0.1, 0.2, 0.3, 0.5]
고정: scenario="mixed", beta=2.0, rec_price=80

rho=0.1: 전체 RE의 10%만 입찰 → 시장 영향 최소
rho=0.5: 전체 RE의 50%가 입찰 → 시장 영향 최대
```

---

## 11. SMP 결정 메커니즘 상세

### 11.1 3가지 모델의 SMP 비교

| 모델 | RE 처리 | SMP 도출 |
|------|---------|---------|
| **Basic ED** | 음의 부하 (net_demand = D - RE) | LP dual of `SUM p = net_demand` |
| **Pre-revision ED** | 음의 부하 + RE 사전 cap | LP dual of `SUM p = net_demand` |
| **Post-revision ED** | nonbid=음의 부하 + bid=공급곡선 참여 | LP dual of `SUM p + SUM r + nonbid = D` |

### 11.2 Pre-ED vs Post-ED의 핵심 차이

**Pre-ED:**
```
SUM_g p_{g,t} = D_t - RE_total_t
```
- RE 전체가 수요에서 차감됨
- 열발전만으로 순수요를 충족
- SMP = 열발전 한계비용만 반영

**Post-ED:**
```
SUM_g p_{g,t} + SUM_k r_{k,t} + RE_nonbid_t = D_t
```
- RE의 일부(입찰분)가 공급곡선에 참여
- 열발전 + RE 입찰블록이 통합 급전순위에서 경쟁
- SMP = 통합 급전순위의 한계유닛 비용 (RE일 수도 있음)

### 11.3 초과공급 시 SMP 결정

초과공급 시간대 (must_run + RE > demand):

**Pre-ED:**
- RE를 사전 cap: `effective_re = min(RE, demand - must_run_pmin)`
- 열발전은 must_run pmin에 고정
- SMP = must_run 열발전의 calibrated 비용 (LP dual)

**Post-ED:**
- RE 비입찰분 + 열발전 must_run으로도 수요를 충족 가능
- RE 입찰블록은 일부만 낙찰 (부분 낙찰 = 한계유닛)
- SMP = 한계 RE 블록의 입찰가 (음수 가능)

### 11.4 왜 LP dual을 사용하는가 (vs 휴리스틱)

이전 구현에서는 `max(thermal_marginal, re_bid_max)` 휴리스틱을 사용했으나, 이 방식에는 **구조적 결함**이 있었다:

**문제**: 열발전과 RE가 동시에 부분투입일 때, `max()` 연산은 항상 열발전 비용(양수)을 선택한다. RE 입찰가(음수 또는 0)는 무시된다.

```
예시 (hour 11, oversupply):
  Nuclear: 부분투입, cost = +12,500
  PV_low:  부분투입, bid = -160,000 (Case B)
  max(12500, -160000) = 12500  ← 모든 시나리오에서 동일!
```

**LP dual 방식**:
```
  Case A: dual = 0        (RE bid=0이 한계)
  Case B: dual = -160,000 (RE bid=-160,000이 한계)
  Case C: dual = -160,000 (Low block이 한계)
  Case D: dual = -80,000  (Low block bid=-80,000이 한계)
  ← 시나리오별로 정확히 차별화!
```

LP dual은 다음을 자동으로 반영한다:
1. **통합 급전순위**: 열발전과 RE가 비용/입찰가 기준으로 하나의 순서에서 경쟁
2. **램프 제약**: 시간간 결합 효과
3. **한계유닛 식별**: 수요 1MW 변화에 실제로 반응하는 유닛

---

## 12. 실행 결과 요약

### 12.1 SMP 정합도 비교

| 모델 | MAE (원/MWh) | RMSE (원/MWh) | 평균 SMP (원/MWh) |
|------|-------------|--------------|------------------|
| Basic ED | 14,625 | 23,226 | 72,292 |
| Pre ED | 42,843 | 133,228 | 44,116 |
| Actual | - | - | 86,917 |

### 12.2 4개 시나리오 결과

| 시나리오 | 평균 SMP (원/MWh) | 평균 DELTA SMP | 최대 하락 | 하락 시간 | 상승 시간 | RE 입찰 낙찰량 (MWh) |
|---------|------------------|---------------|----------|----------|----------|-------------------|
| Pre (baseline) | 44,116 | - | - | - | - | - |
| **Case A (zero)** | 64,843 | **+20,727** | -73,256 | 5 | 3 | 61,795 |
| **Case B (floor)** | 50,332 | **+6,216** | -160,000 | 5 | 2 | 73,565 |
| **Case C (mixed)** | 53,965 | **+9,849** | -160,000 | 6 | 3 | 72,309 |
| **Case D (conservative)** | 55,729 | **+11,613** | -80,000 | 8 | 3 | 67,615 |

### 12.3 beta 민감도 결과 (mixed 시나리오)

| beta | BidFloor (원/MWh) | 평균 DELTA SMP | 최대 하락 |
|------|------------------|---------------|----------|
| 1.5 | -120,000 | +10,984 | -120,000 |
| 2.0 | -160,000 | +9,849 | -160,000 |
| 2.5 | -200,000 | +9,849 | -200,000 |

### 12.4 rho 민감도 결과 (mixed 시나리오)

| rho | 평균 DELTA SMP | 최대 하락 | 하락 시간 | RE 낙찰량 (MWh) |
|-----|---------------|----------|----------|----------------|
| 0.1 | +20,018 | -2 | 1 | 17,690 |
| 0.2 | +6,216 | -160,000 | 5 | 43,870 |
| 0.3 | +9,849 | -160,000 | 6 | 72,309 |
| 0.5 | +17,830 | -108,803 | 6 | 123,465 |

### 12.5 결과 해석

1. **Case B(floor)**가 SMP를 가장 크게 낮춘다: 모든 RE 블록이 하한가(-160,000원)로 입찰하면 초과공급 시간대에서 SMP가 극단적으로 하락한다.

2. **Case A(zero)**는 SMP 하락이 가장 적다: RE가 0원으로 입찰하면 초과공급 시 SMP가 0 근처까지만 하락한다.

3. **Case C와 D의 차이**: D(보수적)는 Low 블록 입찰가가 C의 절반(-80,000 vs -160,000)이므로, 초과공급 시 SMP 하락폭이 더 작다.

4. **rho 효과**: 참여율이 낮으면(0.1) RE 블록이 너무 작아 한계유닛이 되지 못하고, 참여율이 높으면(0.5) RE가 공급곡선의 큰 부분을 차지하여 시장 구조 자체가 변한다.

---

## 13. 전체 파이프라인 실행 흐름

> 파일: `src/run_all.jl`

```
PHASE 0: 데이터 준비
  ├── has_real_data() 확인
  ├── 실제 데이터 있으면 load_all_data()
  └── 없으면 make_dummy_input(24), make_dummy_actual_smp(24)
      + avail_pv, avail_w 배열 설정

PHASE 1: Basic ED
  ├── solve_basic_ed(base_input)
  ├── compute_metrics(basic_smp, actual_smp)
  └── basic_result.csv 저장

PHASE 2: Calibration
  ├── default_fuel_prices()
  ├── estimate_price_adder(base_input, actual_smp;
  │     fuel_prices, max_iter=15, target_mae=3000, learning_rate=0.4)
  └── calibration_history.csv 저장

PHASE 3: Pre-revision ED
  ├── make_pre_input(base_input; fuel_prices, adder)
  ├── solve_pre_ed(pre_input)
  │   └── RE 사전 cap → LP solve → LP dual = SMP
  ├── identify_marginal_fuel_pre(pre_result, pre_input)
  └── pre_result.csv 저장

PHASE 4: Post-revision ED (4개 시나리오)
  ├── run_scenarios(pre_input, pre_result, avail_pv, avail_w)
  │   └── for each scenario (A/B/C/D):
  │       ├── make_post_input() → build_mainland_re_blocks()
  │       ├── solve_post_ed()   → 통합 LP 최적화
  │       ├── determine_post_smp() → LP dual 기반 SMP
  │       └── compute_delta_smp() → DELTA SMP 분석
  ├── scenario_summary.csv 저장
  └── scenario_hourly.csv 저장

PHASE 5: 민감도 분석
  ├── run_beta_sensitivity(betas=[1.5, 2.0, 2.5])
  │   └── sensitivity_beta.csv 저장
  └── run_rho_sensitivity(rhos=[0.1, 0.2, 0.3, 0.5])
      └── sensitivity_rho.csv 저장

PHASE 6: 전체 요약 출력
  └── SMP 정합도 비교 테이블 + 출력 파일 목록
```

### 출력 파일 목록

| 파일 | 내용 |
|------|------|
| `basic_result.csv` | 시간대별 수요, RE, 순수요, Basic SMP, Actual SMP, 오차 |
| `calibration_history.csv` | 반복별 MAE, RMSE |
| `pre_result.csv` | 시간대별 Pre SMP, 한계연료원, 클러스터별 발전량 |
| `scenario_summary.csv` | 시나리오별 요약 (평균 SMP, DELTA SMP, 시간 수 등) |
| `scenario_hourly.csv` | 시간대별 Pre SMP, 4개 시나리오 Post SMP, DELTA SMP |
| `sensitivity_beta.csv` | beta 민감도 결과 |
| `sensitivity_rho.csv` | rho 민감도 결과 |
