[CmdletBinding()]
param(
    [string]$Archive = (Join-Path (Split-Path -Parent $PSScriptRoot) "dist\vellum\xovi-nytcrossword-0.3.0-aarch64.tar.gz")
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    throw "Vellum release archive not found: $Archive"
}
$entries = & tar -tzf $Archive
if ($LASTEXITCODE -ne 0) { throw "Could not list the Vellum release archive." }
$files = @($entries | Where-Object { -not $_.EndsWith("/") })
$runtime = "home/root/xovi-nytcrossword"
$app = "home/root/xovi/exthome/appload/nyt-crossword"
$licenses = "home/root/.vellum/licenses/xovi-nytcrossword"
$expected = @(
    "$runtime/scripts/nytcrossword-run.sh",
    "$runtime/scripts/nytcrossword-shell.sh",
    "$runtime/scripts/nytcrossword-inventory.jq",
    "$runtime/config.example.env",
    "$runtime/tools/bin/qpdf",
    "$runtime/LICENSE",
    "$runtime/README.md",
    "$app/manifest.json", "$app/icon.png", "$app/resources.rcc", "$app/LICENSE",
    "home/root/xovi/exthome/qt-resource-rebuilder/nytQuickDownload.qmd",
    "$licenses/LICENSE", "$licenses/SOURCES", "$licenses/BUILD",
    "$licenses/source-checksums.txt",
    "$licenses/qpdf/LICENSE.txt", "$licenses/qpdf/NOTICE.md",
    "$licenses/zlib/LICENSE",
    "$licenses/libjpeg-turbo/LICENSE.md", "$licenses/libjpeg-turbo/README.ijg",
    "$licenses/musl/COPYRIGHT", "$licenses/gcc/COPYING3", "$licenses/gcc/COPYING.RUNTIME"
)
$differences = Compare-Object $expected $files
if ($differences) {
    throw "Unexpected or missing archive files: $($differences | Out-String)"
}
if ($files.Count -ne $expected.Count) { throw "Duplicate file entries in release archive." }
$listing = & tar -tvzf $Archive
if ($LASTEXITCODE -ne 0) { throw "Could not read archive permissions." }
foreach ($line in $listing) {
    if ($line -notmatch '^(drwxr-xr-x|-rw-r--r--|-rwxr-xr-x)\s') {
        throw "Unsafe or unexpected archive permissions/type: $line"
    }
}
$checksum = (Get-FileHash -Algorithm SHA512 -LiteralPath $Archive).Hash.ToLowerInvariant()
Write-Output "PASS: $($files.Count) expected files; private config/state and NYT documents excluded."
Write-Output "SHA512: $checksum"
