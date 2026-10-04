#!/bin/sh
set -eu

qpdf=$1
work=$(mktemp -d)
trap 'rm -f "$work/one.pdf" "$work/two.pdf"; rmdir "$work"' EXIT

awk 'BEGIN {
    printf "%%PDF-1.4\n"; offset = 9
    objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
    objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    objects[3] = "<< /Type /Page /Parent 2 0 R /Resources << >> /MediaBox [0 0 100 100] >>"
    for (i = 1; i <= 3; i++) {
        offsets[i] = offset
        object = i " 0 obj\n" objects[i] "\nendobj\n"
        printf "%s", object; offset += length(object)
    }
    printf "xref\n0 4\n0000000000 65535 f \n"
    for (i = 1; i <= 3; i++) printf "%010d 00000 n \n", offsets[i]
    printf "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", offset
}' > "$work/one.pdf"

"$qpdf" --check "$work/one.pdf"
"$qpdf" --empty --pages "$work/one.pdf" "$work/one.pdf" -- "$work/two.pdf"
"$qpdf" --check "$work/two.pdf"
test "$("$qpdf" --show-npages "$work/two.pdf")" = 2
echo "PASS: bundled qpdf validates and merges two pages."
