#!/usr/bin/env bash
# Recompile Immich's custom image-processing libraries, mirroring the compile_*
# functions of community-scripts ct/immich.sh. A library is rebuilt only when its
# target revision differs from the one recorded in ~/.immich_library_revisions.
# libheif and libraw are pinned by ct/immich.sh; pass the current pins through
# LIBHEIF_REVISION and LIBRAW_REVISION. The others follow base-images main.
# Upstream sync: community-scripts ProxmoxVE ct/immich.sh @ 5515363c84 (2026-09-29).
# Update this line whenever the script is re-matched against upstream.
set -euo pipefail

: "${LIBHEIF_REVISION:?set LIBHEIF_REVISION to the pin in ct/immich.sh}"
: "${LIBRAW_REVISION:?set LIBRAW_REVISION to the pin in ct/immich.sh}"

export LD_LIBRARY_PATH=/usr/local/lib
export LD_RUN_PATH=/usr/local/lib
STAGING_DIR=/opt/staging
BASE_DIR=${STAGING_DIR}/base-images
SOURCE_DIR=${STAGING_DIR}/image-source
REVISIONS_FILE=/root/.immich_library_revisions
mkdir -p "$SOURCE_DIR"
touch "$REVISIONS_FILE"

if [[ -d "$BASE_DIR"/.git ]]; then
  git -C "$BASE_DIR" pull
else
  git clone -b main https://github.com/immich-app/base-images "$BASE_DIR"
fi

LIBJXL_REVISION="$(jq -cr '.revision' "$BASE_DIR"/server/sources/libjxl.json)"
JPEGLI_REVISION="$(jq -cr '.revision' "$BASE_DIR"/server/sources/jpegli.json)"
IMAGEMAGICK_REVISION="$(jq -cr '.revision' "$BASE_DIR"/server/sources/imagemagick.json)"
LIBVIPS_REVISION="$(jq -cr '.revision' "$BASE_DIR"/server/sources/libvips.json)"

# Return success when the library must be rebuilt
needs_build() {
  [[ "${FORCE_COMPILE:-0}" == 1 ]] && return 0
  [[ "$2" != "$(awk -v l="$1:" '$1 == l {print $2}' "$REVISIONS_FILE")" ]]
}

record() {
  sed -i "/^$1: /d" "$REVISIONS_FILE"
  echo "$1: $2" >>"$REVISIONS_FILE"
  sort -o "$REVISIONS_FILE" "$REVISIONS_FILE"
}

fresh_clone() {
  rm -rf "$2"
  git clone "$1" "$2"
  cd "$2"
  git reset --hard "$3"
}

if needs_build libjxl "$LIBJXL_REVISION"; then
  echo "=== $(date +%T) Compiling libjxl ==="
  SOURCE=${SOURCE_DIR}/libjxl
  fresh_clone https://github.com/libjxl/libjxl.git "$SOURCE" "$LIBJXL_REVISION"
  git submodule update --init --recursive --depth 1 --recommend-shallow
  mkdir build && cd build
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_ENABLE_HWY_AVX3=ON \
    -DJPEGXL_ENABLE_HWY_AVX3_ZEN4=ON \
    -DJPEGXL_ENABLE_HWY_SVE=OFF \
    -DJPEGXL_ENABLE_HWY_SVE2=OFF \
    -DJPEGXL_ENABLE_HWY_SVE2_128=ON \
    -DJPEGXL_ENABLE_PLUGINS=ON \
    ..
  cmake --build . -- -j"$(nproc)"
  cmake --install .
  ldconfig /usr/local/lib
  record libjxl "$LIBJXL_REVISION"
  echo "=== $(date +%T) libjxl done ==="
else
  echo "=== libjxl up to date ==="
fi

