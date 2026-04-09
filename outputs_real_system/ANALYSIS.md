# outputs_real_system 결과 분석

> 실행일: 2026-04-09  
> 데이터: 2024년 한국 육지계통 실데이터  
> 대표일: 12일 (계절별 3일)

---

## 1. 선정된 대표일 12일

| 날짜 | 계절 | 최대수요 (MW) | 평균SMP (원/MWh) | RE점유율 |
|------|------|-------------|----------------|---------|
| 2024-01-23 | 겨울 | 89,231 | 162,456 | 1.8% |
| 2024-02-12 | 겨울 | 61,340 | 85,473 | 3.6% |
| 2024-03-05 | 봄 | 81,691 | 135,985 | 0.8% |
| 2024-05-16 | 봄 | 65,411 | 124,088 | 5.2% |
| 2024-05-22 | 봄 | 68,837 | 129,553 | 3.4% |
| 2024-06-16 | 여름 | 63,577 | 112,178 | 4.2% |
| 2024-06-21 | 여름 | 77,749 | 131,643 | 2.6% |
| 2024-08-20 | 여름 | 97,115 | 157,355 | 1.8% |
| 2024-09-11 | 가을 | 93,246 | 150,372 | 1.3% |
| 2024-10-20 | 가을 | 59,093 | 96,088 | 3.7% |
| 2024-10-25 | 가을 | 68,375 | 120,622 | 2.2% |
| 2024-12-24 | 겨울 | 82,612 | 124,757 | 2.2% |

---

## 2. 출력 파일별 상세

### 2.1 `basic_result.csv` (288행)

Basic ED (교과서형 경제급전) 결과.

| 컬럼 | 설명 |
|------|------|
| date, hour | 날짜, 시간 |
| demand | 실제 수요 (MW) |
| re | 재생에너지 발전량 (MW) |
| net_demand | 순수요 = demand - re (MW) |
| smp_model | Basic ED SMP (원/MWh) |
| smp_actual | 실제 SMP (원/MWh) |
| smp_error | 모형 - 실제 (원/MWh) |
| marginal_fuel | SMP 결정 연료 |
| Nuclear_base ~ Hydro_fixed | 클러스터별 발전량 (MW) |

Basic ED는 pmin, ramp, must-run 제약 없이 단순 비용 최소화로 풀기 때문에 실제 SMP와 차이가 큽니다. 이 차이를 Price Adder 보정으로 줄이는 것이 Phase 2의 역할입니다.

---

### 2.2 `calibration_history.csv` (180행)

Price Adder 반복 보정 이력 (12일 x 15 iterations).

| 컬럼 | 설명 |
|------|------|
| date | 대표일 |
| iteration | 반복 차수 (1~15) |
| mae | Mean Absolute Error (원/MWh) |
| rmse | Root Mean Squared Error (원/MWh) |
| mean_model | 모형 평균 SMP |
| mean_actual | 실제 평균 SMP |

보정 과정에서 MAE가 반복 수가 증가할수록 감소하는 추세를 보입니다. target_mae(3,000원/MWh) 미달 시 15회에서 종료됩니다.

---

### 2.3 `pre_result.csv` (288행)

Pre-revision ED (현행 SMP 재현 모델) 결과.

| 컬럼 | 설명 |
|------|------|
| date, hour | 날짜, 시간 |
| smp_model | Pre-ED SMP (보정 후, 원/MWh) |
| smp_actual | 실제 SMP (원/MWh) |
| smp_error | 모형 - 실제 |
| marginal_fuel | SMP 결정 연료 |
| curtailment | 출력제한량 (MW) |
| 클러스터별 발전량 | (MW) |

Pre-ED는 Price Adder로 보정된 유효비용을 사용하여 pmin, ramp 제약을 포함합니다. 실제 SMP와의 차이(MAE)가 Basic ED 대비 크게 감소합니다.

---

### 2.4 `scenario_summary.csv` (48행)

4개 시나리오의 일별 요약 (12일 x 4시나리오).

