<#
.SYNOPSIS
Deploys the xovi-nytcrossword runtime and AppLoad app to a reMarkable.

.EXAMPLE
.\scripts\update-remarkable.ps1 -TargetHost remarkable.local

.EXAMPLE
.\scripts\update-remarkable.ps1 -TargetHost remarkable.local -User root
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHost,
    [string]$User = "root",
    [string]$RuntimeDirectory = "/home/root/xovi-nytcrossword",
    [string]$AppLoadDirectory = "/home/root/xovi/exthome/appload",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

$root = Split-Path -Parent $PSScriptRoot
$runtimePackage = Join-Path $root "dist\xovi-nytcrossword-runtime.zip"
$appLoadPackage = Join-Path $root "dist\xovi-nytcrossword-appload-app.zip"

Require-Command ssh
Require-Command scp
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "package-tablet.ps1")
    & (Join-Path $PSScriptRoot "package-xovi-appload.ps1")
}
foreach ($package in @($runtimePackage, $appLoadPackage)) {
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "Missing package: $package. Run the package scripts or omit -SkipBuild."
    }
}

$destination = "$User@$TargetHost"
$remoteStaging = "/tmp/nytcrossword-update-$PID"
$remoteScript = Join-Path ([System.IO.Path]::GetTempPath()) "nytcrossword-update-$PID.sh"
$remoteScriptContent = @'
#!/bin/sh
set -eu

stage=$1
runtime=$2
appload=$3

cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

test -f "$stage/xovi-nytcrossword-runtime.zip"
test -f "$stage/xovi-nytcrossword-appload-app.zip"
command -v unzip >/dev/null

mkdir -p "$runtime" "$appload"
# The runtime archive deliberately contains no config.env or state.
unzip -oq "$stage/xovi-nytcrossword-runtime.zip" -d "$runtime"
chmod 755 "$runtime/scripts/"*.sh

rm -rf "$stage/appload"
mkdir -p "$stage/appload"
unzip -oq "$stage/xovi-nytcrossword-appload-app.zip" -d "$stage/appload"
test -s "$stage/appload/nyt-crossword/manifest.json"
test -s "$stage/appload/nyt-crossword/resources.rcc"
test -s "$stage/appload/nyt-crossword/icon.png"
rm -rf "$appload/nyt-crossword"
cp -R "$stage/appload/nyt-crossword" "$appload/nyt-crossword"

test -x "$runtime/scripts/nytcrossword-run.sh"
test -s "$appload/nyt-crossword/resources.rcc"
printf '%s\n' "Updated NYT Crossword runtime and AppLoad app."
'@

try {
    [System.IO.File]::WriteAllText(
        $remoteScript, $remoteScriptContent.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    & ssh $destination "mkdir -p '$remoteStaging'"
    if ($LASTEXITCODE -ne 0) { throw "Could not create remote staging directory." }

    & scp $runtimePackage $appLoadPackage $remoteScript "${destination}:${remoteStaging}/"
    if ($LASTEXITCODE -ne 0) { throw "Package transfer failed." }

    & ssh $destination "sh '$remoteStaging/nytcrossword-update-$PID.sh' '$remoteStaging' '$RuntimeDirectory' '$AppLoadDirectory'"
    if ($LASTEXITCODE -ne 0) { throw "Remote update failed; existing config.env and state were not targeted." }
} finally {
    if (Test-Path -LiteralPath $remoteScript) {
        Remove-Item -LiteralPath $remoteScript -Force
    }
}

Write-Output "Update complete. Restart or refresh AppLoad so it rescans applications."
