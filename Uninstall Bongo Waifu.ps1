[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$appName = 'Bongo Waifu — Unlocked Clothes'
$appFolderName = 'Bongo Waifu Unlocked Clothes'
$installRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

if ([System.IO.Path]::GetFileName($installRoot) -ne $appFolderName) {
    throw 'The uninstall location is invalid. No files were removed.'
}

if (-not $Quiet) {
    Add-Type -AssemblyName PresentationFramework
    $message = "This removes only $appName.`n`nIf a look is currently applied, cancel now and use Options > Restore first. The uninstaller does not modify or delete the game backups.`n`nContinue?"
    $choice = [System.Windows.MessageBox]::Show(
        $message,
        "Uninstall $appName",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { exit 0 }
}

try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$installRoot*" -and
            $_.CommandLine -like '*bongo-preview-server.ps1*'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    if ($env:BONGO_WAIFU_INSTALL_TEST -ne '1') {
        $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"
        $startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) $appFolderName
        if (Test-Path -LiteralPath $desktopShortcut -PathType Leaf) {
            Remove-Item -LiteralPath $desktopShortcut -Force
        }
        if (Test-Path -LiteralPath $startMenuFolder -PathType Container) {
            Remove-Item -LiteralPath $startMenuFolder -Recurse -Force
        }
        $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BongoWaifuUnlockedClothes'
        if (Test-Path -LiteralPath $uninstallKey) {
            Remove-Item -LiteralPath $uninstallKey -Recurse -Force
        }
    }

    $escapedRoot = $installRoot.Replace("'", "''")
    $cleanupCommand = "Start-Sleep -Seconds 2; if (Test-Path -LiteralPath '$escapedRoot') { Remove-Item -LiteralPath '$escapedRoot' -Recurse -Force }"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand', $encodedCommand
    ) -WindowStyle Hidden | Out-Null
}
catch {
    if (-not $Quiet) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            "Could not uninstall $appName",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
    exit 1
}
