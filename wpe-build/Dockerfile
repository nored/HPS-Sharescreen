FROM --platform=linux/arm64 debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# All build + runtime dependencies for WPE WebKit with WebRTC
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build pkg-config \
    git python3 ruby gperf unifdef \
    \
    libwpe-1.0-dev \
    libwpebackend-fdo-1.0-dev \
    libglib2.0-dev \
    libsoup-3.0-dev \
    libjavascriptcoregtk-6.0-dev \
    \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-nice \
    \
    libnice-dev \
    libopus-dev \
    libvpx-dev \
    libssl-dev \
    libsrtp2-dev \
    libevent-dev \
    libgcrypt20-dev \
    \
    libharfbuzz-dev \
    libicu-dev \
    libcairo2-dev \
    libjpeg-dev \
    libpng-dev \
    libwebp-dev \
    libxml2-dev \
    libxslt1-dev \
    libsqlite3-dev \
    libenchant-2-dev \
    libwoff-dev \
    libepoxy-dev \
    liblcms2-dev \
    libseccomp-dev \
    libsystemd-dev \
    libtasn1-6-dev \
    libavif-dev \
    libmanette-0.2-dev \
    libatk1.0-dev \
    libatk-bridge2.0-dev \
    \
    libdrm-dev \
    libgbm-dev \
    libinput-dev \
    libudev-dev \
    libwayland-dev \
    wayland-protocols \
    libxkbcommon-dev \
    libegl-mesa0 \
    libgles2 \
    \
    bubblewrap xdg-dbus-proxy \
    checkinstall \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download WPE WebKit 2.44.4 source
RUN curl -L https://wpewebkit.org/releases/wpewebkit-2.44.4.tar.xz | tar xJ

COPY build.sh /build/build.sh
RUN chmod +x /build/build.sh

CMD ["/build/build.sh"]
