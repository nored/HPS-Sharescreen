#!/bin/bash
set -e

cd /build/wpewebkit-2.44.4

echo "========================================="
echo "  Building WPE WebKit with WebRTC"
echo "========================================="

mkdir -p build && cd build

cmake .. -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
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
echo "Starting build... this will take a while."
echo ""

# Use all available cores
ninja -j$(nproc)

echo ""
echo "========================================="
echo "  Build complete! Creating .deb package"
echo "========================================="

# Install to staging directory and create .deb
DESTDIR=/build/pkg ninja install

# Create .deb with checkinstall
checkinstall --install=no \
  --pkgname=wpewebkit-webrtc \
  --pkgversion=2.44.4 \
  --pkgrelease=1 \
  --arch=arm64 \
  --maintainer="HPS-ShareScreen" \
  --provides="libwpewebkit-2.0-dev" \
  --requires="libwpe-1.0-1,libwpebackend-fdo-1.0-1,libgstreamer1.0-0,gstreamer1.0-nice,gstreamer1.0-plugins-bad,libnice10,libopus0,libvpx7,libsrtp2-1" \
  --default \
  ninja install

# Copy .deb to output
cp /build/wpewebkit-2.44.4/build/*.deb /output/ 2>/dev/null || \
  cp /build/*.deb /output/ 2>/dev/null || \
  echo "NOTE: .deb is at $(find /build -name '*.deb' -print -quit)"

echo ""
echo "========================================="
echo "  Done! .deb package in /output/"
echo "========================================="
