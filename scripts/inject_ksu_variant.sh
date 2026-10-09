#!/usr/bin/env bash
# scripts/inject_ksu_variant.sh
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
cd "${WORKSPACE}/kernel_workspace"

VARIANT=$1
# Export these so the sourced scripts can use them natively
export KSU_VARIANT_REF=$(echo "${KSU_VARIANT_REF:-}" | xargs)
export USE_DYNAMIC_TRANSPLANT=$(echo "${USE_DYNAMIC_TRANSPLANT:-false}" | tr '[:upper:]' '[:lower:]')

# 1. Map the expected directory name based on the variant's internal setup.sh hardcoding
case "${VARIANT}" in
    "KernelSU-Next")
        export MANAGER_DIR="KernelSU-Next"
        ;;
    "SukiSU-Ultra" | "ReSukiSU" | "KernelSU" | "BakaSU")
        export MANAGER_DIR="KernelSU"
        ;;
    *)
        echo "[-] Error: Unsupported Variant '${VARIANT}'. Selected variant not supported" >&2
        exit 1
        ;;
esac

rm -rf "${MANAGER_DIR}"
echo "=== Integrating ${VARIANT} ==="

# ========================================================================
# MODULAR DELEGATION
# ========================================================================
INJECTOR_SCRIPT="../scripts/inject_${VARIANT}.sh"

if [ -f "$INJECTOR_SCRIPT" ]; then
    echo ">>> Delegating integration to modular script: $INJECTOR_SCRIPT"
    
    # We use 'source' so the child script runs in THIS environment.
    source "$INJECTOR_SCRIPT"
    
    # Reset active working directory back to kernel_workspace
    cd "${WORKSPACE}/kernel_workspace"
else
    echo "[-] CRITICAL: Modular script $INJECTOR_SCRIPT not found!" >&2
    exit 1
fi

# ========================================================================
# KERNEL ROOT RESOLUTION (MULTI-DEPTH SAFE LOOKUP)
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

# ========================================================================
# KERNEL 6.6/6.12 UPSTREAM COMPATIBILITY FIXES (UNIVERSAL TARGETED WIPER)
# ========================================================================
echo ">>> Normalizing SELinux function declarations across all variants..."
SELINUX_HIDE="${WORKSPACE}/kernel_workspace/${MANAGER_DIR}/kernel/feature/selinux_hide.c"

if [ -f "$SELINUX_HIDE" ]; then
    
    # 1. Determine correct return type for BakaSU's __maybe_void macro
    K_VER=$(grep "^VERSION =" "${KERNEL_ROOT}/Makefile" | tr -d ' ' | cut -d'=' -f2 || echo "0")
    K_PATCH=$(grep "^PATCHLEVEL =" "${KERNEL_ROOT}/Makefile" | tr -d ' ' | cut -d'=' -f2 || echo "0")
    
    if [ "$K_VER" = "6" ] && [ "$K_PATCH" -ge "6" ]; then
        COMPUTE_AV_RET="void"
    else
        COMPUTE_AV_RET="int"
    fi
    
    # 2. Target ONLY the 3 problematic functions and explicitly wipe the junk prefixes
    FUNCS=(
        "security_compute_av_user_with_policy"
        "security_context_to_sid_with_policy"
        "security_sid_to_context_with_policy"
    )

    for FUNC in "${FUNCS[@]}"; do
        # Strip standard prefixes (static or SUSFS_EXPORT) and their trailing spaces
        sed -i -E "/$FUNC/ s/(static|SUSFS_EXPORT)[[:space:]]+//g" "$SELINUX_HIDE"
        
        # Translate BakaSU's custom macros into native C types
        sed -i -E "/$FUNC/ s/__maybe_int/int/g" "$SELINUX_HIDE"
        sed -i -E "/$FUNC/ s/__maybe_void/$COMPUTE_AV_RET/g" "$SELINUX_HIDE"
    done

    echo "  -> Enforced clean, native C declarations for SELinux hooks."
fi

# ========================================================================
# KLEAF SANDBOX IMMUTABLE GATEKEEPER
# ========================================================================
SHORT_HASH=${UPSTREAM_HASH:0:7}
echo "UPSTREAM_HASH=${UPSTREAM_HASH}" >> $GITHUB_ENV

echo ">>> Injecting Sandbox Variables into Kbuild..."
TARGET_KBUILD="${WORKSPACE}/kernel_workspace/${MANAGER_DIR}/kernel/Kbuild"

if [ -f "$TARGET_KBUILD" ]; then
    {
        # --- Official & Next Namespaces ---
        echo "override KSU_GIT_VERSION_VALID := false" 
        echo "override KSU_GIT_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_GIT_TAG := ${CALCULATED_TAG}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}"
        echo "override KSU_GIT_BRANCH := ${UPSTREAM_BRANCH}"
        
        # --- ReSukiSU Namespaces ---
        echo "override LOCAL_GIT_EXISTS := 1"
        echo "override KSU_LOCAL_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_TAG_NAME := ${CALCULATED_TAG}"
        echo "override KSU_BRANCH_NAME := ${UPSTREAM_BRANCH}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}" 

        # --- SukiSU-Ultra Specific Namespaces ---
        echo "override LOCAL_COUNT := ${CALCULATED_COUNT}"
        echo "override git_commit_count := ${CALCULATED_COUNT}"
        echo "override git_short_sha := ${SHORT_HASH}"
        echo "override git_branch := ${UPSTREAM_BRANCH}"
        echo "override git_latest_tag := ${CALCULATED_TAG}"

        cat "$TARGET_KBUILD"
    } > "${TARGET_KBUILD}.tmp" && mv "${TARGET_KBUILD}.tmp" "$TARGET_KBUILD"

    echo "  -> Prepend Immutable Count: ${CALCULATED_COUNT}"
    echo "  -> Prepend Immutable Tag: ${CALCULATED_TAG}"
    echo "  -> Prepend Immutable SHA: ${SHORT_HASH}"
    echo "  -> Prepend Immutable Branch: ${UPSTREAM_BRANCH}"
else
    echo "[-] Warning: $TARGET_KBUILD not found. Sandbox variables not injected."
fi

# ========================================================================
# KERNEL DRIVER SYMLINK
# ========================================================================
echo ">>> Injecting Bazel symlink..."
DRIVER_ROOT="${KERNEL_ROOT}/drivers"
mkdir -p "${DRIVER_ROOT}"
rm -rf "${DRIVER_ROOT}/kernelsu"

TARGET_KSU_DIR="${WORKSPACE}/kernel_workspace/${MANAGER_DIR}/kernel"
REL_PATH=$(python3 -c "import os.path; print(os.path.relpath('${TARGET_KSU_DIR}', '${DRIVER_ROOT}'))")

ln -sfn "${REL_PATH}" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} architecture locked, sanitized and integrated!"
