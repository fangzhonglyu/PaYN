# PaYN — standalone design repo consuming the ASTRAEA flow.
#
# Designs, target files, and build artifacts live here. The synth/APR/sim/power
# logic, Tcl scripts, and PDK setups come from the flow repo (ASTRAEA).
#
# Override ASTRAEA_FLOW if the flow lives elsewhere:
#   make synth TARGET=TSMC22/BP_ARRAY ASTRAEA_FLOW=/path/to/ASTRAEA

ASTRAEA_FLOW ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../ASTRAEA)

ifeq ($(wildcard $(ASTRAEA_FLOW)/Makefile),)
$(error ASTRAEA_FLOW=$(ASTRAEA_FLOW) is not a flow repo (no Makefile). \
        Clone ASTRAEA next to PaYN, or pass ASTRAEA_FLOW=<path>)
endif

include $(ASTRAEA_FLOW)/Makefile
