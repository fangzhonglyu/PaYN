# Coverage-constrained GF22 combinational INT8 MAC, polar-proton
# omnidirectional campaign.  STRIKE_THETA_DEG is intentionally omitted.
TARGET              := BINARY_INT8_MAC_COMB_ROC
CONFIG              := polar_proton_omni_int8_uniform_10m
DESIGN              := binary_int8_mac_comb
N_TRIALS            := 10000000
SPECTRUM_ANGLE_CDFS := spectrum/spectrum_fits/polar_*deg_proton_cdf.dat
INPUT_DIST          := int8_mac_uniform
ML_SIGNED           := 1
ML_ACC_TERMS        := 32

CLOCK_PERIOD_NS := 1.0
LAYOUT_XMIN := 10.092
LAYOUT_XMAX := 23.548
LAYOUT_YMIN := 10.000
LAYOUT_YMAX := 22.480

MAX_DELAY := 1000
SETUP_TIME := 12
HOLD_TIME := -6

include config.mk
