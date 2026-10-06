# K6/M16/OW24 PaYN combinational inner tile, matched to ROC_flow's GF22
# INT8_MAC_COMB 1 ns / polar-proton / theta=80 degree reference campaign.
TARGET              := PAYN_INNER_TILE_COMB
CONFIG              := polar_proton_theta80_uniform_100k
DESIGN              := payn_inner_tile_comb
N_TRIALS            := 100000
SPECTRUM_ANGLE_CDFS := spectrum/spectrum_fits/polar_*deg_proton_cdf.dat
STRIKE_THETA_DEG    := 80
INPUT_DIST          := uniform

CLOCK_PERIOD_NS := 1.0

# Standard-cell placement core from the clean GF22 APR DEF.  ROC_flow samples
# physical strikes over the core rather than over the 10 um I/O margin.
LAYOUT_XMIN := 10.092
LAYOUT_XMAX := 29.000
LAYOUT_YMIN := 10.000
LAYOUT_YMAX := 27.840

# Gate-level observation window in ps, matched to INT8_MAC_COMB.  Routed PaYN
# setup WNS is +44 ps at this 1 ns constraint.
MAX_DELAY := 1000
SETUP_TIME := 12
HOLD_TIME := -6

include config.mk
