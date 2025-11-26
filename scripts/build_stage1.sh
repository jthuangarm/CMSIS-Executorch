#!/usr/bin/env bash
set -euo pipefail

# Stage 1: Build generic ExecuTorch runtime + full operator libraries.
# Produces static libraries and headers without model-specific pruning.
#
# Usage:
#   scripts/build_stage1.sh /path/to/executorch [/abs/build/dir] [/path/to/toolchain.cmake]
# Example:
#   scripts/build_stage1.sh "$HOME/src/executorch" build/stage1 examples/arm/ethos-u-setup/arm-none-eabi-gcc.cmake
#
# Environment variables:
#   EXECUTORCH_EXTRA_CMAKE_ARGS  Space-separated extra cmake args to append.

EXECUTORCH_SRC=${1:-}
BUILD_DIR=${2:-build/stage1}
TOOLCHAIN_FILE=${3:-}

if [[ -z "${EXECUTORCH_SRC}" ]]; then
  echo "[ERROR] Missing ExecuTorch source path argument." >&2
  exit 1
fi
if [[ ! -d "${EXECUTORCH_SRC}" ]]; then
  echo "[ERROR] ExecuTorch source directory not found: ${EXECUTORCH_SRC}" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo "[Stage1] Configuring generic runtime build..."

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DEXECUTORCH_BUILD_ARM_BAREMETAL=ON      # Enable Ethos-U backend
  -DEXECUTORCH_BUILD_PORTABLE_OPS=ON
  -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON
  -DEXECUTORCH_BUILD_CORTEX_M=ON
  -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF
  -DEXECUTORCH_BUILD_DEVTOOLS=OFF
  -DEXECUTORCH_ENABLE_EVENT_TRACER=OFF
  -DEXECUTORCH_ENABLE_LOGGING=ON
  -DFETCH_ETHOS_U_CONTENT=OFF
  -DEXECUTORCH_SELECT_OPS_MODEL=  # empty => full schema based libs
)

if [[ -n "${TOOLCHAIN_FILE}" ]]; then
  CMAKE_ARGS+=("-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE}")
fi

if [[ -n "${EXECUTORCH_EXTRA_CMAKE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SPLIT=(${EXECUTORCH_EXTRA_CMAKE_ARGS})
  CMAKE_ARGS+=("${EXTRA_SPLIT[@]}")
fi

cmake "${EXECUTORCH_SRC}" "${CMAKE_ARGS[@]}" -B .

echo "[Stage1] Building core & kernel libraries (no install step)..."
cmake --build . -j"$(nproc)" --target executorch_core executorch portable_kernels portable_ops_lib cortex_m_kernels cortex_m_ops_lib quantized_kernels quantized_ops_lib executorch_delegate_ethos_u || {
  echo "[Stage1] ERROR: Build failed" >&2; exit 1; }

ASSETS_DIR="${BUILD_DIR}/assets"
LIB_DIR="${ASSETS_DIR}/lib"
INC_DIR="${ASSETS_DIR}/include"
mkdir -p "${LIB_DIR}" "${INC_DIR}"

echo "[Stage1] Collecting libraries into ${LIB_DIR}"
for LIB in libexecutorch_core.a libexecutorch.a libportable_kernels.a libportable_ops_lib.a \
           libcortex_m_kernels.a libcortex_m_ops_lib.a libquantized_kernels.a libquantized_ops_lib.a \
           libexecutorch_delegate_ethos_u.a; do
  FOUND=$(find . -name "$LIB" | head -n1 || true)
  if [[ -n "$FOUND" ]]; then
    cp "$FOUND" "$LIB_DIR/";
  else
  echo "[Stage1] WARN: $LIB not found";
  fi
done

echo "[Stage1] Collecting headers (executorch runtime + kernels)."
# Primary: use generated build include tree (contains codegen headers)
HDR_ROOT=$(find . -type d -path '*/include/executorch' | head -n1 || true)
if [[ -n "$HDR_ROOT" ]]; then
  echo "[Stage1] Using build header root: $HDR_ROOT"
  rsync -a "$HDR_ROOT/" "$INC_DIR/executorch/"
else
  echo "[Stage1] WARN: Build include/executorch not found."
fi

# Always collect essential source headers for external applications
echo "[Stage1] Collecting essential source headers from ExecuTorch source tree."
ESSENTIAL_HDR_DIRS=(runtime kernels backends extension devtools)
for DIR in "${ESSENTIAL_HDR_DIRS[@]}"; do
  if [[ -d "${EXECUTORCH_SRC}/${DIR}" ]]; then
    echo "[Stage1] Copying source headers from ${DIR}/"
    rsync -a "${EXECUTORCH_SRC}/${DIR}" "$INC_DIR/executorch/"
  else
    echo "[Stage1] WARN: Source directory ${EXECUTORCH_SRC}/${DIR} not found"
  fi
done

# Log header count
HDR_COUNT=$(find "$INC_DIR" -type f -name '*.h' | wc -l | tr -d ' ' || true)
echo "[Stage1] Collected $HDR_COUNT header files."

# Supplement: explicitly gather codegen headers that might live outside include/ tree
echo "[Stage1] Scanning for additional generated headers (Functions.h, NativeFunctions.h, CustomOpsNativeFunctions.h, Register*)."
CODEGEN_PATTERNS=('Functions.h' 'NativeFunctions.h' 'CustomOpsNativeFunctions.h' 'RegisterCodegenUnboxedKernelsEverything.cpp' 'RegisterCPUCustomOps.cpp' 'RegisterSchema.cpp')
for PAT in "${CODEGEN_PATTERNS[@]}"; do
  while IFS= read -r -d '' FILE; do
    RELDIR=$(dirname "$FILE")
    # Normalize into executorch/generated relative bucket
    TARGET_DIR="$INC_DIR/executorch/generated/${RELDIR#.*/stage1/}"
    mkdir -p "$TARGET_DIR"
    # Only copy headers; for cpp we may skip unless explicitly asked
    if [[ "$FILE" == *.h ]]; then
      cp "$FILE" "$TARGET_DIR/"
    fi
  done < <(find . -type f -name "$PAT" -print0 2>/dev/null || true)
done

FINAL_HDR_COUNT=$(find "$INC_DIR" -type f -name '*.h' | wc -l | tr -d ' ' || true)
echo "[Stage1] Final header count: $FINAL_HDR_COUNT"

echo "[Stage1] Asset collection complete at: ${ASSETS_DIR}"
