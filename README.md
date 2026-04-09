# 전력시스템 경제 프로젝트
## 재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석

### 실행 방법

```bash
cd project/
julia setup.jl                    # 최초 1회: 패키지 설치
julia --project=. src/run_all.jl  # 전체 파이프라인 실행 (Basic→Pre→Post→시나리오)
julia --project=. src/run_basic.jl # Basic ED만 단독 실행
```

### 폴더 구조

```
project/
├── Project.toml              # Julia 패키지 의존성
├── setup.jl                  # 최초 설치 스크립트
├── data/
│   ├── raw/                  # 원시 CSV 데이터 (여기에 파일을 넣으세요)
│   └── processed/            # 전처리된 데이터
├── src/
│   ├── types.jl              # 핵심 자료형 (ThermalCluster, EDInput, EDResult 등)
│   ├── load_data.jl          # CSV 데이터 로딩 (자동 컬럼명 인식)
│   ├── preprocess.jl         # 전처리, 대표일 12일 선정, 유효비용 생성
│   ├── dummy_data.jl         # 더미 데이터 생성 (실제 데이터 전까지 사용)
│   ├── build_basic_ed.jl     # Basic ED (수식 B1~B4)
│   ├── build_pre_ed.jl       # Pre-revision ED (수식 P1~P5, pmin/ramp/must-run)
│   ├── build_post_ed.jl      # Post-revision ED (수식 R1~R4, 4블록 입찰)
│   ├── calibrate.jl          # Price Adder 반복추정, MAE/RMSE/duration curve
│   ├── scenarios.jl          # 4개 시나리오 + β/ρ 민감도 분석
│   ├── run_basic.jl          # Basic ED 단독 실행
│   └── run_all.jl            # 전체 파이프라인 통합 실행
├── outputs/                  # 결과 CSV 파일
└── figures/                  # 그래프/시각화
```

### 실행 파이프라인 (run_all.jl)

| Phase | 내용 | 출력 파일 |
|-------|------|-----------|
| 0 | 데이터 준비 (더미 or 실제 CSV) | - |
| 1 | Basic ED (교과서형 기준선) | basic_result.csv |
| 2 | Calibration (Price Adder 반복추정) | calibration_history.csv |
| 3 | Pre-revision ED (현행 SMP 재현) | pre_result.csv |
| 4 | Post-revision ED (4개 시나리오) | scenario_summary.csv, scenario_hourly.csv |
| 5 | 민감도 분석 (β, ρ) | sensitivity_beta.csv, sensitivity_rho.csv |

### 데이터 연결 방법

data/raw/ 폴더에 CSV를 넣으면 load_data.jl이 파일명 패턴으로 자동 인식합니다:

| 데이터 | 파일명 키워드 | 출처 |
|--------|---------------|------|
| SMP/수요 | smp, 가격, 수요 | data.go.kr [R7] |
| 재생발전량 | solar, wind, 태양광, 풍력 | data.go.kr [R12] |
| 발전설비 | 설비, generator | data.go.kr [R11] |
| 연료비용 | 연료비, fuel | data.go.kr [R9] |
| SMP 결정횟수 | 결정횟수, marginal | data.go.kr [R8] |

### 필요 환경

- Julia 1.10+
- JuMP, HiGHS, CSV, DataFrames (setup.jl로 자동 설치)
