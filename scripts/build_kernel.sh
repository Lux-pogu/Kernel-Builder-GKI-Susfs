#!/usr/bin/env bash
# scripts/build_kernel.sh
set -euo pipefail

ENABLE_NOMOUNT=${ENABLE_NOMOUNT:-false}
ENABLE_NET_OPTS=${ENABLE_NET_OPTS:-false}
BASE_VER=${BASE_VER:-}
OFFICIAL_DATE=${OFFICIAL_DATE:-$(date +%s)}
OFFICIAL_HASH=${OFFICIAL_HASH:-unknown}

echo "=== Initializing Execution Engine ==="

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
cd "${WORKSPACE}/kernel_workspace"

mkdir -p ../out out/dist
# Ensure we pass an absolute path to Bazel, so output routing is agnostic to where tools/bazel lives
DIST_DIR_ABS="$(realpath out/dist)"

# --- DYNAMIC PATH RESOLUTION ---
BAZEL_DIR=""
BAZEL_BIN=""
COMMON_DIR=""
BUILD_SH=""

# Locate tools/bazel (Kleaf root)
for candidate in "." "common" "aosp" "common/aosp"; do
    if [ -f "${candidate}/tools/bazel" ]; then
        BAZEL_DIR="${candidate}"
        BAZEL_BIN="${candidate}/tools/bazel"
        break
    fi
done

# Fallback: Deep search for tools/bazel
if [ -z "$BAZEL_BIN" ]; then
    FOUND_BAZEL=$(find . -maxdepth 4 -type f -path "*/tools/bazel" | head -n 1 || true)
    if [ -n "$FOUND_BAZEL" ]; then
        BAZEL_BIN="$FOUND_BAZEL"
        BAZEL_DIR=$(dirname $(dirname "$FOUND_BAZEL"))
    fi
fi

# Locate common dir (for git modifications payload)
for candidate in "common" "." "aosp/common"; do
    if [ -d "${candidate}/.git" ]; then
        COMMON_DIR="${candidate}"
        break
    fi
done
if [ -z "$COMMON_DIR" ]; then
    COMMON_DIR=$(find . -maxdepth 3 -type d -name "common" | head -n 1 || true)
fi

echo ">>> Marking repo as clean (sanitizes all custom configuration & source modifications)..."
if [ -n "$COMMON_DIR" ] && [ -d "$COMMON_DIR" ]; then
    git -C "$COMMON_DIR" ls-files -m | xargs -r git -C "$COMMON_DIR" update-index --assume-unchanged || true
fi

# Build method 
if [ "$BASE_VER" != "5.10" ] && [ -n "$BAZEL_BIN" ] && [ -f "$BAZEL_BIN" ]; then
    echo ">>> Modern Kleaf/Bazel ecosystem detected for $BASE_VER at ${BAZEL_BIN}..."
    
    TRIM_FLAGS=""
    if [ "$BASE_VER" = "5.15" ]; then
        echo "  -> 5.15 detected. Relying on physical Bazel dictionary patch (omitting --notrim)..."
    else
        TRIM_FLAGS="--notrim"
    fi
    
    echo ">>> Executing Bazel from workspace: ${BAZEL_DIR:-.}"
    cd "${BAZEL_DIR:-.}"
    
    # Enforce standard sandboxing, disable trimming dynamically, and inject MAKEFLAGS
    ./tools/bazel run --config=stamp \
      $TRIM_FLAGS \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=STABLE_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      //common:kernel_aarch64_dist \
      -- \
      --destdir="${DIST_DIR_ABS}"
      
    cd "${WORKSPACE}/kernel_workspace"
