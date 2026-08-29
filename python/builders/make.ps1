<#
.SYNOPSIS
    Build orchestrator for the Python client.

.DESCRIPTION
    Called by the repo-root make.ps1 as `./make.ps1 -Client python`, and
    runnable on its own. Its presence here is what makes the root dispatcher
    treat python/ as buildable rather than as scaffolding.

    Deliberately thin. The Python client is a rough draft: generate, then check
    the result imports. There is no compile step -- that is the whole shape
    difference from the PowerShell client, which needs a 12-minute
    generate-and-compile before anything can be run at all.

.PARAMETER Target
    One stage, or all of them in order. Stages: Generate, Verify.

.PARAMETER Help
    List the stages and exit.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Generate', 'Restore', 'Verify')]
    [string]$Target = 'All',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$stages = [ordered]@{
    Generate = 'Generate the client from the committed snapshot'
    Restore  = 'Create a repo-local venv and install the generated requirements'
    Verify   = 'Import every generated module and count the surface'
}

if ($Help) {
    Write-Host 'Stages:' -ForegroundColor Cyan
    $stages.GetEnumerator() | ForEach-Object { '  {0,-10} {1}' -f $_.Key, $_.Value }
    return
}

$repoRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outFolder = Join-Path $repoRoot 'python/src'
$venv      = Join-Path $repoRoot 'python/.venv'
$venvPython = if ($IsWindows -or $null -eq $IsWindows) {
    Join-Path $venv 'Scripts/python.exe'
} else {
    Join-Path $venv 'bin/python'
}

$run = if ($Target -eq 'All') { @($stages.Keys) } else { @($Target) }
$i = 0

foreach ($stage in $run) {
    $i++
    Write-Host ''
    Write-Host "[$i] $stage" -ForegroundColor Cyan

    switch ($stage) {
        'Generate' {
            & (Join-Path $PSScriptRoot 'Invoke-FogSdkPythonGeneration.ps1')
        }
        'Restore' {
            # A repo-local venv, never the user's global site-packages. The
            # generated client pulls pydantic, urllib3, python-dateutil and
            # typing-extensions, and installing those globally to run a build
            # would be a rude side effect of ./make.ps1.
            if (-not (Test-Path -LiteralPath $venv)) {
                & python -m venv $venv
                if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)." }
            }
            $req = Join-Path $outFolder 'requirements.txt'
            if (-not (Test-Path -LiteralPath $req)) { throw "No requirements.txt at $req. Run the Generate stage first." }
            & $venvPython -m pip install --quiet --disable-pip-version-check -r $req
            if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)." }

            # The credential layer's own dependencies, which the generated
            # client knows nothing about. keyring matters more than it looks:
            # without it the Python side falls back to the file tier while
            # PowerShell uses Credential Manager, and the two stop sharing a
            # store without saying so.
            $authReq = Join-Path $repoRoot 'python/fogsdk_auth/requirements.txt'
            if (Test-Path -LiteralPath $authReq) {
                & $venvPython -m pip install --quiet --disable-pip-version-check -r $authReq
                if ($LASTEXITCODE -ne 0) { throw "pip install (fogsdk_auth) failed (exit $LASTEXITCODE)." }
            }
            Write-Host "  venv ready: $venv" -ForegroundColor DarkGray
        }
        'Verify' {
            if (-not (Test-Path -LiteralPath $venvPython)) {
                throw "No venv at $venv. Run the Restore stage first."
            }
            # Import the generated package rather than trusting that files
            # exist. openapi-generator can emit a tree that does not import --
            # a name collision or a bad enum is enough -- and counting .py
            # files would not notice.
            $probe = Join-Path ([System.IO.Path]::GetTempPath()) "fogsdk-verify-$PID.py"
            @"
import sys
sys.path.insert(0, r'$outFolder')
import pkgutil
import fogsdk
import fogsdk.api as _api
import fogsdk.models as _models

apis = [m.name for m in pkgutil.iter_modules(_api.__path__)]
models = [m.name for m in pkgutil.iter_modules(_models.__path__)]

# Importing every api module, not just the package, is the point: a name
# collision or a bad enum shows up here and would not show up in a file count.
failed = []
for name in apis:
    try:
        __import__('fogsdk.api.' + name)
    except Exception as exc:
        failed.append((name, type(exc).__name__ + ': ' + str(exc)))

print('  imported      : fogsdk', getattr(fogsdk, '__version__', ''))
print('  api modules   :', len(apis))
print('  model modules :', len(models))
if failed:
    print('  FAILED to import:', len(failed))
    for name, err in failed[:5]:
        print('    ', name, '->', err)
    raise SystemExit(1)
"@ | Set-Content -LiteralPath $probe -Encoding utf8
            try {
                & $venvPython $probe
                if ($LASTEXITCODE -ne 0) { throw "The generated package does not import (exit $LASTEXITCODE)." }
            } finally {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host ''
Write-Host 'done' -ForegroundColor Green
