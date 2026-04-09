# DATA_SPECIFICATION_real_system.md

## 개별 발전기 122기 기반 실데이터 명세서

### 개요

본 프로젝트는 한국 육지계통의 **개별 발전기 122기** 데이터를 사용하여 Economic Dispatch를 수행한다.
기존 9개 클러스터 방식과 달리, MATPOWER 케이스 파일(KPG193_ver1_5)의 모든 발전기를 개별적으로 모델링한다.

**핵심 차이**: 클러스터링 없이 개별 발전기의 비용함수(gencost), 물리적 제약(genthermal)을 그대로 사용.

### 한국 CBP 시장 구조

- **열소비율(Heat Rate)**: gencost의 2차 비용함수 C(P) = aP^2 + bP + c 에 내포
- **변동운영비(VOM)**: 별도 정산 (발전비용에 미포함)
- **SMP 결정**: 급전순위에 따른 한계비용 기반
- **단위**: gencost 계수는 천원(1000원) 단위 → MC 계산 시 x1000 하여 원/MWh로 변환

---

## 1. generators.csv — 개별 발전기 데이터 (122기)

**출처**: KPG193_ver1_5.m (mpc.gen + mpc.genthermal + mpc.gencost)
**행수**: 122
**전처리**: parse_matpower.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| name | String | - | 발전기 식별자 (LNG_001~056, Coal_001~041, Nuclear_001~025) |
| fuel | String | - | 연료원 (LNG, Coal, Nuclear) |
| pmin | Float | MW | 최소출력 (mpc.gen 10번째 열) |
| pmax | Float | MW | 최대출력 (mpc.gen 9번째 열) |
| ramp_up | Float | MW/h | 상향 램프율 (mpc.genthermal 6번째 열) |
| ramp_down | Float | MW/h | 하향 램프율 (mpc.genthermal 7번째 열) |
| marginal_cost | Float | 원/MWh | 중점 한계비용 = (2a*(Pmin+Pmax)/2 + b) * 1000 |

**발전기 구성**:
- LNG: 56기, 총용량 약 40,000 MW
- Coal: 41기, 총용량 약 30,000 MW
- Nuclear: 25기, 총용량 약 24,000 MW

**명명 규칙**: `{연료}_{순번:03d}` — .m 파일 내 등장 순서대로 연료별 순번 부여

**must_run**: Julia 코드에서 fuel == "Nuclear" 인 경우 true로 설정 (CSV에는 미포함)

---

## 2. gencost.csv — 2차 비용함수 계수

**출처**: KPG193_ver1_5.m (mpc.gencost)
**행수**: 122
**전처리**: parse_matpower.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| name | String | - | 발전기 식별자 |
| a | Float | 천원/(MW^2*h) | 2차 계수 (c2) |
| b | Float | 천원/MWh | 1차 계수 (c1) |
| c | Float | 천원/h | 상수항 (c0) |
| startup_cost | Float | 천원 | 기동비용 |

**비용함수**: C(P) = a*P^2 + b*P + c (천원/h)
**한계비용**: MC(P) = dC/dP = (2aP + b) * 1000 (원/MWh)

**범위 예시**:
- LNG: a=0.002~0.007, b=47~70, MC ≈ 50,000~80,000 원/MWh
- Coal: a=0.025~0.031, b=22~27, MC ≈ 40,000~60,000 원/MWh
- Nuclear: a=0.002~0.003, b=3~8, MC ≈ 8,000~17,000 원/MWh

---

## 3. genthermal.csv — 열적 제약 데이터

**출처**: KPG193_ver1_5.m (mpc.genthermal)
**행수**: 122
**전처리**: parse_matpower.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| name | String | - | 발전기 식별자 |
| type_thermal | Int | - | 열적 유형 (3=보일러/터빈) |
| UT | Int | h | 최소가동시간 (LNG:4, Coal:6, Nuclear:8) |
| DT | Int | h | 최소정지시간 (LNG:3, Coal:12, Nuclear:12) |
| inistate | Int | h | 초기상태 (+24=가동중, -24=정지중) |
| initialpower | Float | MW | 초기출력 |
| ramp_up | Float | MW/h | 상향 램프 |
| ramp_down | Float | MW/h | 하향 램프 |
| startup_limit | Float | MW | 기동 한계 |
| shutdown_limit | Float | MW | 정지 한계 |
| startup1~3 | Float | 천원 | 기동비용 (고온/온간/냉간) |
| startupdelay1~3 | Int | h | 기동지연시간 |

---

## 4. smp_demand.csv — SMP 및 전력수요 시계열

**출처**: HOME_전력거래_계통한계가격_시간별SMP.csv + 한국전력거래소_시간별 전국 전력수요량_20241231.csv
**행수**: 8,784 (366일 x 24시간, 2024년)
**전처리**: preprocess_smp_demand.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| date | String | YYYY-MM-DD | 날짜 |
| hour | Int | 1~24 | 거래시간 (끝점 표시, hour=1은 00:00~01:00) |
| smp_mainland | Float | 원/MWh | 육지계통 SMP |
| demand_mainland | Float | MW | 전국 전력수요 |

