#!/usr/bin/env bash
# scripts/integrate_susfs.sh
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
cd "${WORKSPACE}/kernel_workspace"

# ========================================================================
# KERNEL ROOT RESOLUTION
# ========================================================================
KERNEL_ROOT=""

for candidate in \
    "${WORKSPACE}/kernel_workspace/common" \
    "${WORKSPACE}/kernel_workspace/common/aosp" \
    "${WORKSPACE}/kernel_workspace/common/common"
do
    if [ -f "${candidate}/Makefile" ] && grep -q "VERSION =" "${candidate}/Makefile"; then
        KERNEL_ROOT="${candidate}"
        break
    fi
done

if [ -z "$KERNEL_ROOT" ]; then
    FOUND_MAKEFILE=$(find "${WORKSPACE}/kernel_workspace" -maxdepth 5 -type f -name "Makefile" -exec grep -l "VERSION =" {} + | head -n 1 || true)
    if [ -n "$FOUND_MAKEFILE" ]; then
        KERNEL_ROOT=$(dirname "$FOUND_MAKEFILE")
    fi
fi

if [ -z "$KERNEL_ROOT" ] || [ ! -f "${KERNEL_ROOT}/Makefile" ]; then
    echo "[-] Error: Could not locate kernel Makefile in kernel_workspace" >&2
    exit 1
fi

echo ">>> Detected kernel source root at: ${KERNEL_ROOT}"

echo ">>> Cloning susfs4ksu..."

# 1. Attempt to clone the primary target
if ! git clone --depth=1 -b "${SUSFS_NEXT_REF}" "${SUSFS_NEXT_URL}" susfs4ksu; then
    echo "[-] Branch '${SUSFS_NEXT_REF}' not found. Attempting fallback..."
    
    # 2. Strip the '-dev' suffix from the string
    FALLBACK_REF="${SUSFS_NEXT_REF%-dev}"
    
    # 3. Ensure we aren't retrying the exact same string
    if [ "${SUSFS_NEXT_REF}" = "${FALLBACK_REF}" ]; then
        echo "[-] Error: Clone failed and no '-dev' suffix to fallback from. Exiting." >&2
        exit 1
    fi

    echo ">>> Trying fallback branch: '${FALLBACK_REF}'..."
    
    # 4. Clone fallback
    git clone --depth=1 -b "${FALLBACK_REF}" "${SUSFS_NEXT_URL}" susfs4ksu || {
        echo "[-] Error: Fallback branch '${FALLBACK_REF}' also failed. Exiting." >&2
        exit 1
    }
fi

COMMON_PATCH_SRC="$(find susfs4ksu/kernel_patches -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' | head -n1)"
[ -n "${COMMON_PATCH_SRC}" ] || { echo "[-] Could not find 50_add_susfs_in_*.patch" >&2; exit 1; }

echo ">>> Copying SUSFS files into ${KERNEL_ROOT}..."
mkdir -p "${KERNEL_ROOT}/fs" "${KERNEL_ROOT}/include/linux"

cp -f "${COMMON_PATCH_SRC}" "${KERNEL_ROOT}/"
cp -rf susfs4ksu/kernel_patches/fs/* "${KERNEL_ROOT}/fs/"
cp -rf susfs4ksu/kernel_patches/include/linux/* "${KERNEL_ROOT}/include/linux/"

echo ">>> Applying common kernel SUSFS patch..."
(cd "${KERNEL_ROOT}" && patch -p1 --no-backup-if-mismatch < "$(basename "${COMMON_PATCH_SRC}")") || true

echo ">>> SUSFS common-side integration complete!"
