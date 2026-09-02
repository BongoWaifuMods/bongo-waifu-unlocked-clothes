param([switch]$NoOpen)

$ErrorActionPreference = 'Stop'

$runtimeRoot = Join-Path $PSScriptRoot '.runtime'
$venvPython = Join-Path $runtimeRoot 'Scripts\python.exe'
$requirementsPath = Join-Path $PSScriptRoot 'requirements.txt'
$serverPath = Join-Path $PSScriptRoot 'bongo-preview-server.ps1'

try {
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        Write-Host 'Preparing Bongo Waifu — Unlocked Clothes for the first run...'
        $pythonExecutable = $null
        $pythonPrefix = @()
        if ($env:BONGO_WAIFU_PYTHON -and (Test-Path -LiteralPath $env:BONGO_WAIFU_PYTHON -PathType Leaf)) {
            $pythonExecutable = $env:BONGO_WAIFU_PYTHON
        }
        else {
            $pythonLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
            if ($null -ne $pythonLauncher) {
                & $pythonLauncher.Source -3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $pythonExecutable = $pythonLauncher.Source
                    $pythonPrefix = @('-3')
                }
            }
            if ($null -eq $pythonExecutable) {
                $pythonLauncher = Get-Command python.exe -ErrorAction SilentlyContinue
                if ($null -ne $pythonLauncher) {
                    & $pythonLauncher.Source -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>$null
                    if ($LASTEXITCODE -eq 0) { $pythonExecutable = $pythonLauncher.Source }
                }
            }
        }
        if ($null -eq $pythonExecutable) {
            throw 'Python 3.11 or newer is required. Install it from https://www.python.org/downloads/windows/ and run this file again.'
        }
        & $pythonExecutable @pythonPrefix -m venv $runtimeRoot
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw 'The local Python environment could not be created.'
        }
    }

    & $venvPython -c 'import UnityPy, dncil' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Installing the local dependencies...'
        & $venvPython -m pip install --disable-pip-version-check -r $requirementsPath
        if ($LASTEXITCODE -ne 0) { throw 'The local dependencies could not be installed.' }
    }

    $quotedServer = '"' + $serverPath + '"'
    $serverProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedServer -NoOpen" -WindowStyle Hidden -PassThru

    foreach ($attempt in 1..240) {
        foreach ($port in 54811..54820) {
            try {
                $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status" -TimeoutSec 1
                if ([int]$status.apiVersion -ge 8) {
                    if (-not $NoOpen) { Start-Process "http://127.0.0.1:$port/all-clothes.html" }
                    exit 0
                }
            }
            catch { }
        }
        if ($serverProcess.HasExited) { throw 'The local wardrobe server stopped before opening.' }
        Start-Sleep -Milliseconds 500
    }
    throw 'The local wardrobe took too long to start.'
}
catch {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