if needs_build jpegli "$JPEGLI_REVISION"; then
  echo "=== $(date +%T) Compiling jpegli ==="
  SOURCE=${SOURCE_DIR}/jpegli
  fresh_clone https://github.com/google/jpegli.git "$SOURCE" "$JPEGLI_REVISION"
  git submodule update --init --depth 1 --recommend-shallow third_party/libjpeg-turbo
  git apply -3 "$BASE_DIR"/server/sources/jpegli-patches/jpegli-empty-dht-marker.patch
  git apply -3 "$BASE_DIR"/server/sources/jpegli-patches/jpegli-icc-warning.patch
  mkdir build && cd build
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DJPEGLI_ENABLE_DOXYGEN=OFF \
    -DJPEGLI_ENABLE_MANPAGES=OFF \
    -DJPEGLI_ENABLE_BENCHMARK=OFF \
    -DJPEGLI_ENABLE_TOOLS=OFF \
    -DJPEGLI_ENABLE_DEVTOOLS=OFF \
    -DJPEGLI_ENABLE_FUZZERS=OFF \
    -DJPEGLI_ENABLE_JNI=OFF \
    -DJPEGLI_ENABLE_OPENEXR=OFF \
    -DJPEGLI_ENABLE_SJPEG=OFF \
    -DJPEGLI_ENABLE_SKCMS=OFF \
    -DJPEGLI_FORCE_SYSTEM_HWY=ON \
    -DJPEGLI_FORCE_SYSTEM_LCMS2=ON \
    -DJPEGLI_ENABLE_JPEGLI_LIBJPEG=ON \
    -DJPEGLI_INSTALL_JPEGLI_LIBJPEG=ON \
    -DJPEGLI_ENABLE_HWY_AVX3=ON \
    -DJPEGLI_ENABLE_HWY_AVX3_ZEN4=ON \
    -DJPEGLI_ENABLE_HWY_SVE=OFF \
    -DJPEGLI_ENABLE_HWY_SVE2=OFF \
    -DJPEGLI_ENABLE_HWY_SVE2_128=ON \
    -DJPEGLI_LIBJPEG_LIBRARY_SOVERSION=62 \
    -DJPEGLI_LIBJPEG_LIBRARY_VERSION=62.3.0 \
    -DLIBJPEG_TURBO_VERSION_NUMBER=2001005 \
    ..
  cmake --build . -- -j"$(nproc)"
  cmake --install .
  ldconfig /usr/local/lib
  record jpegli "$JPEGLI_REVISION"
  echo "=== $(date +%T) jpegli done ==="
else
  echo "=== jpegli up to date ==="
fi

if needs_build libheif "$LIBHEIF_REVISION"; then
  echo "=== $(date +%T) Compiling libheif ==="
  SOURCE=${SOURCE_DIR}/libheif
  fresh_clone https://github.com/strukturag/libheif.git "$SOURCE" "$LIBHEIF_REVISION"
  mkdir build && cd build
  cmake --preset=release-noplugins \
    -DWITH_DAV1D=ON \
    -DENABLE_PARALLEL_TILE_DECODING=ON \
    -DWITH_LIBSHARPYUV=ON \
    -DWITH_LIBDE265=ON \
    -DWITH_AOM_DECODER=OFF \
    -DWITH_AOM_ENCODER=ON \
    -DWITH_X265=OFF \
    -DWITH_EXAMPLES=OFF \
    ..
  make install -j"$(nproc)"
  ldconfig /usr/local/lib
  record libheif "$LIBHEIF_REVISION"
  echo "=== $(date +%T) libheif done ==="
else
  echo "=== libheif up to date ==="
fi

if needs_build libraw "$LIBRAW_REVISION"; then
  echo "=== $(date +%T) Compiling libraw ==="
  SOURCE=${SOURCE_DIR}/libraw
  fresh_clone https://github.com/LibRaw/LibRaw.git "$SOURCE" "$LIBRAW_REVISION"
  autoreconf --install
  ./configure --disable-examples
  make -j"$(nproc)"
  make install
  ldconfig /usr/local/lib
  record libraw "$LIBRAW_REVISION"
  echo "=== $(date +%T) libraw done ==="
else
  echo "=== libraw up to date ==="
fi

if needs_build imagemagick "$IMAGEMAGICK_REVISION" ||
  ! grep -q 'DMAGICK_LIBRAW' /usr/local/lib/ImageMagick-7*/config-Q16HDRI/configure.xml 2>/dev/null; then
  echo "=== $(date +%T) Compiling imagemagick ==="
  SOURCE=${SOURCE_DIR}/imagemagick
  fresh_clone https://github.com/ImageMagick/ImageMagick.git "$SOURCE" "$IMAGEMAGICK_REVISION"
  ./configure --with-modules CPPFLAGS="-DMAGICK_LIBRAW_VERSION_TAIL=202502"
  make -j"$(nproc)"
  make install
  ldconfig /usr/local/lib
  record imagemagick "$IMAGEMAGICK_REVISION"
  echo "=== $(date +%T) imagemagick done ==="
else
  echo "=== imagemagick up to date ==="
fi

if needs_build libvips "$LIBVIPS_REVISION"; then
  echo "=== $(date +%T) Compiling libvips ==="
  SOURCE=${SOURCE_DIR}/libvips
  fresh_clone https://github.com/libvips/libvips.git "$SOURCE" "$LIBVIPS_REVISION"
  git apply "$BASE_DIR"/server/sources/libvips-patches/0001-put-other-loaders-ahead-of-dcrawload.patch
  meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled
  cd build
  ninja install
  ldconfig /usr/local/lib
  record libvips "$LIBVIPS_REVISION"
  echo "=== $(date +%T) libvips done ==="
else
  echo "=== libvips up to date ==="
fi

cd /
rm -rf "$SOURCE_DIR"
echo "=== $(date +%T) LIBRARIES COMPLETE ==="
cat "$REVISIONS_FILE"
