#!/bin/sh
set -eu

srcdir=$1
qpdf_ver=$2
zlib_ver=$3
jpeg_ver=$4
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix="$srcdir/static-deps"

cd "$srcdir/zlib-$zlib_ver"
./configure --static --prefix="$prefix"
make -j4
make install

cmake -S "$srcdir/libjpeg-turbo-$jpeg_ver" -B "$srcdir/jpeg-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF \
    -DWITH_SIMD=OFF
cmake --build "$srcdir/jpeg-build" --parallel 4
cmake --install "$srcdir/jpeg-build"

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
cmake -S "$srcdir/qpdf-$qpdf_ver" -B "$srcdir/qpdf-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_EXE_LINKER_FLAGS=-static \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF \
    -DSTATIC_JPEG=ON -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON
cmake --build "$srcdir/qpdf-build" --target qpdf --parallel 4
strip "$srcdir/qpdf-build/qpdf/qpdf"
binary="$srcdir/qpdf-build/qpdf/qpdf"
file "$binary"
if readelf -l "$binary" | grep -q INTERP ||
        readelf -d "$binary" | grep -q NEEDED; then
    echo "Bundled qpdf must not require a dynamic loader or shared libraries." >&2
    exit 1
fi
sh "$root/packaging/vellum/smoke-test.sh" "$srcdir/qpdf-build/qpdf/qpdf"

/usr/lib/qt6/libexec/rcc --format-version 2 --binary \
    -o "$srcdir/resources.rcc" "$root/xovi/appload/nyt-crossword/application.qrc"
test -s "$srcdir/resources.rcc"
