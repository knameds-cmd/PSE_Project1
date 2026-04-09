# ============================================================
# dummy_data.jl  ─  한국 육지계통 더미 데이터 생성
# ============================================================
# 실제 데이터 확보 전까지 Basic ED 구조 검증용으로 사용.
# 값은 한국 육지계통의 대략적 규모와 패턴을 반영한 합성 데이터.
# 실제 데이터 확보 후 load_data.jl로 교체 예정.
# ============================================================

# types.jl은 run_basic.jl에서 먼저 include됨 (중복 include 방지)

"""
    make_dummy_demand(T=24) -> Vector{Float64}

한국 육지계통의 하루 수요 패턴을 모사한 더미 데이터 [MW].
- 최저: ~36,000 MW (새벽 4시)
- 최대: ~52,000 MW (저녁 피크)
- 패턴: 봄철 경부하일 기준 (RE 침투 효과가 두드러지는 날)
- must_run(22GW) + 고RE 시 초과공급 → 시나리오별 SMP 차이 유발
"""
function make_dummy_demand(T::Int=24)
    # 시간대: 1=00시, 2=01시, ..., 24=23시
    base = 48000.0  # 기저 부하 [MW] (봄철 경부하일)

    # 시간대별 부하 패턴 (비율)
    pattern = [
        0.82, 0.78, 0.76, 0.75, 0.76, 0.80,  # 00-05시: 야간 저부하
        0.85, 0.92, 0.98, 1.02, 1.05, 1.06,  # 06-11시: 오전 증가
        1.04, 1.06, 1.08, 1.07, 1.05, 1.04,  # 12-17시: 오후 피크
        1.06, 1.08, 1.05, 1.00, 0.94, 0.88   # 18-23시: 저녁→야간
    ]

    demand = base .* pattern[1:T]
    return demand
end

"""
    make_dummy_renewable(T=24) -> Vector{Float64}

한국 육지의 태양광+풍력 합산 발전량 더미 데이터 [MW].
- 태양광: 낮 시간대 집중 (최대 ~30,000 MW, 2024 설비용량 반영)
- 풍력:   상대적으로 균일 (평균 ~3,000 MW)
- 낮 시간대: must_run(22GW) + RE > demand → 초과공급 발생
"""
function make_dummy_renewable(T::Int=24)
    # 태양광 패턴 (일출~일몰, 정오 최대, 2024 설비 반영)
    solar = [
        0, 0, 0, 0, 0, 200,              # 00-05시
        1500, 6000, 14000, 22000, 28000, 30000,  # 06-11시
        30000, 29000, 25000, 18000, 10000, 3000,  # 12-17시
        300, 0, 0, 0, 0, 0                # 18-23시
    ]

    # 풍력 패턴 (야간 약간 높음, 1.5x 증가)
    wind = [
        3750, 3900, 4050, 4200, 4050, 3750,   # 00-05시
        3300, 3000, 2700, 2550, 2400, 2250,   # 06-11시
        2100, 2250, 2400, 2700, 3000, 3300,   # 12-17시
        3600, 3900, 4200, 4350, 4200, 4050    # 18-23시
    ]

    re_total = Float64.(solar[1:T] .+ wind[1:T])
    return re_total
end

