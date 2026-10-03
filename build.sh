#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f -- "$0")")"
cd "$SCRIPT_DIR" || exit 1

PLATFORM_JAR="${SCRIPT_DIR}/framework-res.apk"
PLATFORM_KEY="${SCRIPT_DIR}/keys/platform.pk8"
PLATFORM_CERT="${SCRIPT_DIR}/keys/platform.x509.pem"
OVERLAY_NAME="$(sed -nE 's/LOCAL_PACKAGE_NAME.*:=\s*(.*)/\1/p' Framework/Android.mk)"
OVERLAY_SYSTEMUI_NAME="$(sed -nE 's/LOCAL_PACKAGE_NAME.*:=\s*(.*)/\1/p' SystemUI/Android.mk)"

readonly SCRIPT_DIR
readonly PLATFORM_JAR
readonly PLATFORM_KEY
readonly PLATFORM_CERT
readonly OVERLAY_NAME
readonly OVERLAY_SYSTEMUI_NAME

# Trap Cleanup handler
HW_OVERLAY_TMP=""
MAGISK_MODULE_TMP=""
cleanup() {
    [ -n "$HW_OVERLAY_TMP" ] && rm -rf "$HW_OVERLAY_TMP"
    [ -n "$MAGISK_MODULE_TMP" ] && rm -rf "$MAGISK_MODULE_TMP"
}
trap cleanup EXIT INT TERM

echo '==========================='
echo "Building Overlay APKs"
echo '==========================='

#############################################################################
## Clean
#############################################################################
echo -n "Cleaning previous build... "
[ -d build/ ] && rm -rf build/
[ -d out/ ] && rm -rf out/
echo "cleaned ✓"

#############################################################################
## Compile framework-res overlay
#############################################################################
mkdir -p build/compiled
echo -n "Compiling framework-res overlay... "
aapt2 compile --dir Framework/res -o build/compiled/ >/dev/null 2>&1 \
    || { echo "Error: aapt2 compile failed"; exit 1; }
echo "compiled ✓"

#############################################################################
## Compile SystemUI overlay
#############################################################################
echo -n "Compiling SystemUI overlay... "
if [ -d "SystemUI/res" ] && [ "$(ls -A SystemUI/res 2>/dev/null)" ]; then
    mkdir -p build/compiled_systemui
    aapt2 compile --dir SystemUI/res -o build/compiled_systemui/ >/dev/null 2>&1 \
        || { echo "Error: aapt2 compile (systemui) failed"; exit 1; }
    echo "compiled ✓"
else
    echo "No SystemUI resources found — skipping SystemUI overlay"
fi

#############################################################################
## Link framework-res overlay
#############################################################################
if [ ! -f "$PLATFORM_JAR" ]; then
    echo -e "\nError: Linking PLATFORM_JAR ($PLATFORM_JAR) not found!"
    exit 1
fi

