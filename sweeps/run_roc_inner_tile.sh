#!/usr/bin/env bash
# Export a clean PaYN GF22 APR run into a PaYN-local ROC_flow workspace, then
# run one ROC pipeline stage (default: all).  ROC_flow itself remains unmodified.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROC_ROOT="${ROC_FLOW:-$REPO/../ROC_flow}"
APR_RUN="${APR_RUN:-roc_k6m16_20260722_cov}"
ROC_STAGE="${1:-all}"
ROC_TRIALS="${ROC_TRIALS:-100000}"
ROC_ANGLE="${ROC_ANGLE:-theta80}"
TOP=payn_inner_tile_comb

case "$ROC_ANGLE:$ROC_TRIALS" in
    theta80:100000)
        ROC_CONFIG=payn_inner_tile_theta80_uniform_100k
        ROC_BUILD=polar_proton_theta80_uniform_100k
        ;;
    theta80:1000000)
        ROC_CONFIG=payn_inner_tile_theta80_uniform_1m
        ROC_BUILD=polar_proton_theta80_uniform_1m
        ;;
    omni:10000000)
        ROC_CONFIG=payn_inner_tile_omni_uniform_10m
        ROC_BUILD=polar_proton_omni_uniform_10m
        ;;
    *)
        echo "ERROR: supported ROC_ANGLE:ROC_TRIALS pairs are" >&2
        echo "       theta80:100000, theta80:1000000, omni:10000000" >&2
        exit 1
        ;;
esac

APR_OUT="$REPO/apr/build/GF22FDX/PAYN_INNER_TILE_COMB/$APR_RUN/outputs"
DESIGN_DIR="$REPO/build/roc_flow/design/PAYN_INNER_TILE_COMB"
BUILD_DIR="$REPO/build/roc_flow/PAYN_INNER_TILE_COMB/$ROC_BUILD"
CONFIG_FILE="$REPO/roc_flow/configs/$ROC_CONFIG.mk"

for suffix in apr.v apr.sdf lef spef; do
    if [ ! -f "$APR_OUT/$TOP.$suffix" ]; then
        echo "ERROR: missing APR artifact: $APR_OUT/$TOP.$suffix" >&2
        exit 1
    fi
done

mkdir -p "$DESIGN_DIR" "$BUILD_DIR"
for suffix in apr.v apr.sdf lef spef apr.def apr.physical.v gds; do
    if [ -f "$APR_OUT/$TOP.$suffix" ]; then
        cp -f "$APR_OUT/$TOP.$suffix" "$DESIGN_DIR/$TOP.$suffix"
    fi
done

source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 \
            synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 \
            vcs/2020.12-SP2-1 \
            innovus/21.14.000 \
            genus/21.14.000

make -C "$ROC_ROOT" "$ROC_STAGE" \
    CONFIG_FILE="$CONFIG_FILE" \
    DESIGN_DIR="$DESIGN_DIR" \
    BUILD_DIR="$BUILD_DIR"