"""
    make_dummy_clusters() -> Vector{ThermalCluster}

한국 육지계통의 9개 열발전 클러스터 더미 데이터.
클러스터링 기준: 문서 2.3절의 권장안
- 비용 순서: Nuclear < Coal_low < Coal_high < LNG_CC_low < LNG_CC_mid < CHP < LNG_GT_peak < Oil_peak < Hydro
- 용량 합계: ~100 GW (한국 육지 설비용량 규모)
"""
function make_dummy_clusters()
    clusters = ThermalCluster[
        # name              fuel       pmin    pmax    ramp_up ramp_dn heat_rate vom  must_run  mc(원/MWh)
        ThermalCluster(
            "Nuclear_base",  "nuclear",
            18000.0, 24000.0,   # 원전: 높은 최소출력, pmin ≈ 75% of pmax
            600.0, 600.0,       # 느린 램프
            2.4, 500.0,         # 낮은 열소비율
            true,               # must-run
            55000.0             # ~55 원/kWh → 55,000 원/MWh
        ),
        ThermalCluster(
            "Coal_lowcost",  "coal",
            6000.0, 16000.0,    # 저비용 석탄
            2000.0, 2000.0,
            2.1, 2000.0,
            false,
            75000.0             # ~75 원/kWh
        ),
        ThermalCluster(
            "Coal_highcost", "coal",
            3000.0, 10000.0,    # 고비용 석탄
            1500.0, 1500.0,
            2.3, 2500.0,
            false,
            90000.0             # ~90 원/kWh
        ),
        ThermalCluster(
            "LNG_CC_low",   "lng",
            2000.0, 12000.0,    # LNG 복합 저비용
            4000.0, 4000.0,     # 빠른 램프
            1.7, 3000.0,
            false,
            110000.0            # ~110 원/kWh
        ),
        ThermalCluster(
            "LNG_CC_mid",   "lng",
            1500.0, 10000.0,    # LNG 복합 중간
            3500.0, 3500.0,
            1.8, 3500.0,
            false,
            130000.0            # ~130 원/kWh
        ),
        ThermalCluster(
            "CHP_mustrun",  "chp",
            4000.0, 6000.0,     # 집단에너지/열병합: 높은 최소출력 비율
            1000.0, 1000.0,
            2.0, 2000.0,
            true,               # must-run (열 공급 의무)
            95000.0             # ~95 원/kWh
        ),
        ThermalCluster(
            "LNG_GT_peak",  "lng",
            0.0, 5000.0,        # 첨두용 GT: 최소출력 없음
            5000.0, 5000.0,     # 매우 빠른 램프
            2.5, 5000.0,
            false,
            180000.0            # ~180 원/kWh
        ),
        ThermalCluster(
            "Oil_peak",     "oil",
            0.0, 2000.0,        # 유류 첨두
            2000.0, 2000.0,
            3.0, 8000.0,
            false,
            250000.0            # ~250 원/kWh
        ),
        ThermalCluster(
            "Hydro_fixed",  "hydro",
            0.0, 4000.0,        # 수력/양수
            4000.0, 4000.0,
            0.0, 500.0,
            false,
            60000.0             # ~60 원/kWh (기회비용 반영)
        ),
    ]
    return clusters
end

"""
    make_dummy_input(T=24) -> EDInput

Basic ED용 더미 입력 데이터 생성.
"""
function make_dummy_input(T::Int=24)
    demand = make_dummy_demand(T)
    re_gen = make_dummy_renewable(T)
    clusters = make_dummy_clusters()
    return EDInput(T, demand, re_gen, clusters)
end

"""
    make_dummy_actual_smp(T=24) -> Vector{Float64}

검증 비교용 더미 actual SMP [원/MWh].
봄철 경부하일 + 고RE 침투율을 반영한 패턴.
- 새벽: ~80,000 원/MWh (석탄 한계)
- 낮:   ~55,000~65,000 원/MWh (높은 RE → SMP 급락)
- 저녁: ~130,000~145,000 원/MWh (RE 감소 → LNG 한계)
"""
function make_dummy_actual_smp(T::Int=24)
    smp = [
        80000, 78000, 76000, 75000, 76000, 80000,   # 00-05시
        82000, 85000, 75000, 65000, 58000, 55000,   # 06-11시 (태양광 급증 → SMP 하방)
        55000, 58000, 65000, 80000, 100000, 125000,  # 12-17시 (오후: RE 감소 → SMP 상승)
        145000, 140000, 130000, 115000, 100000, 88000 # 18-23시 (저녁 피크 후 감소)
    ]
    return Float64.(smp[1:T])
end

