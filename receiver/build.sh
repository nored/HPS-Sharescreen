#!/bin/bash
# Build the C++ receiver on the Pi
set -e

echo "Installing build dependencies..."
sudo apt-get install -y -qq \
  build-essential cmake pkg-config \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-bad1.0-dev \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-nice \
  gir1.2-gst-plugins-bad-1.0 \
  libsoup-3.0-dev \
  libjson-glib-dev

echo "Building..."
cd "$(dirname "$0")"
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

echo ""
echo "Built: $(pwd)/sharescreen-receiver"
echo ""
echo "Install:"
echo "  sudo cp build/sharescreen-receiver /usr/local/bin/"
