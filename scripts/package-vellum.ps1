[CmdletBinding(DefaultParameterSetName = "Release")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Release")]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Commit,
    [Parameter(Mandatory = $true, ParameterSetName = "Local")]
    [switch]$Local,
    [string]$OutputDirectory,
    [ValidateNotNullOrEmpty()]
    [string]$ContainerCommand = "docker"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$version = "0.3.0"
if ($OutputDirectory) {
    $work = [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    $work = Join-Path $root "dist\vellum"
}
$source = Join-Path $work "app-source"
$recipeDirectory = Join-Path $work "packages\xovi-nytcrossword"
$archiveName = "xovi-nytcrossword-$version-aarch64.tar.gz"
$archive = Join-Path $work $archiveName

if (-not (Get-Command $ContainerCommand -ErrorAction SilentlyContinue)) {
    throw "Container command not found: $ContainerCommand"
}
if (Test-Path -LiteralPath $source) {
    throw "Build source already exists at $source. Use a fresh dist\vellum directory after reviewing previous output."
}
New-Item -ItemType Directory -Force -Path $source, $recipeDirectory | Out-Null
if ($Local) {
    $sourceCommit = "local"
    foreach ($path in @("LICENSE", "README.md", "config.example.env", "scripts\build-vellum.sh",
            "scripts\nytcrossword-run.sh", "scripts\nytcrossword-shell.sh",
            "scripts\nytcrossword-inventory.jq", "packaging\vellum", "xovi")) {
        $destination = Join-Path $source $path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $path) -Destination $destination -Recurse
    }
} else {
    $sourceCommit = $Commit
    $sourceArchive = Join-Path $work "app-$Commit.tar.gz"
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/cchrysostomou/xovi-nytcrossword/archive/$Commit.tar.gz" -OutFile $sourceArchive
    & tar -xzf $sourceArchive --strip-components=1 -C $source
    if ($LASTEXITCODE -ne 0) { throw "Could not unpack the published source." }
}
foreach ($required in @("LICENSE", "scripts\build-vellum.sh", "packaging\vellum\build-release.sh")) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required))) {
        throw "Source is missing $required. Publish the packaging changes before building a release."
    }
}
Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object {
    $_.Extension -in @(".sh", ".qml", ".qmd", ".qrc", ".jq", ".json", ".env", ".md", ".in") -or
        $_.Name -in @("LICENSE", "Dockerfile", "source-sha512sums")
} | ForEach-Object {
    $text = [System.IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($_.FullName, $text, [System.Text.UTF8Encoding]::new($false))
}
$backendVersion = [regex]::Match(
    [System.IO.File]::ReadAllText((Join-Path $source "scripts\nytcrossword-shell.sh")),
    '(?m)^VERSION="([^"]+)"').Groups[1].Value
if ($backendVersion -ne $version) { throw "Backend version $backendVersion does not match package version $version." }
$buildImage = "xovi-nytcrossword-vellum-build:alpine3.23"
& $ContainerCommand build --platform linux/arm64 --tag $buildImage (Join-Path $source "packaging\vellum")
if ($LASTEXITCODE -ne 0) { throw "Could not prepare the ARM64 build image." }
& $ContainerCommand run --rm --platform linux/arm64 `
    --mount "type=bind,source=$source,target=/app,readonly" `
    --mount "type=bind,source=$work,target=/output" `
    $buildImage sh /app/packaging/vellum/build-release.sh /app /output $sourceCommit $version
if ($LASTEXITCODE -ne 0) { throw "Vellum release build failed." }
if (-not (Test-Path -LiteralPath $archive)) { throw "Release archive was not created." }
& (Join-Path $PSScriptRoot "verify-vellum-package.ps1") -Archive $archive

$checksum = (Get-FileHash -Algorithm SHA512 -LiteralPath $archive).Hash.ToLowerInvariant()
$template = [System.IO.File]::ReadAllText((Join-Path $source "packaging\vellum\xovi-nytcrossword\VELBUILD.in"))
if ($Local) {
    Copy-Item -LiteralPath $archive -Destination (Join-Path $recipeDirectory $archiveName)
    $packageSource = $archiveName
} else {
    $packageSource = "https://github.com/cchrysostomou/xovi-nytcrossword/releases/download/v$version/$archiveName"
}
$recipe = $template.Replace("@COMMIT@", $sourceCommit).Replace("@SOURCE@", $packageSource).Replace("@CHECKSUM@", $checksum)
if ($Local) {
    $recipe = $recipe -replace '(?m)^readmeurl=.*\r?\n', ''
}
[System.IO.File]::WriteAllText((Join-Path $recipeDirectory "VELBUILD"),
    $recipe.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Output "Created $archive"
Write-Output "Created $(Join-Path $recipeDirectory 'VELBUILD')"
if ($Local) {
    Write-Warning "LOCAL TEST ONLY: this recipe and archive are not for submission or publication."
} else {
    Write-Output "Upload the archive to the v$version release before submitting the Vellum recipe."
}
