cmake_minimum_required(VERSION 3.16)
project(sharescreen-receiver LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)

pkg_check_modules(GST REQUIRED
  gstreamer-1.0
  gstreamer-sdp-1.0
  gstreamer-webrtc-1.0
)

pkg_check_modules(SOUP REQUIRED libsoup-3.0)
pkg_check_modules(JSON REQUIRED json-glib-1.0)
pkg_check_modules(GLIB REQUIRED glib-2.0 gio-2.0)

add_executable(sharescreen-receiver
  src/main.cpp
  src/signaling.cpp
  src/pipeline.cpp
)

target_include_directories(sharescreen-receiver PRIVATE
  ${GST_INCLUDE_DIRS}
  ${SOUP_INCLUDE_DIRS}
  ${JSON_INCLUDE_DIRS}
  ${GLIB_INCLUDE_DIRS}
)

target_link_libraries(sharescreen-receiver PRIVATE
  ${GST_LIBRARIES}
  ${SOUP_LIBRARIES}
  ${JSON_LIBRARIES}
  ${GLIB_LIBRARIES}
)

target_compile_options(sharescreen-receiver PRIVATE
  ${GST_CFLAGS_OTHER}
  ${SOUP_CFLAGS_OTHER}
  ${JSON_CFLAGS_OTHER}
  ${GLIB_CFLAGS_OTHER}
)

target_compile_definitions(sharescreen-receiver PRIVATE GST_USE_UNSTABLE_API)

install(TARGETS sharescreen-receiver DESTINATION bin)