# ============================================================
# 추가 더미 데이터: ThermalUnitSpec (Price Adder 물리적 검증용)
# ============================================================
"""
    make_dummy_unit_specs() -> Vector{ThermalUnitSpec}

클러스터별 기동비/최소가동시간/호기용량 더미 데이터.
MATPOWER genthermal 데이터 형식을 참조하여 생성.
"""
function make_dummy_unit_specs()
    return ThermalUnitSpec[
        # name               startup_cost(천원) min_up_time(h) pmax_unit(MW)
        ThermalUnitSpec("Nuclear_base",   0.0,       72.0,  1000.0),  # 원전: 기동비 사실상 없음, 장기 가동
        ThermalUnitSpec("Coal_lowcost",   120000.0,   8.0,   500.0),  # 저비용 석탄
        ThermalUnitSpec("Coal_highcost",  100000.0,   6.0,   500.0),  # 고비용 석탄
        ThermalUnitSpec("LNG_CC_low",      47398.56,  4.0,   880.0),  # LNG CC (MATPOWER 참조)
        ThermalUnitSpec("LNG_CC_mid",      52138.42,  4.0,   700.0),  # LNG CC 중간
        ThermalUnitSpec("CHP_mustrun",     30000.0,   6.0,   200.0),  # 열병합
        ThermalUnitSpec("LNG_GT_peak",     10000.0,   1.0,   150.0),  # GT 첨두
        ThermalUnitSpec("Oil_peak",        15000.0,   1.0,   200.0),  # 유류 첨두
        ThermalUnitSpec("Hydro_fixed",         0.0,   1.0,   500.0),  # 수력
    ]
end

# ============================================================
# 추가 더미 데이터: Nuclear Must-Off (원전 계획정비)
# ============================================================
"""
    make_dummy_nuclear_must_off() -> DataFrame

원전 계획정비 더미 데이터.
총 24호기 중 분석 대상일(봄철)에 3호기가 정비 중인 시나리오.
"""
function make_dummy_nuclear_must_off()
    # id: 호기 번호, off_start_day/off_end_day: 연중 일 (1~365)
    return DataFrame(
        id            = [67, 68, 71],
        off_start_day  = [  1,  37, 100],
        off_start_time = [  1,   1,   1],
        off_end_day    = [341,  88, 160],
        off_end_time   = [ 24,  24,  24],
    )
end

# ============================================================
# 추가 더미 데이터: MATPOWER gencost (2차 비용함수 계수)
# ============================================================
"""
    make_dummy_gencost() -> Dict{String, Tuple{Float64,Float64,Float64}}

클러스터별 2차 비용함수 계수 더미 데이터.
C(P) = a·P² + b·P + c [원/h], P는 MW.
MC(P) = 2a·P + b [원/MWh].

한국 전력시장 비용구조를 참고하여 설정.
"""
function make_dummy_gencost()
    return Dict{String, Tuple{Float64,Float64,Float64}}(
        # (a, b, c) — C(P) = a*P² + b*P + c
        "Nuclear_base"  => (0.000500,  12000.0,  50000.0),   # 매우 완만한 2차 비용
        "Coal_lowcost"  => (0.002000,  63000.0,  80000.0),   # 석탄 저비용
        "Coal_highcost" => (0.003000,  72000.0,  70000.0),   # 석탄 고비용
        "LNG_CC_low"    => (0.004601,  50243.0,   5213.0),   # MATPOWER 참조값
        "LNG_CC_mid"    => (0.005500,  96500.0,   6000.0),   # LNG CC 중간
        "CHP_mustrun"   => (0.003500,  80000.0,  40000.0),   # 열병합
        "LNG_GT_peak"   => (0.010000, 150000.0,   3000.0),   # GT 첨두 (급경사)
        "Oil_peak"      => (0.008000, 210000.0,   5000.0),   # 유류 첨두
        "Hydro_fixed"   => (0.000000,  60000.0,      0.0),   # 수력 (선형)
    )
end
