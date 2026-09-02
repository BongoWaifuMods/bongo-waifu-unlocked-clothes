param([switch]$NoOpen)

$ErrorActionPreference = 'Stop'

$pythonPath = Join-Path $PSScriptRoot 'runtime\python\python.exe'
$serverPath = Join-Path $PSScriptRoot 'bongo-preview-server.ps1'

try {
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw 'The bundled application runtime is missing. Reinstall Bongo Waifu — Unlocked Clothes using the latest setup file.'
    }
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw 'The local wardrobe server is missing. Reinstall the application.'
    }
    & $pythonPath -c 'import UnityPy, dncil, dnfile, TypeTreeGeneratorAPI' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The bundled application runtime is incomplete. Reinstall the application.'
    }

    $quotedServer = '"' + $serverPath + '"'
    $serverProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedServer -NoOpen" -WindowStyle Hidden -PassThru

    foreach ($attempt in 1..240) {
        foreach ($port in 54811..54820) {
            try {
                $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status" -TimeoutSec 5
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
