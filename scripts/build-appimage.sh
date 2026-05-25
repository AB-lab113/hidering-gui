#!/usr/bin/env bash
# Reproducible Linux AppImage build for Hidering Wallet GUI.
#
# Tested on Ubuntu 24.04 (glibc 2.39, Qt 5.15.13). The resulting AppImage runs
# on distros with glibc >= 2.39 (Ubuntu 24.04+, Debian 13+, Fedora 39+).
# For wider compat, rebuild on an older base distro.
#
# Bundling uses TheAssassin's linuxdeploy + linuxdeploy-plugin-qt (NOT linuxdeployqt).
# linuxdeployqt 'continuous' build 107 (2025-10) is broken on this stack: it detects
# the Qt libs via ldd but never copies them into the AppDir, so appimagetool then
# aborts with "Desktop file not found". linuxdeploy bundles Qt correctly. Both
# linuxdeploy and the qt plugin REQUIRE patchelf (installed below if missing).
#
# Usage:  scripts/build-appimage.sh [VERSION]   # default VERSION=v2.0.1

set -euo pipefail

VERSION="${1:-v2.0.1}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-release"

echo "==> Release build (-DCMAKE_BUILD_TYPE=Release -DWITH_SCANNER=OFF)"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_SCANNER=OFF -DMANUAL_SUBMODULES=ON
make -j2  # use -j2 to stay below 7.4 GB RAM limit on WSL2; bump if you have more

echo "==> Strip"
strip --strip-unneeded bin/hidering-wallet-gui

echo "==> Ensure patchelf (required by linuxdeploy + linuxdeploy-plugin-qt)"
if ! command -v patchelf >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/patchelf" ]; then
    pip install --user --break-system-packages patchelf
fi
export PATH="$HOME/.local/bin:$PATH"
command -v patchelf >/dev/null || { echo "ERROR: patchelf unavailable"; exit 1; }

echo "==> Write .desktop"
DESKTOP="$BUILD_DIR/hidering-wallet.desktop"
cat > "$DESKTOP" <<'EOF'
[Desktop Entry]
Type=Application
Name=HIDERING Wallet
GenericName=Cryptocurrency Wallet
Comment=Privacy-focused desktop wallet for Hidering (HRG)
Exec=hidering-wallet-gui
Icon=hidering-wallet-gui
Terminal=false
Categories=Office;Finance;
Keywords=hidering;hrg;cryptocurrency;wallet;privacy;
StartupWMClass=Hidering
EOF

echo "==> Fetch tools (extracted to avoid a libfuse2 dependency)"
TOOLS="$BUILD_DIR/.tools"
mkdir -p "$TOOLS"
dl_extract() { # url outdir
    local url="$1" out="$2"
    if [ ! -e "$TOOLS/$out/AppRun" ]; then
        curl -fsSL --retry 5 -o "$TOOLS/$out.AppImage" "$url"
        chmod +x "$TOOLS/$out.AppImage"
        ( cd "$TOOLS" && rm -rf squashfs-root && "./$out.AppImage" --appimage-extract >/dev/null \
          && rm -rf "$out" && mv squashfs-root "$out" )
    fi
}
dl_extract https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage ld-main
dl_extract https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage ld-qt
dl_extract https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage ait
# linuxdeploy discovers its qt plugin as an executable named 'linuxdeploy-plugin-qt' in PATH
ln -sf "$TOOLS/ld-main/AppRun" "$TOOLS/linuxdeploy"
ln -sf "$TOOLS/ld-qt/AppRun"   "$TOOLS/linuxdeploy-plugin-qt"
export PATH="$TOOLS:$PATH"

echo "==> Bundle Qt + system libs via linuxdeploy + plugin-qt"
# Use the real Qt5 qmake explicitly; the /usr/bin/qmake qtchooser wrapper can resolve
# to an empty path in non-interactive shells.
QMAKE_BIN="${QMAKE:-/usr/lib/qt5/bin/qmake}"
[ -x "$QMAKE_BIN" ] || QMAKE_BIN="$(command -v qmake)"
echo "    using qmake: $QMAKE_BIN ($("$QMAKE_BIN" -query QT_VERSION 2>/dev/null))"
rm -rf AppDir
QMAKE="$QMAKE_BIN" QML_SOURCES_PATHS="$REPO_ROOT" \
    "$TOOLS/linuxdeploy" --appdir AppDir \
        -e bin/hidering-wallet-gui \
        -i "$REPO_ROOT/images/appicons/256x256.png" --icon-filename hidering-wallet-gui \
        -d "$DESKTOP" \
        --plugin qt

echo "==> Add offscreen platform plugin (lets the AppImage run headless / in CI)"
OFFSCREEN="$("$QMAKE_BIN" -query QT_INSTALL_PLUGINS)/platforms/libqoffscreen.so"
[ -f "$OFFSCREEN" ] && cp "$OFFSCREEN" AppDir/usr/plugins/platforms/ || true

echo "==> Fetch AppImage runtime via gh CLI (appimagetool auto-download 502s often)"
if [ ! -f runtime-x86_64 ]; then
    gh release download continuous \
        --repo AppImage/type2-runtime \
        --pattern runtime-x86_64 \
        --skip-existing
fi
chmod +x runtime-x86_64

echo "==> Pack AppImage with explicit runtime file"
OUT="Hidering_Wallet-${VERSION}-x86_64.AppImage"
rm -f "$OUT"
ARCH=x86_64 "$TOOLS/ait/AppRun" --runtime-file ./runtime-x86_64 AppDir "$OUT"

echo "==> Built: $BUILD_DIR/$OUT"
ls -lh "$OUT"
sha256sum "$OUT"
