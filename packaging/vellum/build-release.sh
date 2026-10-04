#!/bin/sh
set -eu

root=$1
work=$2
commit=$3
version=$4
qpdf_ver=12.4.2
zlib_ver=1.3.1
jpeg_ver=3.1.3
musl_ver=1.2.5
gcc_ver=15.2.0

test "$(uname -m)" = aarch64
test "$(gcc -dumpfullversion)" = "$gcc_ver"
apk info -v | grep -q "^musl-$musl_ver-r"
mkdir -p "$work/sources"
cd "$work/sources"

fetch() {
    if [ ! -f "$1" ]; then
        curl --fail --location --retry 3 --output "$1.partial" "$2"
        mv "$1.partial" "$1"
    fi
}

fetch "qpdf-$qpdf_ver.tar.gz" "https://github.com/qpdf/qpdf/releases/download/v$qpdf_ver/qpdf-$qpdf_ver.tar.gz"
fetch "zlib-$zlib_ver.tar.gz" "https://zlib.net/fossils/zlib-$zlib_ver.tar.gz"
fetch "libjpeg-turbo-$jpeg_ver.tar.gz" "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$jpeg_ver/libjpeg-turbo-$jpeg_ver.tar.gz"
fetch "musl-$musl_ver.tar.gz" "https://musl.libc.org/releases/musl-$musl_ver.tar.gz"
fetch gcc-COPYING3 "https://raw.githubusercontent.com/gcc-mirror/gcc/releases/gcc-$gcc_ver/COPYING3"
fetch gcc-COPYING.RUNTIME "https://raw.githubusercontent.com/gcc-mirror/gcc/releases/gcc-$gcc_ver/COPYING.RUNTIME"
sha512sum -c "$root/packaging/vellum/source-sha512sums"
cp "$root/packaging/vellum/source-sha512sums" "$work/source-checksums.txt"
for archive in ./*.tar.gz; do
    if [ ! -d "${archive%.tar.gz}" ]; then
        tar -xzf "$archive"
    fi
done
sh "$root/scripts/build-vellum.sh" "$work/sources" "$qpdf_ver" "$zlib_ver" "$jpeg_ver"

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
chmod 755 "$stage"
runtime="$stage/home/root/xovi-nytcrossword"
app="$stage/home/root/xovi/exthome/appload/nyt-crossword"
licenses="$stage/home/root/.vellum/licenses/xovi-nytcrossword"
cd "$root"
install -Dm755 scripts/nytcrossword-run.sh "$runtime/scripts/nytcrossword-run.sh"
install -Dm755 scripts/nytcrossword-shell.sh "$runtime/scripts/nytcrossword-shell.sh"
install -Dm644 scripts/nytcrossword-inventory.jq "$runtime/scripts/nytcrossword-inventory.jq"
install -Dm644 config.example.env "$runtime/config.example.env"
install -Dm755 "$work/sources/qpdf-build/qpdf/qpdf" "$runtime/tools/bin/qpdf"
install -Dm644 xovi/appload/nyt-crossword/manifest.json "$app/manifest.json"
install -Dm644 xovi/appload/nyt-crossword/icon.png "$app/icon.png"
install -Dm644 "$work/sources/resources.rcc" "$app/resources.rcc"
install -Dm644 LICENSE "$app/LICENSE"
install -Dm644 LICENSE "$runtime/LICENSE"
install -Dm644 README.md "$runtime/README.md"
install -Dm644 xovi/3.28/nytQuickDownload.qmd "$stage/home/root/xovi/exthome/qt-resource-rebuilder/nytQuickDownload.qmd"
install -Dm644 LICENSE "$licenses/LICENSE"
install -Dm644 "$work/sources/qpdf-$qpdf_ver/LICENSE.txt" "$licenses/qpdf/LICENSE.txt"
install -Dm644 "$work/sources/qpdf-$qpdf_ver/NOTICE.md" "$licenses/qpdf/NOTICE.md"
install -Dm644 "$work/sources/zlib-$zlib_ver/LICENSE" "$licenses/zlib/LICENSE"
install -Dm644 "$work/sources/libjpeg-turbo-$jpeg_ver/LICENSE.md" "$licenses/libjpeg-turbo/LICENSE.md"
install -Dm644 "$work/sources/libjpeg-turbo-$jpeg_ver/README.ijg" "$licenses/libjpeg-turbo/README.ijg"
install -Dm644 "$work/sources/musl-$musl_ver/COPYRIGHT" "$licenses/musl/COPYRIGHT"
install -Dm644 "$work/sources/gcc-COPYING3" "$licenses/gcc/COPYING3"
install -Dm644 "$work/sources/gcc-COPYING.RUNTIME" "$licenses/gcc/COPYING.RUNTIME"
install -Dm644 "$work/source-checksums.txt" "$licenses/source-checksums.txt"
printf '%s\n' \
    "https://github.com/cchrysostomou/xovi-nytcrossword/archive/$commit.tar.gz" \
    "https://github.com/qpdf/qpdf/releases/download/v$qpdf_ver/qpdf-$qpdf_ver.tar.gz" \
    "https://zlib.net/fossils/zlib-$zlib_ver.tar.gz" \
    "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$jpeg_ver/libjpeg-turbo-$jpeg_ver.tar.gz" \
    "https://musl.libc.org/releases/musl-$musl_ver.tar.gz" \
    "https://gcc.gnu.org/pub/gcc/releases/gcc-$gcc_ver/gcc-$gcc_ver.tar.xz" \
    > "$licenses/SOURCES"
printf 'app_version=%s\napp_commit=%s\nqpdf_version=%s\n' "$version" "$commit" "$qpdf_ver" \
    > "$licenses/BUILD"
apk info -v >> "$licenses/BUILD"
test ! -e "$runtime/config.env"
test ! -e "$runtime/state"
tar -czf "$work/xovi-nytcrossword-$version-aarch64.tar.gz" -C "$stage" home
echo "Created Vellum release archive for aarch64."
