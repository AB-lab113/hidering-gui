#!/usr/bin/env bash
# Reproducible Linux AppImage build for Hidering Wallet GUI.
#
# Tested on Ubuntu 24.04 (glibc 2.39, Qt 5.15.13). The resulting AppImage runs
# on distros with glibc >= 2.39 (Ubuntu 24.04+, Debian 13+, Fedora 39+).
# For wider compat, rebuild on an older base distro.
#
# Usage:  scripts/build-appimage.sh [VERSION]   # default VERSION=v2.0.0

set -euo pipefail

VERSION="${1:-v2.0.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-release"

echo "==> Release build (-DCMAKE_BUILD_TYPE=Release -DWITH_SCANNER=OFF)"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_SCANNER=OFF -DMANUAL_SUBMODULES=ON
make -j2  # use -j2 to stay below 7.4 GB RAM limit on WSL2; bump if you have more

echo "==> Strip"
strip --strip-unneeded bin/hidering-wallet-gui

echo "==> Scaffold AppDir"
rm -rf AppDir
mkdir -p AppDir/usr/bin \
         AppDir/usr/share/applications \
         AppDir/usr/share/icons/hicolor/256x256/apps
cp bin/hidering-wallet-gui AppDir/usr/bin/
cp "$REPO_ROOT/images/appicons/256x256.png" AppDir/usr/share/icons/hicolor/256x256/apps/hidering-wallet.png
cp "$REPO_ROOT/images/appicons/256x256.png" AppDir/hidering-wallet.png  # root icon REQUIRED by linuxdeployqt
cat > AppDir/usr/share/applications/hidering-wallet.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Hidering Wallet
GenericName=Cryptocurrency Wallet
Comment=Privacy-focused desktop wallet for Hidering (HRG)
Exec=hidering-wallet-gui
Icon=hidering-wallet
Terminal=false
Categories=Office;Finance;
Keywords=hidering;hrg;cryptocurrency;wallet;privacy;monero;
StartupWMClass=Hidering
EOF

echo "==> Fetch linuxdeployqt (extracted to avoid libfuse2 dependency)"
if [ ! -d squashfs-root ]; then
    curl -fL --retry 5 -o linuxdeployqt.AppImage \
        https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage
    chmod +x linuxdeployqt.AppImage
    ./linuxdeployqt.AppImage --appimage-extract >/dev/null
fi

echo "==> Bundle Qt + system libs via linuxdeployqt"
# NOTE: do NOT pass -extra-plugins=platforms/libqxcb.so — the slash in the plugin
# name crashes linuxdeployqt silently with exit 1. Default detection is fine.
./squashfs-root/usr/bin/linuxdeployqt \
    AppDir/usr/bin/hidering-wallet-gui \
    -qmldir="$REPO_ROOT" \
    -unsupported-allow-new-glibc \
    -verbose=1 || true   # linuxdeployqt may exit 1 only because its auto-runtime-download fails; we handle that next.

echo "==> Fetch AppImage runtime via gh CLI (auto-download from appimagetool 502s often)"
if [ ! -f runtime-x86_64 ]; then
    gh release download continuous \
        --repo AppImage/type2-runtime \
        --pattern runtime-x86_64 \
        --skip-existing
fi
chmod +x runtime-x86_64

echo "==> Pack AppImage with explicit runtime file"
OUT="Hidering_Wallet-${VERSION}-x86_64.AppImage"
VERSION="$VERSION" ./squashfs-root/usr/bin/appimagetool \
    --runtime-file ./runtime-x86_64 \
    AppDir "$OUT"

echo "==> Built: $BUILD_DIR/$OUT"
ls -lh "$OUT"
sha256sum "$OUT"
