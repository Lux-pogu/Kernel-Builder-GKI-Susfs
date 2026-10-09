#!/usr/bin/env bash
# scripts/configure_kconfigs.sh
set -euo pipefail

ENABLE_NOMOUNT=${ENABLE_NOMOUNT:-false}
ENABLE_NET_OPTS=${ENABLE_NET_OPTS:-false}
BASE_VER=${BASE_VER:-}

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
COMBINED_FRAG="${WORKSPACE}/tools/custom_combined.fragment"
> "$COMBINED_FRAG" # Initialize empty file

echo "=== Configuring Kconfigs & ABI Neutralization for Kernel ${BASE_VER} ==="

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

# Locate directory containing BUILD.bazel (usually KERNEL_ROOT or common)
BAZEL_DIR="${KERNEL_ROOT}"
if [ ! -f "${BAZEL_DIR}/BUILD.bazel" ] && [ -f "${WORKSPACE}/kernel_workspace/common/BUILD.bazel" ]; then
    BAZEL_DIR="${WORKSPACE}/kernel_workspace/common"
fi

# 1. NEUTRALIZE LEGACY ABI PROTECTED EXPORTS (modpost bypass for 5.10-6.6)
for f in "${WORKSPACE}/kernel_workspace/common/android/abi_gki_protected_exports"* "${KERNEL_ROOT}/android/abi_gki_protected_exports"*; do
    [ -f "$f" ] && > "$f" || true
done

# 2. NEUTRALIZE STRICT SYMBOL LISTS & TRIMMING (ABI Bouncer Bypass)
case "$BASE_VER" in
    5.10)
        echo ">>> Maintaining stock ABI/KMI strictness for 5.10 (Untouched to prevent bootloops)..."
        ;;
    5.15)
        echo ">>> Disabling strict ABI mode & trimming in legacy configs and BUILD.bazel for 5.15..."
        sed -i 's/KMI_SYMBOL_LIST_STRICT_MODE=1/KMI_SYMBOL_LIST_STRICT_MODE=0/g' "${KERNEL_ROOT}"/build.config.* 2>/dev/null || true
        sed -i 's/TRIM_NONLISTED_KMI=1/TRIM_NONLISTED_KMI=0/g' "${KERNEL_ROOT}"/build.config.* 2>/dev/null || true

        if [ -f "${BAZEL_DIR}/BUILD.bazel" ] && grep -q 'name = "kernel_aarch64",' "${BAZEL_DIR}/BUILD.bazel"; then
            sed -i '/name = "kernel_aarch64",/a \    kmi_symbol_list_strict_mode = False,\n    trim_nonlisted_kmi = False,' "${BAZEL_DIR}/BUILD.bazel"
        fi
        ;;
    6.1|6.6|6.12)
        echo ">>> Disabling strict ABI mode in BUILD.bazel for $BASE_VER..."
        if [ -f "${BAZEL_DIR}/BUILD.bazel" ]; then
            sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' "${BAZEL_DIR}/BUILD.bazel" 2>/dev/null || true
        fi
        ;;
    *)
        echo ">>> No strict mode sed required for $BASE_VER."
        ;;
esac

# 3. DYNAMIC FRAGMENT ASSEMBLY
NOMOUNT_FRAG="${WORKSPACE}/tools/nomount.fragment"
NETOPTS_FRAG="${WORKSPACE}/tools/net_opts.fragment"

if [ "$ENABLE_NOMOUNT" = "true" ] && [ -f "$NOMOUNT_FRAG" ]; then
    echo ">>> Appending NoMount Kconfigs..."
    cat "$NOMOUNT_FRAG" >> "$COMBINED_FRAG"
    echo "" >> "$COMBINED_FRAG"
fi

if [ "$ENABLE_NET_OPTS" = "true" ] && [ -f "$NETOPTS_FRAG" ]; then
    echo ">>> Appending Network Optimization Kconfigs..."
    cat "$NETOPTS_FRAG" >> "$COMBINED_FRAG"
    echo "" >> "$COMBINED_FRAG"
fi

# 4. INTEGRATE COMBINED KCONFIG FRAGMENT
if [ -s "$COMBINED_FRAG" ]; then
    
    if [ "$ENABLE_NOMOUNT" = "true" ]; then
        echo ">>> Dynamically wiring NoMount hooks into VFS tree..."
        grep -q "nomount" "${KERNEL_ROOT}/fs/Makefile" || echo 'obj-$(CONFIG_NOMOUNT)		+= nomount/' >> "${KERNEL_ROOT}/fs/Makefile"
        grep -q "nomount" "${KERNEL_ROOT}/fs/Kconfig" || echo 'source "fs/nomount/Kconfig"' >> "${KERNEL_ROOT}/fs/Kconfig"
    fi

    case "$BASE_VER" in
        5.10|5.15)
            echo ">>> Injecting Legacy/Bazel $BASE_VER Kconfig Fragment..."
            mkdir -p "${KERNEL_ROOT}/arch/arm64/configs"
            cp "$COMBINED_FRAG" "${KERNEL_ROOT}/arch/arm64/configs/custom_legacy.fragment"
            BUILD_CONFIG=$(find "${KERNEL_ROOT}" "${WORKSPACE}/kernel_workspace" -maxdepth 2 -name "build.config.gki.aarch64" | head -n1 || true)
            if [ -n "$BUILD_CONFIG" ]; then
                echo 'EXTRA_DEFCONFIG_FRAGMENTS="custom_legacy.fragment"' >> "$BUILD_CONFIG"
            fi
            ;;
        6.1)
            echo ">>> Injecting Bazel 6.1 Kconfig Fragment..."
            cp "$COMBINED_FRAG" "${BAZEL_DIR}/custom_fragment"
            if [ -f "${BAZEL_DIR}/BUILD.bazel" ]; then
                sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' "${BAZEL_DIR}/BUILD.bazel"
            fi
            ;;
        *)
            echo ">>> Injecting Bazel 6.6+ Kconfig Fragment..."
            cp "$COMBINED_FRAG" "${BAZEL_DIR}/custom_fragment"
            
            if [ -f "${BAZEL_DIR}/BUILD.bazel" ]; then
                if grep -q '"kernel_aarch64": {' "${BAZEL_DIR}/BUILD.bazel"; then
                    sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' "${BAZEL_DIR}/BUILD.bazel"
                elif grep -q 'name = "kernel_aarch64",' "${BAZEL_DIR}/BUILD.bazel"; then
                    sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' "${BAZEL_DIR}/BUILD.bazel"
                else
                    echo "[-] ERROR: Could not find kernel_aarch64 injection point in BUILD.bazel!"
                    exit 1
                fi
            fi
            ;;
    esac
fi

echo ">>> Configuration complete."