**단위 변환**: 원본 SMP는 원/kWh → x1000 → 원/MWh
**범위**: SMP 0~230,820 원/MWh, 수요 39,258~97,115 MW

---

## 5. renewables_generation_mwh.csv — 재생에너지 발전량

**출처**: 재생에너지_발전량_2024.csv
**행수**: 8,784
**전처리**: preprocess_renewables.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| date | String | YYYY-MM-DD | 날짜 |
| hour | Int | 1~24 | 거래시간 |
| solar_mainland | Float | MW | 태양광 발전량 합계 |
| wind_mainland | Float | MW | 풍력(육지) 발전량 |

**범위**: 태양광 0~6,255 MW, 풍력 0~1,266 MW

---

## 6. renewables_capacity_mw.csv — 재생에너지 설비용량

**출처**: HOME_발전설비_신재생_발전기현황.csv
**전처리**: preprocess_renewables_capacity.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| energy_type | String | - | 에너지원 (solar, wind) |
| total_capacity_mw | Float | MW | 총 설비용량 |
| count | Int | - | 발전기 수 |

**총 설비용량**: 태양광 31,857 MW (181,426기), 풍력 2,471 MW (154기)

---

## 7. fuel_costs.csv — 월별 연료비용

**출처**: HOME_전력거래_연료비용.csv (발전별비용 섹션)
**행수**: 380 (76개월 x 5연료, 2020~2026)
**전처리**: preprocess_fuel_costs.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| year_month | String | YYYY-MM | 연월 |
| fuel | String | - | 연료 (nuclear, coal, anthracite, oil, lng) |
| fuel_cost_won_per_gcal | Float | 원/Gcal | 발전용 열량단가 |

**2024년 평균 (원/Gcal)**:
- nuclear: 2,578
- coal: 34,260
- anthracite: 32,655
- oil: 139,934
- lng: 80,898

---

## 8. nuclear_must_off.csv — 원전 계획예방정비

**출처**: 한국수력원자력(주)_원전 호기별 계획예방정비 현황.csv
**행수**: 18 (2024년 정비 건)
**전처리**: preprocess_nuclear_mustoff.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| id | Int | - | 정비 건 ID |
| unit_name | String | - | 원전 호기명 (고리4호기, 신고리1호기 등) |
| off_start_date | String | YYYY-MM-DD | 정비 시작일 |
| off_end_date | String | YYYY-MM-DD | 정비 종료일 |
| off_start_day | Int | 1~366 | 시작 일수 (연중) |
| off_end_day | Int | 1~366 | 종료 일수 (연중) |
| duration_days | Int | 일 | 정비 기간 |

**연말~연초 정비**: off_end_day < off_start_day인 경우, 2024년 내 구간만 기록 (off_end_day=366)

---

## 9. marginal_fuel_counts.csv — 연료원별 SMP 결정횟수

**출처**: HOME_전력거래_계통한계가격_연료원별SMP결정.csv
**행수**: 12 (2024년 월별)
**전처리**: preprocess_marginal_fuel.py

| 컬럼 | 타입 | 단위 | 설명 |
|------|------|------|------|
| date | String | YYYY-MM | 연월 |
| LNG | Int | 시간 | LNG가 SMP 결정한 시간 수 |
| 유류 | Int | 시간 | 유류 결정 시간 수 |
| anthracite | Int | 시간 | 무연탄 결정 시간 수 |
| bituminous | Int | 시간 | 유연탄 결정 시간 수 |
| nuclear | Int | 시간 | 원자력 결정 시간 수 |
| total_hours | Int | 시간 | 월 총 시간 |

**2024년 패턴**: LNG 지배적 (575~741시간/월), 겨울에 유연탄 비율 증가 (110~136시간/월)

---

## 데이터 인코딩 주의사항

- **원본 CSV (EPSIS/KPX)**: CP949 (한국어 인코딩)
- **processed CSV**: UTF-8 (Python 전처리 후 변환)
- **MATPOWER .m 파일**: UTF-8/ASCII

---

## 전처리 코드 목록

| 스크립트 | 입력 | 출력 |
|----------|------|------|
| parse_matpower.py | KPG193_ver1_5.m | generators.csv, gencost.csv, genthermal.csv |
| preprocess_smp_demand.py | 시간별SMP.csv + 수요량.csv | smp_demand.csv |
| preprocess_renewables.py | 재생에너지_발전량_2024.csv | renewables_generation_mwh.csv |
| preprocess_renewables_capacity.py | HOME_발전설비_신재생.csv | renewables_capacity_mw.csv |
| preprocess_fuel_costs.py | HOME_전력거래_연료비용.csv | fuel_costs.csv |
| preprocess_nuclear_mustoff.py | 원전정비현황.csv | nuclear_must_off.csv |
| preprocess_marginal_fuel.py | 연료원별SMP결정.csv | marginal_fuel_counts.csv |
| run_all_preprocessing.py | (통합 실행) | 전체 CSV |

전체 전처리 실행: `python run_all_preprocessing.py`
