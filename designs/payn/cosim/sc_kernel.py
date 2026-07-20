"""Numpy reference model for PaYN's SC array arithmetic (bit-exact).

Mirrors the RTL at the arithmetic level:
  - Sobol RNG bank (M lanes, distinct XOR seeds) -> payn/sobol.sv (sobol_bank)
  - Owen scramble mask (golden-stride offsets)   -> payn/pe_peripheral.sv
  - Comparator: bit[d,m] = mag[d] > (thr[m] ^ owen(d,m,salt))
  - 2-bit encode + popcount + per-cycle bias     -> payn/inner_tile.sv (InnerTile)
  - Output-stationary accumulator (signed)       -> payn/inner_tile.sv (InnerTile)

Scmp alignment (2025 update):
  - Input-side Sobol uses identity DVs (matches scmp's Q seed [1,1,1,...,1]).
  - Weight-side Sobol uses the DVs from scmp's K seed [1,1,1,1,9,1,41,255],
    yielding DV = [128,64,32,16,72,4,82,255]. The (input, weight) Sobol pair
    then has SCC ~ 0, which is the necessary + sufficient condition for an
    unbiased SC dot-product estimator.
  - No C-BSG feedback -- scmp does not use it. The Sobol DV pair alone
    achieves the decorrelation that C-BSG would enforce dynamically.

  payn_array.sv wires the weight bank with DIRECTION_SET=1 (the K DV table) and
  the input bank with DIRECTION_SET=0 (identity), so the RTL <-> numpy match is
  bit-exact -- verified end-to-end by designs/payn/cosim/cosim_array.py. Set
  cfg.DV_W = DV_Q_WIDTH8 to model the biased identity-DV-on-both-banks variant.

Does NOT model per-cycle systolic pipeline delays. For P_ROWS = P_COLS = 1 the
inner_pe's in_bits_pipe / w_bits_pipe delays are both a single flop, so the T
'productive' compute cycles at the inner tile consume Sobol thr[0..T-1] in
order. The RTL TB is sequenced to match that assumption exactly.

Entry point: matmul(A, B, cfg) computes a full GEMM by tiling onto a single-PE
array (P_ROWS = P_COLS = 1) with inner grid N_H x N_W and inner-tile K x M.
Returns the drained int16 accumulator matrix.
"""
from __future__ import annotations

import numpy as np
from dataclasses import dataclass


# =============================================================================
# Sobol RNG (bit-exact port of sobol.sv)
# =============================================================================

# scmp_kernels' Sobol direction-vector tables (from make_sobol_simple_config
# and rng.py::Sobol._default_seed for length=8). Q-side keeps identity DVs; K-side
# uses the seed vector [1,1,1,1,9,1,41,255] which yields these DVs:
#   V[i] = seed[i] / 2^(i+1) * 2^WIDTH  =>  [128, 64, 32, 16, 72, 4, 82, 255].
# scmp searched for this K seed empirically; it gives SCC ~ 0 vs the Q seed.
DV_Q_WIDTH8 = [128, 64, 32, 16, 8, 4, 2, 1]      # identity (Q side, scmp default)
DV_K_WIDTH8 = [128, 64, 32, 16, 72, 4, 82, 255]  # scmp K side, decorrelated vs Q


class SobolRNG:
    """Parameterized Sobol. Port of designs/payn/sobol.sv (module sobol_generator) with a DV table.

    `dv[j]` replaces sobol.sv's hardcoded ``1 << (WIDTH-1-j)``. Default is the
    identity DV table (matches current RTL behavior). Pass a scmp K-seed table
    (or any valid Sobol DV set) for a decorrelated parallel Sobol trajectory.
    """

    def __init__(self, width: int, seed: int, dv: list | None = None):
        self.width = width
        self.mask = (1 << width) - 1
        self.seed = seed & self.mask
        # Identity DVs are the current RTL default: [1<<(WIDTH-1), ..., 1].
        self.dv = list(dv) if dv is not None else [1 << (width - 1 - j) for j in range(width)]
        assert len(self.dv) == width, f"DV table must be length {width}"
        self.reset()

    def reset(self) -> None:
        self.cnt = 0
        self.seq = self.seed

    def step(self) -> int:
        """One clocked update. Returns the new sobolSeq value.

        Mirrors sobol.sv: the inacc/outoh chain finds the LSB zero of cnt.
        When cnt has NO zero (all-ones, right before wrap), no direction
        vector is selected (selected_dv == 0) and seq is unchanged.
        """
        c = self.cnt
        j = 0
        while j < self.width and ((c >> j) & 1):
            j += 1
        if j < self.width:
            self.seq = (self.seq ^ self.dv[j]) & self.mask
        # else: cnt was all-ones, selected_dv=0, seq unchanged.
        self.cnt = (self.cnt + 1) & self.mask
        return self.seq


