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

    # ---------------------------------------------------------
    # PIXEL / DEVICE TARGET AUTO-DETECTION
    # ---------------------------------------------------------
    
    # Try to infer device name from OTA_URL if provided
    DEVICE_NAME=""
    if [ -n "${OTA_URL:-}" ]; then
        DEVICE_NAME=$(echo "$OTA_URL" | sed -n 's/.*releases.grapheneos.org\/\([a-z0-9]*\)-ota.*/\1/p' || true)
    fi
    # Hardcode fallback if inference fails
    if [ -z "$DEVICE_NAME" ]; then DEVICE_NAME="komodo"; fi

    echo ">>> Inferred device codename: $DEVICE_NAME"

    # Map Google Pixel device codenames to their shared kernel repository codenames
    KERNEL_CODENAME=""
    case "$DEVICE_NAME" in
        stallion) KERNEL_CODENAME="stallion" ;;
        tegu) KERNEL_CODENAME="tegu" ;;
        comet) KERNEL_CODENAME="comet" ;;
        komodo|caiman|tokay) KERNEL_CODENAME="caimito" ;;
        akita) KERNEL_CODENAME="akita" ;;
        husky|shiba) KERNEL_CODENAME="shusky" ;;
        felix) KERNEL_CODENAME="felix" ;;
        tangorpro) KERNEL_CODENAME="tangorpro" ;;
        lynx) KERNEL_CODENAME="lynx" ;;
        cheetah|panther) KERNEL_CODENAME="pantah" ;;
        bluejay) KERNEL_CODENAME="bluejay" ;;
        raven|oriole) KERNEL_CODENAME="raviole" ;;
        *) KERNEL_CODENAME="$DEVICE_NAME" ;;
    esac

    echo ">>> Mapped Kernel Codename: $KERNEL_CODENAME"

    # GrapheneOS relies on this custom manifest injection for Kleaf builds.
    if [ -f "aosp_manifest.xml" ]; then
        export KLEAF_REPO_MANIFEST="aosp_manifest.xml"
        echo ">>> Exported KLEAF_REPO_MANIFEST=aosp_manifest.xml"
    fi

    BAZEL_TARGET="//common:kernel_aarch64_dist"
    
    # Deep search for the exact mapped target
    FOUND_BUILD=$(find private aosp common -type f -name "BUILD.bazel" -exec grep -l -E "name = \"${KERNEL_CODENAME}_dist\"" {} + | head -n 1 || true)
    if [ -n "$FOUND_BUILD" ]; then
        PKG_PATH=$(dirname "$FOUND_BUILD")
        PKG_PATH=${PKG_PATH#./}
        BAZEL_TARGET="//${PKG_PATH}:${KERNEL_CODENAME}_dist"
    else
        echo "[!] Could not auto-detect ${KERNEL_CODENAME}_dist. Searching for any target matching device..."
        FOUND_BUILD=$(find private aosp -type f -name "BUILD.bazel" -exec grep -l "name = \"${KERNEL_CODENAME}\"" {} + | head -n 1 || true)
        if [ -n "$FOUND_BUILD" ]; then
            PKG_PATH=$(dirname "$FOUND_BUILD")
            PKG_PATH=${PKG_PATH#./}
            BAZEL_TARGET="//${PKG_PATH}:${KERNEL_CODENAME}"
        else
            echo "[!] Falling back to //common:kernel_aarch64_dist"
        fi
    fi

    echo ">>> Using Bazel target: $BAZEL_TARGET"
    
    ./tools/bazel run --config=stamp \
      $TRIM_FLAGS \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=STABLE_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      "$BAZEL_TARGET" \
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

# Locate the compiled Image binary robustly (Wrapper scripts might ignore --destdir and output to out/<codename>/dist)
IMAGE_PATH="$(find "${WORKSPACE}/kernel_workspace" -type f -name 'Image' | grep -v 'host' | head -n 1 || true)"
if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"
cp -f "${IMAGE_PATH}" "${WORKSPACE}/out/Image"

# Map the dist directory to wherever the Image ended up for config checks
ACTUAL_DIST_DIR="$(dirname "${IMAGE_PATH}")"

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
        if [ -f "${ACTUAL_DIST_DIR}/config.gz" ]; then
            CONFIG_SRC="${ACTUAL_DIST_DIR}/config.gz"
        elif [ -f "${ACTUAL_DIST_DIR}/.config" ]; then
            CONFIG_SRC="${ACTUAL_DIST_DIR}/.config"
        else
            CONFIG_SRC=$(find "${ACTUAL_DIST_DIR}" -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
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
