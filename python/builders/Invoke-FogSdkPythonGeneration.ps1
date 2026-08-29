<#
.SYNOPSIS
    Generate the Python client from the committed OpenAPI snapshot.

.DESCRIPTION
    Pins the generator version, because the generated surface is not committed
    and an unpinned run is the one thing that can change the shipped package
    without changing a tracked file.

    Rough draft. openapi-generator's Python output is a working urllib3 client
    and nothing more -- it has no FOG-specific naming, no credential handling,
    and no opinion about how anyone would want to use it. Those come later, if
    at all.

.PARAMETER Document
    The OpenAPI document. Defaults to the committed snapshot.

.PARAMETER OutputFolder
    Where to write the client. Defaults to python/src, which is gitignored.

.PARAMETER GeneratorVersion
    The openapi-generator version, pinned. 7.25.0 is what the generator
    comparison on FogApi's spike/generator-comparison branch was measured
    against, so its recorded findings apply to this output.

    NOTE this is NOT the npm package version. @openapitools/openapi-generator-cli
    is a thin wrapper versioned separately (2.x) that downloads the generator
    JAR itself; pinning the npm package to 7.25.0 fails with ETARGET because no
    such npm version exists. The generator version is selected with the
    OPENAPI_GENERATOR_VERSION environment variable.

.PARAMETER CliVersion
    The npm wrapper version, pinned for the same reason the generator is.
#>
[CmdletBinding()]
param(
    [string]$Document,
    [string]$OutputFolder,
    [string]$GeneratorVersion = '7.25.0',
    [string]$CliVersion = '2.41.0'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Document)     { $Document     = Join-Path $repoRoot 'spec/openapi/fog-1.6.json' }
if (-not $OutputFolder) { $OutputFolder = Join-Path $repoRoot 'python/src' }
$config = Join-Path $repoRoot 'spec/generators/openapi-generator-config.json'

foreach ($p in @($Document, $config)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}
if (-not (Get-Command npx -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'npx not found. Node is required to run openapi-generator.'
}
# openapi-generator is a Java program; the npm package only wraps it.
if (-not (Get-Command java -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'java not found. openapi-generator is a JAR, so a JRE is required -- this is the one hard prerequisite the PowerShell client does not share.'
}

Write-Host "openapi-generator $GeneratorVersion (cli $CliVersion)" -ForegroundColor DarkGray
Write-Host "  document : $Document" -ForegroundColor DarkGray
Write-Host "  output   : $OutputFolder" -ForegroundColor DarkGray

# The README this folder replaces is preserved: python/src/ is gitignored except
# for its README, which explains what the folder is to anyone who checks out the
# repo without running a build.
$readme = Join-Path $OutputFolder 'README.md'
$keep = if (Test-Path -LiteralPath $readme) { Get-Content -Raw -LiteralPath $readme } else { $null }

$log = Join-Path ([System.IO.Path]::GetTempPath()) "fogsdk-python-generate.log"

$env:OPENAPI_GENERATOR_VERSION = $GeneratorVersion
& npx -y "@openapitools/openapi-generator-cli@$CliVersion" generate `
    -i $Document `
    -g python `
    -o $OutputFolder `
    -c $config `
    *>&1 | Tee-Object -FilePath $log

# openapi-generator DOES set a useful exit code, unlike AutoRest's
# build-module.ps1 -- but check for the artifact anyway. A generator that
# reports success and produced nothing has happened in this repo before.
$pkg = Join-Path $OutputFolder 'fogsdk/__init__.py'
if (-not (Test-Path -LiteralPath $pkg)) {
    throw "No package at $pkg. Generation reported exit $LASTEXITCODE but produced nothing usable. Log: $log"
}

if ($keep) { Set-Content -LiteralPath $readme -Value $keep -NoNewline }

$apis   = @(Get-ChildItem -Path (Join-Path $OutputFolder 'fogsdk/api')   -Filter *.py -EA SilentlyContinue)
$models = @(Get-ChildItem -Path (Join-Path $OutputFolder 'fogsdk/models') -Filter *.py -EA SilentlyContinue)

Write-Host ''
Write-Host "  api modules   : $($apis.Count)"   -ForegroundColor Green
Write-Host "  model modules : $($models.Count)" -ForegroundColor Green
Write-Host "  log           : $log"             -ForegroundColor DarkGray
