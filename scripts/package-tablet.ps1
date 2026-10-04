$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $root "dist"
$output = Join-Path $outputDirectory "xovi-nytcrossword-runtime.zip"

# The runtime archive never contains config.env or state/, so redeploying keeps
# the tablet's existing configuration.
$files = @(
    @{ Path = "scripts\nytcrossword-run.sh"; Mode = 33261 }
    @{ Path = "scripts\nytcrossword-shell.sh"; Mode = 33261 }
    @{ Path = "scripts\nytcrossword-inventory.jq"; Mode = 33188 }
    @{ Path = "config.example.env"; Mode = 33188 }
    @{ Path = "xovi\3.28\nytQuickDownload.qmd"; Mode = 33188 }
)
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file.Path) -PathType Leaf)) {
        throw "Missing runtime file: $($file.Path)"
    }
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($output, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive(
    $stream, [System.IO.Compression.ZipArchiveMode]::Create)
$encoding = New-Object System.Text.UTF8Encoding($false)
try {
    foreach ($file in $files) {
        $entry = $zip.CreateEntry(
            $file.Path.Replace('\', '/'), [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.ExternalAttributes = $file.Mode -shl 16
        $text = [System.IO.File]::ReadAllText((Join-Path $root $file.Path)).Replace("`r`n", "`n")
        $bytes = $encoding.GetBytes($text)
        $destination = $entry.Open()
        try {
            $destination.Write($bytes, 0, $bytes.Length)
        } finally {
            $destination.Dispose()
        }
    }
} finally {
    $zip.Dispose()
    $stream.Dispose()
}

Write-Output "Created $output"