else
    echo ">>> Legacy Hermetic Make ecosystem detected (5.10 or fallback)..."
    
    # Locate build/build.sh
    for candidate in "build/build.sh" "common/build/build.sh" "build.sh"; do
        if [ -f "$candidate" ]; then
            BUILD_SH="$candidate"
            break
        fi
    done
    if [ -z "$BUILD_SH" ]; then
        BUILD_SH=$(find . -maxdepth 4 -type f -name "build.sh" | head -n 1 || true)
    fi
    
    export DIST_DIR="${DIST_DIR_ABS}"
    export KERNEL_DIR="${COMMON_DIR:-common}"
    export BUILD_CONFIG="${KERNEL_DIR}/build.config.gki.aarch64"
    export SOURCE_DATE_EPOCH="$OFFICIAL_DATE"
    export EXTRA_LINUX_VERSION="-g${OFFICIAL_HASH}"
    
    if [ -n "$BUILD_SH" ] && [ -f "$BUILD_SH" ]; then
        echo "[+] Invoking ${BUILD_SH}..."
        bash "$BUILD_SH"
    else
        echo "[-] ERROR: Legacy build/build.sh orchestrator not found!" >&2
        exit 1
    fi
fi

IMAGE_PATH="$(find "${DIST_DIR_ABS}" -type f -name 'Image' -print -quit)"
if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced in ${DIST_DIR_ABS}!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"
cp -f "${IMAGE_PATH}" "${WORKSPACE}/out/Image"

echo ">>> Extracting kernel runtime version string..."
KERNEL_VERSION_STRING=$(strings "${WORKSPACE}/out/Image" | grep -E "Linux version [0-9]" | head -n 1 || true)

if [ -z "$KERNEL_VERSION_STRING" ]; then
    KERNEL_VERSION_STRING=$(strings "${WORKSPACE}/out/Image" | grep -i "Linux version" | head -n 1 || true)
fi

if [ -n "$KERNEL_VERSION_STRING" ]; then
    echo "    $KERNEL_VERSION_STRING"
else
    echo "    [!] Notice: Could not read raw banner string directly from compiled Image binary."
fi

# --- DYNAMIC KCONFIG VALIDATION REPORT ---
if [ "$ENABLE_NOMOUNT" = "true" ] || [ "$ENABLE_NET_OPTS" = "true" ]; then
    echo "::group::Custom Kconfig Integration Report"
    echo ""
    echo "=============================================="
    echo " CUSTOM KCONFIG VALIDATION REPORT             "
    echo "=============================================="

    FRAGMENT_FILE="${WORKSPACE}/tools/custom_combined.fragment"
    
    if [ ! -f "$FRAGMENT_FILE" ]; then
        echo "[-] Notice: tools/custom.fragment not found. Skipping validation."
    else
        CONFIG_SRC=""
        if [ -f "${DIST_DIR_ABS}/config.gz" ]; then
            CONFIG_SRC="${DIST_DIR_ABS}/config.gz"
        elif [ -f "${DIST_DIR_ABS}/.config" ]; then
            CONFIG_SRC="${DIST_DIR_ABS}/.config"
        else
            CONFIG_SRC=$(find "${DIST_DIR_ABS}" -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
        fi

        if [ -z "$CONFIG_SRC" ]; then
            echo "[!] WARN: Could not locate compiled kernel configuration target."
        else
            echo ">>> Extracting definitions from: $CONFIG_SRC"
            echo "----------------------------------------------"
            
            REQUESTED_CONFIGS=$(grep -E '^CONFIG_' "$FRAGMENT_FILE" | cut -d'=' -f1 || true)
            
            if [ -z "$REQUESTED_CONFIGS" ]; then
                echo "  [-] No active custom configs found in fragment."
            else
                for CFG in $REQUESTED_CONFIGS; do
                    if [[ "$CONFIG_SRC" == *.gz ]]; then
                        VAL=$(zgrep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    else
                        VAL=$(grep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    fi

                    if [ "$VAL" = "y" ]; then
                        printf "  [ PASS ] %-40s = %s\n" "$CFG" "$VAL"
                    elif [ "$VAL" = "m" ]; then
                        printf "  [ WARN ] %-40s = %s (Module)\n" "$CFG" "$VAL"
                    else
                        printf "  [ DROP ] %-40s = MISSING/OVERRIDDEN\n" "$CFG"
                    fi
                done
            fi
        fi
    fi

    echo "=============================================="
    echo "::endgroup::"
fi

echo ">>> Build execution loop completed"
