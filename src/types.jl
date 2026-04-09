# ============================================================
# types.jl  ─  프로젝트 핵심 자료형 정의
# ============================================================
# 전력시스템 경제 프로젝트: 재생에너지 입찰제 도입에 따른 SMP 변화 분석
# Basic ED / Pre-revision ED / Post-revision ED 공용 자료형
# ============================================================

"""
    ThermalCluster

열발전 클러스터 자료형.
- Basic ED: name, fuel, pmax, marginal_cost 만 사용
- Pre ED: pmin, ramp_up, ramp_down, heat_rate, vom, must_run, price_adder 추가 사용
"""
struct ThermalCluster
    name::String            # 클러스터 이름 (예: "Nuclear_base")
    fuel::String            # 연료원 (예: "nuclear", "coal", "lng", "oil", "chp", "hydro")
    pmin::Float64           # 최소출력 [MW]
    pmax::Float64           # 최대출력 [MW]
    ramp_up::Float64        # 상향 램프 한계 [MW/h]
    ramp_down::Float64      # 하향 램프 한계 [MW/h]
    heat_rate::Float64      # 열소비율 [Gcal/MWh] (연료비→발전비 변환)
    vom::Float64            # 변동운영비 [원/MWh]
    must_run::Bool          # must-run 여부
    marginal_cost::Float64  # 단순 한계비용 [원/MWh] (Basic ED용)
end

"""
    adjust_cluster_capacity(c::ThermalCluster; pmin, pmax) -> ThermalCluster

immutable ThermalCluster의 pmin/pmax만 조정한 새 인스턴스를 반환.
Nuclear must-off 등으로 가용 용량이 변할 때 사용.
"""
function adjust_cluster_capacity(c::ThermalCluster;
                                  pmin::Float64=c.pmin,
                                  pmax::Float64=c.pmax)
    return ThermalCluster(c.name, c.fuel, pmin, pmax, c.ramp_up, c.ramp_down,
                          c.heat_rate, c.vom, c.must_run, c.marginal_cost)
end

"""
    ThermalUnitSpec

개별 발전호기의 물리적 사양 (Price Adder 물리적 검증용).
MATPOWER genthermal 데이터에서 추출.
"""
struct ThermalUnitSpec
    name::String            # 클러스터 이름 (ThermalCluster.name과 매핑)
    startup_cost::Float64   # 고온기동비 [천원] → 검증 시 원 단위로 변환
    min_up_time::Float64    # 최소가동시간 [시간]
    pmax_unit::Float64      # 호기별 최대출력 [MW]
end

"""
    PiecewiseCostSegment

구간별 선형 근사의 단일 구간.
2차 비용함수 C(P) = a*P² + b*P + c를 S개 구간으로 분할.
"""
struct PiecewiseCostSegment
    delta_max::Float64      # 구간 폭 [MW]
    marginal_cost::Float64  # 이 구간의 한계비용 [원/MWh]
end

"""
    PiecewiseCost

클러스터 1개의 구간별 선형 근사 비용 정보.
"""
struct PiecewiseCost
    cluster_idx::Int                        # 클러스터 인덱스
    pmin::Float64                           # 최소출력 [MW]
    segments::Vector{PiecewiseCostSegment}  # S개 구간
end

"""
    RenewableBidBlock

재생에너지 입찰 블록 자료형 (Post-revision ED에서 사용).
- avail: 시간대별 공급가능량 상한 [MW] (길이 = T)
- bid:   시간대별 입찰가격 [원/MWh]   (길이 = T)
"""
struct RenewableBidBlock
    name::String            # 블록 이름 (예: "PV_low", "W_high")
    tech::String            # 기술 유형 ("solar" 또는 "wind")
    avail::Vector{Float64}  # 시간대별 공급가능량 [MW]
    bid::Vector{Float64}    # 시간대별 입찰가격 [원/MWh]
end

"""
    EDInput

Economic Dispatch 입력 데이터 통합 구조체.
모든 ED 모델(Basic/Pre/Post)이 공용으로 사용.
"""
struct EDInput
    T::Int                              # 시간 수 (보통 24)
    demand::Vector{Float64}             # 시간대별 수요 [MW]
    re_generation::Vector{Float64}      # 시간대별 외생 재생발전량 [MW] (Basic/Pre: 전체, Post: nonbid분)
    clusters::Vector{ThermalCluster}    # 열발전 클러스터 목록
end

"""
    EDResult

Economic Dispatch 결과 구조체.
"""
struct EDResult
    T::Int                              # 시간 수
    generation::Matrix{Float64}         # 클러스터별 시간대별 발전량 [MW] (G × T)
    smp::Vector{Float64}                # 시간대별 SMP [원/MWh] (dual value)
    total_cost::Float64                 # 총 발전비용 [원]
    cluster_names::Vector{String}       # 클러스터 이름 목록
    status::Symbol                      # 최적화 상태 (:OPTIMAL 등)
    curtailment::Vector{Float64}        # 시간대별 RE 출력제한량 [MW]
end

"""
    PostEDResult

Post-revision ED 결과 구조체 (재생 입찰블록 낙찰량 포함).
"""
struct PostEDResult
    base::EDResult                      # 기본 ED 결과
    re_dispatch::Matrix{Float64}        # 입찰블록별 시간대별 낙찰량 [MW] (K × T)
    re_block_names::Vector{String}      # 입찰블록 이름 목록
    curtailment::Vector{Float64}        # 시간대별 비입찰 RE 출력제한량 [MW]
end

"""
    CurtailmentAnalysis

출력제한 분석 결과 구조체.
"""
struct CurtailmentAnalysis
    total_mwh::Float64                  # 총 출력제한량 [MWh]
    hours::Int                          # 출력제한 발생 시간 수
    max_mw::Float64                     # 최대 시간당 출력제한량 [MW]
    by_hour::Vector{Float64}            # 시간대별 출력제한량 [MW]
    smp_correlation::Float64            # SMP와의 상관계수 (Pearson)
end

"""
    MonteCarloResult

몬테카를로 시뮬레이션 결과 구조체.
"""
struct MonteCarloResult
    n_samples::Int                      # 총 샘플 수
    mean_smp::Vector{Float64}           # 평균 SMP 프로파일 [원/MWh]
    p5_smp::Vector{Float64}             # 5th percentile SMP
    p95_smp::Vector{Float64}            # 95th percentile SMP
    mean_delta_smp::Float64             # 평균 ΔSMP (vs Pre)
    all_smp::Matrix{Float64}            # 전체 SMP [n_samples × T]
    mean_curtailment::Vector{Float64}   # 평균 출력제한 프로파일 [MW]
end
