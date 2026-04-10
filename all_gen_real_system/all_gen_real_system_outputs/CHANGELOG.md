# CHANGELOG

Generated: 2026-04-10T22:19:35.401

v2 (개별 발전기 122기 + real-data) — 개선계획서 TASK 1~11
  - 개별 발전기 122기 (클러스터링 없음), MATPOWER KPG193 기반
  - heat_rate/vom 제거: 한국 CBP 시장 — gencost에 열소비율 내포
  - §1  potential 재구성 (가정: 2024 발전량 ≡ potential, max CF<1)
  - §2  BidderType mixture (aggressive/moderate/conservative/PPA_locked)
  - §3  Case_A_zero ≡ ρ=0 baseline (bidding_active=false), ε_nonbid=100
  - §5  RE Pmin = min(α·installed_mw, avail) (installed_mw 누락 시 fallback)
  - §6  Beta(α,β) mixture + common shock 몬테카를로
  - §7  활성 marginal 전체 갱신 + 1/n_marg 정규화
  - §8  Tikhonov L2 shrinkage (λη=0.05/iter)
  - §9  curtailment_free calibration (RE must-take, dual purity)
  - §10 Train/test/buffer split (계절 ±3일 buffer) + 3D adder G×24×S
  - §11 sanity assert: |SMP_post_A − SMP_pre| < 1