| 컬럼 | 설명 |
|------|------|
| scenario | Case_A_zero / Case_B_floor / Case_C_mixed / Case_D_conservative |
| mean_smp_pre | Pre-ED 평균 SMP |
| mean_smp_post | Post-ED 평균 SMP |
| mean_delta_smp | SMP 변화량 (Post - Pre) |
| hours_down / hours_up | SMP 하락/상승 시간 수 |
| curtailment_mwh / hours / max_mw | 출력제한 지표 |

**시나리오 정의:**
- **Case A (zero)**: 모든 RE 블록 입찰가 = 0 원/MWh
- **Case B (floor)**: 모든 블록 = -β × REC × 1000
- **Case C (mixed)**: Low=floor, Mid=0.5×floor, High=0
- **Case D (conservative)**: Low=0.5×floor, Mid=0.25×floor, High=0

---

### 2.5 `scenario_hourly.csv` (1,152행)

시간별 시나리오 결과 (12일 x 24h x 4시나리오).

| 컬럼 | 설명 |
|------|------|
| smp_pre | Pre-ED SMP |
| smp_post | Post-ED SMP |
| delta_smp | SMP 변화량 |
| curtailment | 출력제한량 (MW) |

---

### 2.6 `curtailment_analysis.csv` (48행)

Pre-ED vs Post-ED 출력제한 비교.

| 컬럼 | 설명 |
|------|------|
| pre_curtailment_mwh | Pre-ED 출력제한량 |
| post_curtailment_mwh | Post-ED 출력제한량 |
| reduction_mwh | 감소량 (개선) |

---

### 2.7 `monte_carlo_result.csv` (288행)

100회 랜덤 입찰가 시뮬레이션 결과.

| 컬럼 | 설명 |
|------|------|
| mean_smp | 100회 평균 SMP |
| p5_smp | 5th percentile SMP |
| p95_smp | 95th percentile SMP |
| smp_pre | Pre-ED 기준선 SMP |
| mean_curtailment | 평균 출력제한량 |

각 샘플에서 RE 블록별 입찰가를 [BidFloor, 0] 균등분포로 랜덤 생성하여 Post-ED를 풀고, 통계량을 집계합니다.

---

### 2.8 `sensitivity_beta.csv` (36행)

β(입찰하한 배수) 민감도 분석 (12일 x 3개 β값).

| 컬럼 | 설명 |
|------|------|
| beta | 1.5, 2.0, 2.5 |
| mean_delta_smp | 평균 SMP 변화량 |
| curtailment_mwh | 출력제한량 |
| mean_smp_post | Post-ED 평균 SMP |

β가 클수록 RE 입찰 하한이 더 낮아져(음의 가격) SMP 하락 효과가 강해집니다.

---

### 2.9 `sensitivity_rho.csv` (48행)

ρ(RE 입찰 참여율) 민감도 분석 (12일 x 4개 ρ값).

| 컬럼 | 설명 |
|------|------|
| rho | 0.1, 0.2, 0.3, 0.5 |
| mean_delta_smp | 평균 SMP 변화량 |
| curtailment_mwh | 출력제한량 |
| mean_smp_post | Post-ED 평균 SMP |

ρ가 클수록 더 많은 RE가 입찰에 참여하여 공급곡선에 영향을 미칩니다.

---

## 3. 실행 환경

| 항목 | 값 |
|------|---|
| Julia | 1.11+ |
| 솔버 | HiGHS (LP) |
| 클러스터 | 8개 (CHP 제거, VOM=0) |
| 대표일 | 12일 (자동 선정) |
| Piecewise 세그먼트 | 4 |
| Monte Carlo 샘플 | 100 |
| Calibration max_iter | 15 |
| Target MAE | 3,000 원/MWh |

---

## 4. 데이터 정합성 확인

| 검증 항목 | 결과 |
|----------|------|
| SMP/Demand 8,784행 로딩 | 정상 |
| 재생에너지 8,784행 병합 | 정상 |
| 8개 클러스터 로딩 (CHP 제거) | 정상 |
| 월별 연료단가 60행 (5연료 x 12월) | 정상 |
| 원전 정비 18건 반영 | 정상 (월별 2~6기 정비) |
| 12일 대표일 선정 | 정상 (4계절 x 3일) |
| 총 Pmax 114,941 MW > 피크 97,115 MW | 예비율 18.4% |
| LP 솔버 최적해 | 12일 전체 OPTIMAL |