echo -n "Linking framework-res APK... "
mkdir -p build/apk
aapt2 link --manifest Framework/AndroidManifest.xml \
    -I "${PLATFORM_JAR}" \
    --auto-add-overlay \
    -o build/apk/unsigned.apk \
    build/compiled/*.flat >/dev/null 2>&1 || { echo "Error: aapt2 link failed"; exit 1; }
echo "linked ✓"

#############################################################################
## Link SystemUI overlay
#############################################################################
LINKED_SYSTEMUI=false
if compgen -G "build/compiled_systemui/*.flat" > /dev/null; then
    echo -n "Linking SystemUI APK... "
    aapt2 link --manifest SystemUI/AndroidManifest.xml \
        -I "${PLATFORM_JAR}" \
        --auto-add-overlay \
        -o build/apk/systemui_unsigned.apk \
        build/compiled_systemui/*.flat >/dev/null 2>&1 \
        || { echo "Error: aapt2 link (systemui) failed"; exit 1; }
    LINKED_SYSTEMUI=true
    echo "linked ✓"
fi

#############################################################################
## Zipalign
#############################################################################
echo -n "Zipaligning Framework-res APK... "
zipalign -f 4 build/apk/unsigned.apk build/apk/aligned.apk >/dev/null 2>&1 \
    || { echo "Error: zipalign failed"; exit 1; }
echo "aligned ✓"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    echo -n "Zipaligning SystemUI APK... "
    zipalign -f 4 build/apk/systemui_unsigned.apk build/apk/systemui_aligned.apk >/dev/null 2>&1 \
        || { echo "Error: zipalign (systemui) failed"; exit 1; }
    echo "aligned ✓"
fi

#############################################################################
## Signing APKs
#############################################################################
if [ ! -f "$PLATFORM_KEY" ] || [ ! -f "$PLATFORM_CERT" ]; then
    echo -e "\nError: Signing keys not found!"
    echo "Error: Key:  ${PLATFORM_KEY}"
    echo "Error: Cert: ${PLATFORM_CERT}"
    exit 1
fi

echo -n "Signing Framework-res APK... "
mkdir -p out/apks
apksigner sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
    --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
    --out "out/apks/${OVERLAY_NAME}.apk" build/apk/aligned.apk >/dev/null 2>&1 \
    || { echo "Error: apksigner failed"; exit 1; }

echo "signed: out/apks/${OVERLAY_NAME}.apk ✓"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    echo -n "Signing SystemUI APK... "
    apksigner sign --key "${PLATFORM_KEY}" --cert "${PLATFORM_CERT}" \
        --v1-signing-enabled true --v2-signing-enabled true --v4-signing-enabled false \
        --out "out/apks/${OVERLAY_SYSTEMUI_NAME}.apk" build/apk/systemui_aligned.apk >/dev/null 2>&1 \
        || { echo "Error: apksigner (systemui) failed"; exit 1; }

    echo "signed: out/apks/${OVERLAY_SYSTEMUI_NAME}.apk ✓"
fi

#############################################################################
## Verify APKs
#############################################################################
echo -n "Verifying Framework-res APK... "
apksigner verify "out/apks/${OVERLAY_NAME}.apk" >/dev/null 2>&1 \
    && echo "verified ✓" || { echo "Error: Verification failed"; exit 1; }

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    echo -n "Verifying SystemUI APK... "
    apksigner verify "out/apks/${OVERLAY_SYSTEMUI_NAME}.apk" >/dev/null 2>&1 \
        && echo "verified ✓" || { echo "Error: Verification failed"; exit 1; }
fi

SIZE_FW=$(du -sh "out/apks/${OVERLAY_NAME}.apk" 2>/dev/null | cut -f1)
echo "Framework APK size: ${SIZE_FW}"
if [ "$LINKED_SYSTEMUI" = "true" ]; then
    SIZE_SU=$(du -sh "out/apks/${OVERLAY_SYSTEMUI_NAME}.apk" 2>/dev/null | cut -f1)
    echo "SystemUI APK size: ${SIZE_SU}"
fi

#############################################################################
## Building Vendor Hardware Overlay
#############################################################################
echo '================================='
echo "Building Vendor Hardware Overlay"
echo '================================='

HW_OVERLAY_TMP="$(mktemp -d -p "${SCRIPT_DIR}/")"
mkdir -p "${HW_OVERLAY_TMP}/Infinix/Hot30I-X669C"
echo -n "Copying Framework-res Vendor HW Overlay... "
cp -a Framework/* "${HW_OVERLAY_TMP}/Infinix/Hot30I-X669C/" \
    || { echo "Error: Copying Framework-res Vendor HW Overlay failed"; exit 1; }
echo "copied ✓"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    mkdir -p "${HW_OVERLAY_TMP}/Infinix/Hot30I-X669C-SystemUI"
    echo -n "Copying SystemUI Vendor HW Overlay... "
    cp -a SystemUI/* "${HW_OVERLAY_TMP}/Infinix/Hot30I-X669C-SystemUI/" \
        || { echo "Error: Copying SystemUI Vendor HW Overlay failed"; exit 1; }
    echo "copied ✓"
fi

HW_OVERLAY_NAME="vendor-hardware-${OVERLAY_NAME#*-}"
(cd "$HW_OVERLAY_TMP" && zip -rq "${SCRIPT_DIR}/out/${HW_OVERLAY_NAME}.zip" .)
echo "Vendor HW Overlay created: out/${HW_OVERLAY_NAME}.zip ✓"

#############################################################################
## Build Magisk module
#############################################################################
echo '==========================='
echo "Building Magisk Module"
echo '==========================='

MAGISK_MODULE_TMP="$(mktemp -d -p "${SCRIPT_DIR}/")"

mkdir -p "$MAGISK_MODULE_TMP/META-INF/com/google/android"

echo -n "Copying update-binary..."
if [ -f update-binary ]; then
    cp update-binary "${MAGISK_MODULE_TMP}/META-INF/com/google/android/update-binary" \
        || { echo "Error: Copying update-binary failed"; exit 1; }
    echo "copied ✓"
fi

echo -n "Copying updater-script..."
if [ -f updater-script ]; then
    cp updater-script "${MAGISK_MODULE_TMP}/META-INF/com/google/android/updater-script" \
        || { echo "Error: Copying updater-script failed"; exit 1; }
    echo "copied ✓"
fi

mkdir -p "${MAGISK_MODULE_TMP}/system/product/overlay"

echo -n "Copying Framework-res APK... "
cp "out/apks/${OVERLAY_NAME}.apk" "${MAGISK_MODULE_TMP}/system/product/overlay/" \
     || { echo "Error: Copying Framework-res APK failed"; exit 1; }
echo "Copied ✓"

if [ "$LINKED_SYSTEMUI" = "true" ]; then
    echo -n "Copying SystemUI APK... "
    cp "out/apks/${OVERLAY_SYSTEMUI_NAME}.apk" "${MAGISK_MODULE_TMP}/system/product/overlay/" \
         || { echo "Error: Copying SystemUI APK failed"; exit 1; }
    echo "Copied ✓"
fi

echo -n "Copying module.prop... "
if [ -f module.prop ]; then
    cp module.prop "${MAGISK_MODULE_TMP}/module.prop" \
        || { echo "Error: Copying module.prop failed"; exit 1; }
    echo "Copied ✓"
fi

echo -n "Copying customize.sh script... "
if [ -f customize.sh ]; then
    cp customize.sh "${MAGISK_MODULE_TMP}/customize.sh" \
        || { echo "Error: Copying customize.sh failed"; exit 1; }
    chmod +x "${MAGISK_MODULE_TMP}/customize.sh"
    echo "copied ✓"
fi

(cd "$MAGISK_MODULE_TMP" && zip -rq "${SCRIPT_DIR}/out/${OVERLAY_NAME}-magisk.zip" .)
echo "Magisk module created: out/${OVERLAY_NAME}-magisk.zip ✓"
