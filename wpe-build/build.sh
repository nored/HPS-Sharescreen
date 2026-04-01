#!/bin/bash
set -e

cd /build/wpewebkit-2.44.4

# Detect architecture for lib dir and .deb
DPKG_ARCH=$(dpkg --print-architecture)
if [ "$DPKG_ARCH" = "armhf" ]; then
  LIB_DIR="lib/arm-linux-gnueabihf"
else
  LIB_DIR="lib/aarch64-linux-gnu"
fi

echo "========================================="
echo "  Building WPE WebKit with WebRTC"
echo "  Architecture: ${DPKG_ARCH}"
echo "  Lib dir: ${LIB_DIR}"
echo "========================================="

mkdir -p build && cd build

cmake .. -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=${LIB_DIR} \
  -DPORT=WPE \
  -DENABLE_WEB_RTC=ON \
  -DENABLE_MEDIA_SOURCE=ON \
  -DENABLE_ENCRYPTED_MEDIA=ON \
  -DENABLE_WEB_AUDIO=ON \
  -DENABLE_VIDEO=ON \
  -DENABLE_WEBGL=ON \
  -DENABLE_JOURNALD_LOG=OFF \
  -DENABLE_BUBBLEWRAP_SANDBOX=ON \
  -DENABLE_MINIBROWSER=OFF \
  -DUSE_SOUP2=OFF \
  -DUSE_AVIF=ON \
  -DUSE_JPEGXL=OFF \
  -DUSE_WPE_RENDERER=ON

echo ""
echo "Starting build with $(nproc) cores..."
echo ""

ninja -j$(nproc)

echo ""
echo "========================================="
echo "  Build complete! Creating .deb package"
echo "========================================="

checkinstall --install=no \
  --pkgname=wpewebkit-webrtc \
  --pkgversion=2.44.4 \
  --pkgrelease=1 \
  --arch=${DPKG_ARCH} \
  --maintainer="HPS-ShareScreen" \
  --provides="libwpewebkit-2.0-dev" \
  --requires="libwpe-1.0-1,libwpebackend-fdo-1.0-1,libgstreamer1.0-0,gstreamer1.0-nice,gstreamer1.0-plugins-bad,libnice10,libopus0,libvpx7,libsrtp2-1,libegl-mesa0,libgles2" \
  --default \
  ninja install

cp *.deb /output/ 2>/dev/null || \
  cp /build/*.deb /output/ 2>/dev/null || true

echo ""
echo "========================================="
echo "  Done!"
echo "  .deb: $(find /build -name '*.deb' -print -quit)"
echo "========================================="
ls -lh /output/*.deb 2>/dev/null
