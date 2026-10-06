# K6/M16/OW24 PaYN combinational inner tile, matched to ROC_flow's GF22
# INT8_MAC_COMB 1 ns / polar-proton / theta=80 degree reference campaign.
TARGET              := PAYN_INNER_TILE_COMB
CONFIG              := polar_proton_theta80_uniform_1m
DESIGN              := payn_inner_tile_comb
N_TRIALS            := 1000000
SPECTRUM_ANGLE_CDFS := spectrum/spectrum_fits/polar_*deg_proton_cdf.dat
STRIKE_THETA_DEG    := 80
INPUT_DIST          := uniform

CLOCK_PERIOD_NS := 1.0
LAYOUT_XMIN := 10.092
LAYOUT_XMAX := 29.000
LAYOUT_YMIN := 10.000
LAYOUT_YMAX := 27.840

MAX_DELAY := 1000
SETUP_TIME := 12
HOLD_TIME := -6

include config.mk
