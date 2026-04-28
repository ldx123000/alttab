#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AltTab"
CONFIG="Release"
DEPLOYMENT_TARGET="13.0"
PROJECT_DIR="$(cd "$(dirname "$0")/AltTab" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_PATH="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}.app"
DIST_DIR="${BUILD_DIR}/dist"

# Default install to ~/Applications (no sudo needed); use --system for /Applications
INSTALL_DIR="${HOME}/Applications"

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  build       Build the app (Release configuration)
  dmg         Build a distributable DMG
  install     Build and install to ~/Applications (user-level)
  run         Build and launch immediately
  clean       Remove build artifacts
  diagnose-hotkeys  Print native Command-Tab enabled state
  restore-hotkeys  Re-enable native macOS Command-Tab shortcuts
  uninstall   Remove installed app and kill running instance

Options:
  --system    Install to /Applications instead of ~/Applications (may need sudo)

Examples:
  ./build.sh build                  # Build only
  ./build.sh dmg                    # Build AltTab.dmg
  ./build.sh install                # Build and install to ~/Applications
  sudo ./build.sh install --system  # Build and install to /Applications
  ./build.sh run                    # Build and launch from build dir
  ./build.sh diagnose-hotkeys       # Show whether native Command-Tab is enabled
  ./build.sh restore-hotkeys        # Restore native Command-Tab if needed
  ./build.sh uninstall              # Remove from ~/Applications
  sudo ./build.sh uninstall --system  # Remove from /Applications

Default: build
EOF
}

# Parse --system flag from any position
for arg in "$@"; do
    if [[ "$arg" == "--system" ]]; then
        INSTALL_DIR="/Applications"
    fi
done

check_clt() {
    if ! command -v swiftc &>/dev/null; then
        echo "Error: swiftc not found. Install Command Line Tools:"
        echo "  xcode-select --install"
        exit 1
    fi
    if ! xcrun --sdk macosx --show-sdk-path &>/dev/null; then
        echo "Error: macOS SDK not found. Install Command Line Tools:"
        echo "  xcode-select --install"
        exit 1
    fi
}

do_build() {
    check_clt

    local sdk_path
    local arch
    local binary_path
    local codesign_output
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    arch="$(uname -m)"
    binary_path="${APP_PATH}/Contents/MacOS/${APP_NAME}"

    echo "Building ${APP_NAME} (${CONFIG}) with swiftc..."
    rm -rf "$APP_PATH"
    mkdir -p "${APP_PATH}/Contents/MacOS"

    swiftc \
        -Osize \
        -whole-module-optimization \
        -sdk "$sdk_path" \
        -F "${sdk_path}/System/Library/PrivateFrameworks" \
        -framework SkyLight \
        -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
        -module-name "$APP_NAME" \
        "${PROJECT_DIR}/${APP_NAME}"/*.swift \
        -o "$binary_path"

    strip -S -x "$binary_path"

    cp "${PROJECT_DIR}/${APP_NAME}/Info.plist" "${APP_PATH}/Contents/Info.plist"
    plutil -lint "${APP_PATH}/Contents/Info.plist" >/dev/null
    if ! codesign_output="$(codesign \
        --force \
        --sign - \
        --timestamp=none \
        "$APP_PATH" 2>&1)"; then
        echo "$codesign_output"
        exit 1
    fi

    echo ""
    echo "Build succeeded: ${APP_PATH}"
}

do_install() {
    do_build

    # Kill running instance
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 0.5

    # Create install dir if needed (for ~/Applications)
    mkdir -p "${INSTALL_DIR}"

    echo "Installing to ${INSTALL_DIR}/${APP_NAME}.app ..."
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    cp -R "$APP_PATH" "${INSTALL_DIR}/"

    echo ""
    echo "Installed successfully!"
    echo ""
    echo "Launch:"
    echo "  open ${INSTALL_DIR}/${APP_NAME}.app"
    echo ""
    echo "First launch:"
    echo "  Grant Accessibility:  System Settings → Privacy & Security → Accessibility → AltTab ON"
}

do_dmg() {
    do_build

    if ! command -v hdiutil &>/dev/null; then
        echo "Error: hdiutil not found. DMG packaging requires macOS hdiutil."
        exit 1
    fi

    local version
    local staging_dir
    local dmg_path
    version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0")"
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.dmg.XXXXXX")"
    dmg_path="${DIST_DIR}/${APP_NAME}-${version}.dmg"
    trap "rm -rf $(printf "%q" "$staging_dir")" EXIT

    echo "Packaging ${APP_NAME} ${version} as DMG..."
    mkdir -p "$staging_dir" "$DIST_DIR"
    cp -R "$APP_PATH" "$staging_dir/"
    ln -s /Applications "${staging_dir}/Applications"
    rm -f "$dmg_path"

    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$staging_dir" \
        -format UDZO \
        -ov \
        "$dmg_path" >/dev/null

    hdiutil verify "$dmg_path" >/dev/null
    rm -rf "$staging_dir"
    trap - EXIT

    echo ""
    echo "DMG created: ${dmg_path}"
    echo ""
    echo "Install:"
    echo "  Open the DMG, then drag ${APP_NAME}.app to Applications."
}

do_run() {
    do_build
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 0.5
    echo "Launching ${APP_NAME}..."
    open "$APP_PATH"
}

do_clean() {
    echo "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    echo "Done."
}

do_restore_hotkeys() {
    echo "Restoring native macOS Command-Tab shortcuts..."
    swift -e 'import CoreGraphics; @_silgen_name("CGSSetSymbolicHotKeyEnabled") func setHotKey(_ h: Int, _ e: Bool) -> CGError; _ = setHotKey(1, true); _ = setHotKey(2, true)'
    echo "Done."
}

do_diagnose_hotkeys() {
    echo "AltTab process:"
    pgrep -fl "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" || true
    echo ""
    echo "Native macOS hotkeys:"
    swift -e 'import CoreGraphics; @_silgen_name("CGSIsSymbolicHotKeyEnabled") func isEnabled(_ h: Int) -> Bool; @_silgen_name("CGSGetSymbolicHotKeyValue") func value(_ h: Int, _ o: UnsafeMutablePointer<UInt32>, _ k: UnsafeMutablePointer<UInt32>, _ m: UnsafeMutablePointer<UInt32>) -> CGError; for h in [1, 2, 6] { var o: UInt32 = 0; var k: UInt32 = 0; var m: UInt32 = 0; _ = value(h, &o, &k, &m); print("  id=\(h) enabled=\(isEnabled(h)) key=\(k) modifiers=\(m)") }'
    echo ""
    echo "Expected while AltTab is active: id=1 and id=2 enabled=false."
}

do_uninstall() {
    echo "Uninstalling ${APP_NAME} from ${INSTALL_DIR}..."
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    do_restore_hotkeys
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    echo "Removed ${APP_NAME} from ${INSTALL_DIR}."
    echo "Note: You may want to remove it from Login Items in System Settings."
}

# Get first non-flag argument as the command
CMD="build"
for arg in "$@"; do
    if [[ "$arg" != --* ]]; then
        CMD="$arg"
        break
    fi
done

case "$CMD" in
    build)     do_build ;;
    dmg)       do_dmg ;;
    install)   do_install ;;
    run)       do_run ;;
    clean)     do_clean ;;
    diagnose-hotkeys) do_diagnose_hotkeys ;;
    restore-hotkeys) do_restore_hotkeys ;;
    uninstall) do_uninstall ;;
    -h|--help|help) usage ;;
    *)
        echo "Unknown command: $CMD"
        usage
        exit 1
        ;;
esac
