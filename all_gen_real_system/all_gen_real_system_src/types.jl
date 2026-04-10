# ============================================================
# types.jl  ─  프로젝트 핵심 자료형 정의 (개별 발전기 버전)
# ============================================================
# 전력시스템 경제 프로젝트: 재생에너지 입찰제 도입에 따른 SMP 변화 분석
# 기존 클러스터 기반에서 개별 발전기 122기 기반으로 전환
#
# 주요 변경사항:
# - ThermalCluster → ThermalGenerator (개별 발전기)
# - heat_rate, vom 필드 제거 (한국 CBP 시장: gencost에 열소비율 내포)
# - marginal_cost는 gencost의 중점 MC로 직접 계산
# ============================================================

"""
    ThermalGenerator

개별 열발전기 자료형 (122기).
- Basic ED: name, fuel, pmax, marginal_cost 만 사용
- Pre ED: pmin, ramp_up, ramp_down, must_run, price_adder 추가 사용

한국 CBP 시장 특성:
- 열소비율(Heat Rate)은 gencost 2차 비용함수에 내포
- 변동운영비(VOM)는 별도 정산 → 발전비용에 미포함
- marginal_cost = (2a·P_mid + b) × 1000 원/MWh (gencost에서 직접 계산)
"""
struct ThermalGenerator
    name::String            # 발전기 이름 (예: "LNG_001", "Coal_015")
    fuel::String            # 연료원 ("LNG", "Coal", "Nuclear")
    pmin::Float64           # 최소출력 [MW]
    pmax::Float64           # 최대출력 [MW]
    ramp_up::Float64        # 상향 램프 한계 [MW/h]
    ramp_down::Float64      # 하향 램프 한계 [MW/h]
    must_run::Bool          # must-run 여부 (Nuclear = true)
    marginal_cost::Float64  # 중점 한계비용 [원/MWh] (Basic ED용)
end

# 기존 코드 호환을 위한 type alias
const ThermalCluster = ThermalGenerator

"""
    adjust_generator_capacity(g::ThermalGenerator; pmin, pmax) -> ThermalGenerator

immutable ThermalGenerator의 pmin/pmax만 조정한 새 인스턴스를 반환.
Nuclear must-off 등으로 가용 용량이 변할 때 사용.
"""
function adjust_generator_capacity(g::ThermalGenerator;
                                   pmin::Float64=g.pmin,
                                   pmax::Float64=g.pmax)
    return ThermalGenerator(g.name, g.fuel, pmin, pmax, g.ramp_up, g.ramp_down,
                            g.must_run, g.marginal_cost)
end


"""
    ThermalUnitSpec

개별 발전호기의 물리적 사양 (Price Adder 물리적 검증용).
genthermal 데이터에서 추출.
"""
struct ThermalUnitSpec
    name::String            # 발전기 이름 (ThermalGenerator.name과 매핑)
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

발전기 1기의 구간별 선형 근사 비용 정보.
"""
struct PiecewiseCost
    cluster_idx::Int                        # 발전기 인덱스
    pmin::Float64                           # 최소출력 [MW]
    segments::Vector{PiecewiseCostSegment}  # S개 구간
end

"""
    RenewableBidBlock

재생에너지 입찰 블록 자료형 (Post-revision ED에서 사용).
- avail: 시간대별 공급가능량 상한 [MW] (길이 = T) — physical availability
- bid:   시간대별 입찰가격 [원/MWh]   (길이 = T)
- installed_mw: 이 블록이 점유하는 설비용량 [MW]
                (§5: Pmin = min(α·installed_mw, avail_t))
                0.0 이면 fallback (avail × α) 적용
"""
struct RenewableBidBlock
    name::String            # 블록 이름 (예: "PV_low", "W_high")
    tech::String            # 기술 유형 ("solar" 또는 "wind")
    avail::Vector{Float64}  # 시간대별 공급가능량 [MW]
    bid::Vector{Float64}    # 시간대별 입찰가격 [원/MWh]
    installed_mw::Float64   # 블록 점유 설비용량 [MW]  (§5)
end

# 하위호환: 기존 4-인자 생성자 (installed_mw 미지정 → 0.0 → fallback 사용)
RenewableBidBlock(name::String, tech::String,
                  avail::Vector{Float64}, bid::Vector{Float64}) =
    RenewableBidBlock(name, tech, avail, bid, 0.0)

# ============================================================
# Bidder Type — §2.3 (Heterogeneity 도입)
# ============================================================
"""
    BidderType

재생에너지 입찰사업자 유형 (§2.3 — Bidder Types mixture).

- name      : "aggressive" / "moderate" / "conservative" / "PPA_locked"
- share     : φ_j (해당 유형이 차지하는 비율; ∑φ_j=1)
- beta_dist : §6 Beta(α,β) 의 (α,β) — 입찰가 분포 형상.
- w_blocks  : (low, mid, high) 블록 가중 (§2.3 표). 결정론 고정값.
"""
struct BidderType
    name::String
    share::Float64                       # φ_j
    beta_dist::Tuple{Float64,Float64}    # (α,β) for Beta — §6
    w_blocks::NTuple{3,Float64}          # (low, mid, high) — §2.3
end

"""
    EDInput

Economic Dispatch 입력 데이터 통합 구조체.
"""
struct EDInput
    T::Int                              # 시간 수 (보통 24)
    demand::Vector{Float64}             # 시간대별 수요 [MW]
    re_generation::Vector{Float64}      # 시간대별 외생 재생발전량 [MW]
    clusters::Vector{ThermalGenerator}  # 열발전기 목록 (호환을 위해 clusters 이름 유지)
end

"""
    EDResult

Economic Dispatch 결과 구조체.
"""
struct EDResult
    T::Int                              # 시간 수
    generation::Matrix{Float64}         # 발전기별 시간대별 발전량 [MW] (G × T)
    smp::Vector{Float64}                # 시간대별 SMP [원/MWh]
    total_cost::Float64                 # 총 발전비용 [원]
    cluster_names::Vector{String}       # 발전기 이름 목록
    status::Symbol                      # 최적화 상태 (:OPTIMAL 등)
    curtailment::Vector{Float64}        # 시간대별 RE 출력제한량 [MW]
end

"""
    PostEDResult

Post-revision ED 결과 구조체 (재생 입찰블록 낙찰량 포함).
"""
struct PostEDResult
    base::EDResult
    re_dispatch::Matrix{Float64}        # 입찰블록별 시간대별 낙찰량 [MW]
    re_block_names::Vector{String}
    curtailment::Vector{Float64}
end

"""
    CurtailmentAnalysis

출력제한 분석 결과 구조체.
"""
struct CurtailmentAnalysis
    total_mwh::Float64
    hours::Int
    max_mw::Float64
    by_hour::Vector{Float64}
    smp_correlation::Float64
end

"""
    MonteCarloResult

몬테카를로 시뮬레이션 결과 구조체.
"""
struct MonteCarloResult
    n_samples::Int
    mean_smp::Vector{Float64}
    p5_smp::Vector{Float64}
    p95_smp::Vector{Float64}
    mean_delta_smp::Float64
    all_smp::Matrix{Float64}
    mean_curtailment::Vector{Float64}
end