class RNGBank:
    """M parallel Sobol RNGs. Port of designs/payn/sobol.sv (module sobol_bank)."""

    def __init__(self, width: int, M: int, seed_base: int, seed_stride: int,
                 dv: list | None = None):
        self.width = width
        self.M = M
        mask = (1 << width) - 1
        self.rngs = [
            SobolRNG(width, seed_base ^ ((seed_stride * m) & mask), dv=dv)
            for m in range(M)
        ]

    def reset(self) -> None:
        for r in self.rngs:
            r.reset()

    def step(self) -> np.ndarray:
        return np.array([r.step() for r in self.rngs], dtype=np.int32)


# =============================================================================
# cmp_lane arithmetic (bit-exact port of cmp_lane.sv)
# =============================================================================

def owen_mask(d: int, m: int, salt: int, width: int) -> int:
    """Bit-exact port of the cmp_lane.sv Owen scramble mask."""
    LEVELS = 1 << width
    GOLDEN_K = ((LEVELS * 79) // 128) | 1
    GOLDEN_M = ((LEVELS * 49) // 128) | 1
    return (d * GOLDEN_K + m * GOLDEN_M + salt) & (LEVELS - 1)


def cmp_lane_bits(mag_K: np.ndarray, thr_M: np.ndarray,
                  K: int, M: int, WIDTH: int, salt: int,
                  owen_enable: bool = True) -> np.ndarray:
    """(K,) magnitudes vs (M,) thresholds -> (K, M) comparator bits."""
    out = np.zeros((K, M), dtype=np.uint8)
    for d in range(K):
        for m in range(M):
            mask = owen_mask(d, m, salt, WIDTH) if owen_enable else 0
            thr = int(thr_M[m]) ^ mask
            out[d, m] = 1 if int(mag_K[d]) > thr else 0
    return out


def edge_operand_bits(mag_NK: np.ndarray, thr_M: np.ndarray,
                      K: int, M: int, WIDTH: int, salt: int,
                      owen_enable: bool = True) -> np.ndarray:
    """N rows of cmp_lane. mag_NK: (N, K) -> bits (N, K, M)."""
    N = mag_NK.shape[0]
    out = np.zeros((N, K, M), dtype=np.uint8)
    for n in range(N):
        out[n] = cmp_lane_bits(mag_NK[n], thr_M, K, M, WIDTH, salt, owen_enable)
    return out


# =============================================================================
# inner_tile_2bit contribution (bit-exact port, DEFER_BIAS=0 branch)
# =============================================================================

def inner_tile_2bit_contribution(in_bits_KM: np.ndarray, w_bits_KM: np.ndarray,
                                 in_signs_K: np.ndarray, w_signs_K: np.ndarray,
                                 K: int, M: int) -> int:
    """Per-cycle contribution to the output-stationary accumulator.

    Bit-exact port of inner_tile_2bit.sv (DEFER_BIAS=0):
      neg_lane[d]  = in_signs[d] ^ w_signs[d]
      and_out[d,m] = in_bits[d,m] & w_bits[d,m]
      enc_hi[d,m]  = and_out[d,m] & ~neg_lane[d]
      enc_lo[d,m]  = ~and_out[d,m]
      sum_encoded  = 2*popcount(enc_hi) + popcount(enc_lo)
      contribution = sum_encoded - K*M     (signed)
    """
    neg_lane = (in_signs_K ^ w_signs_K).astype(np.uint8)     # (K,)
    and_out = (in_bits_KM & w_bits_KM).astype(np.uint8)       # (K, M)
    enc_hi = and_out & (1 - neg_lane[:, None])                # (K, M)
    enc_lo = 1 - and_out                                       # (K, M)
    pop_hi = int(enc_hi.sum())
    pop_lo = int(enc_lo.sum())
    sum_encoded = 2 * pop_hi + pop_lo
    return sum_encoded - K * M


# =============================================================================
# inner_tile_2bit_apc contribution (bit-exact port of inner_tile_2bit_apc.sv)
# =============================================================================

def inner_tile_2bit_apc_contribution(in_bits_KM: np.ndarray, w_bits_KM: np.ndarray,
                                     in_signs_K: np.ndarray, w_signs_K: np.ndarray,
                                     K: int, M: int, au_flip: int) -> int:
    """Per-cycle APC contribution. Mirrors inner_tile_2bit_apc.sv exactly.

    Uses the same enc_hi / enc_lo as the exact path, then applies an AU layer
    of 2-input gates that halves K*M -> K*M/2. Pair (d, 2m)-(d, 2m+1) at index
    PIDX = d*(M/2) + m: base label = PIDX%2 (0=AND, 1=OR), rotated per cycle
    by XOR with au_flip. Halved popcounts, weight-2 reinterpretation:
      sum_encoded_apc = 4*popcount(au_hi) + 2*popcount(au_lo)
      contribution    = sum_encoded_apc - K*M
    """
    assert M % 2 == 0, "M must be even (pair across m)"
    neg_lane = (in_signs_K ^ w_signs_K).astype(np.uint8)
    and_out = (in_bits_KM & w_bits_KM).astype(np.uint8)
    enc_hi = (and_out & (1 - neg_lane[:, None])).astype(np.uint8)
    enc_lo = (1 - and_out).astype(np.uint8)
    # Vectorized: reshape to (K, M/2, 2) and pair across the last axis.
    hi = enc_hi.reshape(K, M // 2, 2)
    lo = enc_lo.reshape(K, M // 2, 2)
    # Base labels tile (K, M/2): PIDX = d*(M/2) + m; base_isor = PIDX % 2.
    pidx = (np.arange(K)[:, None] * (M // 2) + np.arange(M // 2)[None, :])
    use_or = ((pidx & 1) ^ (au_flip & 1)).astype(bool)
    and_hi = hi[..., 0] & hi[..., 1]
    or_hi  = hi[..., 0] | hi[..., 1]
    and_lo = lo[..., 0] & lo[..., 1]
    or_lo  = lo[..., 0] | lo[..., 1]
    au_hi = np.where(use_or, or_hi, and_hi)
    au_lo = np.where(use_or, or_lo, and_lo)
    sum_encoded_apc = 4 * int(au_hi.sum()) + 2 * int(au_lo.sum())
    return sum_encoded_apc - K * M


# =============================================================================
# Single-PE array simulator (P_ROWS = P_COLS = 1 corner PE)
# =============================================================================

@dataclass
class ArrayCfg:
    K: int = 4
    M: int = 4
    N_H: int = 2
    N_W: int = 2
    WIDTH: int = 8
    OWIDTH: int = 16
    T: int = 32                # stoc_len per K-tile
    ENCODING: int = 1          # 1 = 2-bit offset (inner_tile_2bit, DEFER_BIAS=0)
    SEED_BASE_IN: int = 0x17
    SEED_STRIDE_IN: int = 0x53
    SEED_BASE_W: int = 0x9D
    SEED_STRIDE_W: int = 0x2B
    # Direction-vector tables. Input side keeps identity DVs (matches scmp's Q
    # seed). Weight side uses scmp's K-seed DVs -> the (input, weight) Sobol pair
    # has SCC ~ 0, so the SC estimator is unbiased. Setting DV_W = None reverts
    # to the biased identity-DV design (RMSE floor ~ q_max^2*D at any T).
    DV_IN: list | None = None                # None -> identity (Q side)
    DV_W:  list | None = None                # None -> DV_K_WIDTH8 selected in _make_rng_w below

    def make_rng_in(self) -> "RNGBank":
        dv = self.DV_IN if self.DV_IN is not None else DV_Q_WIDTH8
        return RNGBank(self.WIDTH, self.M, self.SEED_BASE_IN, self.SEED_STRIDE_IN, dv=dv)

    def make_rng_w(self) -> "RNGBank":
        dv = self.DV_W if self.DV_W is not None else DV_K_WIDTH8
        return RNGBank(self.WIDTH, self.M, self.SEED_BASE_W, self.SEED_STRIDE_W, dv=dv)


def _sign_extend(v: int, width: int) -> int:
    hi = 1 << (width - 1)
    return v - (1 << width) if (v & hi) else v


def compute_k_tile(ifm_mag: np.ndarray, ifm_sign: np.ndarray,
                   wght_mag: np.ndarray, wght_sign: np.ndarray,
                   cfg: ArrayCfg,
                   rng_in: RNGBank, rng_w: RNGBank,
                   au_flip_state: list | None = None) -> np.ndarray:
    """Contribution of one K-tile to acc[N_H, N_W].

    Args:
        ifm_mag:  (N_H, K)  input magnitudes (uint, WIDTH bits)
        ifm_sign: (N_H, K)  input signs (0 = +, 1 = -)
        wght_mag: (N_W, K)  weight magnitudes
        wght_sign:(N_W, K)  weight signs
        rng_in/w: RNG banks; caller resets or persists them across tiles as
                  needed to match the RTL's rng_bank state.
        au_flip_state: single-element list holding the au_flip bit for ENCODING=3.
            Caller passes a list so we can update it in-place across K-tiles
            (the T-flip-flop in inner_tile_2bit_apc.sv persists across K-blocks
            in the same spatial tile; it only resets when the whole array is
            reset between spatial tiles). Ignored for ENCODING != 3.

    Returns:
        contribution (N_H, N_W) int64
    """
    K, M, N_H, N_W, WIDTH, T = cfg.K, cfg.M, cfg.N_H, cfg.N_W, cfg.WIDTH, cfg.T
    salt_west = 0
    salt_south = 1 << (WIDTH - 1)

    contrib = np.zeros((N_H, N_W), dtype=np.int64)
    for t in range(T):
        thr_in = rng_in.step()
        thr_w = rng_w.step()

        in_bits = edge_operand_bits(ifm_mag, thr_in, K, M, WIDTH, salt_west)
        w_bits = edge_operand_bits(wght_mag, thr_w, K, M, WIDTH, salt_south)

        for h in range(N_H):
            for v in range(N_W):
                if cfg.ENCODING == 3:
                    assert au_flip_state is not None
                    contrib[h, v] += inner_tile_2bit_apc_contribution(
                        in_bits[h], w_bits[v],
                        ifm_sign[h].astype(np.uint8),
                        wght_sign[v].astype(np.uint8),
                        K, M, au_flip_state[0],
                    )
                    continue
                contrib[h, v] += inner_tile_2bit_contribution(
                    in_bits[h], w_bits[v],
                    ifm_sign[h].astype(np.uint8),
                    wght_sign[v].astype(np.uint8),
                    K, M,
                )
        # T-flip-flop toggle: matches inner_tile_2bit_apc.sv, which flips au_flip
        # on the same posedge that updates acc. The old au_flip was used for
        # this cycle's contribution above; toggle now so the next iteration
        # sees the flipped value.
        if cfg.ENCODING == 3 and au_flip_state is not None:
            au_flip_state[0] ^= 1
    return contrib


def compute_spatial_tile(A_tile: np.ndarray, sA_tile: np.ndarray,
                         B_tile: np.ndarray, sB_tile: np.ndarray,
                         cfg: ArrayCfg) -> np.ndarray:
    """One spatial output tile: N_H rows of A vs N_W rows of B, K_g inner.

    Args:
        A_tile:  (N_H, K_g)  input magnitudes
        sA_tile: (N_H, K_g)  input signs
        B_tile:  (N_W, K_g)  weight magnitudes
        sB_tile: (N_W, K_g)  weight signs

    Returns:
        acc (N_H, N_W) int64 — full drain output for one spatial tile.
    """
    K = cfg.K
    K_g = A_tile.shape[1]
    assert K_g % K == 0, f"K_g={K_g} must be divisible by K={K}"
    n_k_blocks = K_g // K

    # RTL resets its RNG on the array reset. We instantiate one RNG bank per
    # spatial tile (matches TB sequence: reset arr, then run all K-blocks of
    # this spatial tile, drain, then reset for next spatial tile). Bank DVs
    # come from the cfg factories -- identity on input side (Q), scmp K-seed on
    # weight side by default -- so the input/weight Sobol pair has SCC ~ 0.
    rng_in = cfg.make_rng_in()
    rng_w  = cfg.make_rng_w()
    # ENCODING=3 (APC) has a per-inner-tile T-flip-flop for the AU rotation.
    # It resets on the array reset (start of a spatial tile) and persists
    # across K-blocks within the same spatial tile.
    au_flip_state = [0]

    acc = np.zeros((cfg.N_H, cfg.N_W), dtype=np.int64)
    for k in range(n_k_blocks):
        # Match RTL TB timing: between K-blocks the array's bit-pipe fill takes 2
        # extra Sobol advances (load posedge + fill posedge) before the first
        # accumulate. The K=0 case has the same 2-cycle fill (post-reset in_bits
        # is zero -> contribution zero -> harmless), but Sobol still advances 2x
        # before the first productive thr[0]. For K-block 0 the productive thrs
        # are Sobol steps 1..T (0-indexed), so we don't skip. For K-block >= 1,
        # advance RNG twice to consume the fill-cycle thrs.
        if k > 0:
            rng_in.step(); rng_in.step()
            rng_w.step();  rng_w.step()
        ifm_mag = A_tile[:, k*K:(k+1)*K]
        ifm_sign = sA_tile[:, k*K:(k+1)*K]
        wght_mag = B_tile[:, k*K:(k+1)*K]
        wght_sign = sB_tile[:, k*K:(k+1)*K]
        acc += compute_k_tile(
            ifm_mag, ifm_sign, wght_mag, wght_sign, cfg, rng_in, rng_w,
            au_flip_state=au_flip_state,
        )

    # Truncate to OWIDTH signed (matches RTL's signed OWIDTH accumulator).
    mask = (1 << cfg.OWIDTH) - 1
    for h in range(cfg.N_H):
        for v in range(cfg.N_W):
            acc[h, v] = _sign_extend(int(acc[h, v]) & mask, cfg.OWIDTH)
    return acc


def matmul(A: np.ndarray, sA: np.ndarray,
           B: np.ndarray, sB: np.ndarray,
           cfg: ArrayCfg) -> np.ndarray:
    """Full GEMM y = A @ B.T in the SC domain, mapped onto the single-PE array.

    Args:
        A:  (M_g, K_g) input magnitudes, WIDTH bits unsigned
        sA: (M_g, K_g) input signs
        B:  (N_g, K_g) weight magnitudes
        sB: (N_g, K_g) weight signs

    Returns:
        y (M_g, N_g) int64 — SC-domain accumulator values (unscaled),
        equal to what the RTL drain rail produces for the same operands.
    """
    M_g, K_g = A.shape
    N_g, K_gB = B.shape
    assert K_g == K_gB, "A and B must share the inner dimension"
    assert M_g % cfg.N_H == 0, f"M_g={M_g} must be divisible by N_H={cfg.N_H}"
    assert N_g % cfg.N_W == 0, f"N_g={N_g} must be divisible by N_W={cfg.N_W}"
    assert K_g % cfg.K == 0, f"K_g={K_g} must be divisible by K={cfg.K}"

    n_rt = M_g // cfg.N_H
    n_ct = N_g // cfg.N_W
    y = np.zeros((M_g, N_g), dtype=np.int64)
    for rt in range(n_rt):
        for ct in range(n_ct):
            A_tile = A[rt*cfg.N_H:(rt+1)*cfg.N_H]
            sA_tile = sA[rt*cfg.N_H:(rt+1)*cfg.N_H]
            B_tile = B[ct*cfg.N_W:(ct+1)*cfg.N_W]
            sB_tile = sB[ct*cfg.N_W:(ct+1)*cfg.N_W]
            acc = compute_spatial_tile(A_tile, sA_tile, B_tile, sB_tile, cfg)
            y[rt*cfg.N_H:(rt+1)*cfg.N_H,
              ct*cfg.N_W:(ct+1)*cfg.N_W] = acc
    return y


# =============================================================================
# Self-test
# =============================================================================

if __name__ == "__main__":
    cfg = ArrayCfg()
    print("=== sc_kernel self-test ===")
    print(f"cfg: K={cfg.K} M={cfg.M} N_H={cfg.N_H} N_W={cfg.N_W} "
          f"WIDTH={cfg.WIDTH} T={cfg.T}")

    # Sobol reproduction check: first 16 outputs of lane 0.
    rng = SobolRNG(cfg.WIDTH, 0x17)
    seq = [rng.step() for _ in range(16)]
    print(f"Sobol lane 0 first 16: {seq}")

    # Sanity: (2, 8) x (2, 8) GEMM -> (2, 2) output.
    rs = np.random.RandomState(0)
    q_max = (1 << (cfg.WIDTH - 1)) - 1
    A_signed = rs.randint(-q_max, q_max + 1, size=(2, 8)).astype(np.int32)
    B_signed = rs.randint(-q_max, q_max + 1, size=(2, 8)).astype(np.int32)

    A = np.abs(A_signed).astype(np.uint32)
    sA = (A_signed < 0).astype(np.uint8)
    B = np.abs(B_signed).astype(np.uint32)
    sB = (B_signed < 0).astype(np.uint8)

    y_sc = matmul(A, sA, B, sB, cfg)
    y_fp = A_signed @ B_signed.T

    scale = (q_max * q_max) / cfg.T
    y_sc_scaled = y_sc.astype(np.float64) * scale / cfg.M
    print(f"y_sc (raw)    =\n{y_sc}")
    print(f"y_sc (scaled) =\n{y_sc_scaled}")
    print(f"y_fp          =\n{y_fp}")
    print(f"max |err|     = {np.max(np.abs(y_sc_scaled - y_fp)):.1f}")
