$ErrorActionPreference = 'Stop'

$appName = 'Bongo Waifu — Unlocked Clothes'
$appFolderName = 'Bongo Waifu Unlocked Clothes'
$payloadPath = Join-Path $PSScriptRoot 'payload.zip'
$versionPath = Join-Path $PSScriptRoot 'version.txt'
$testMode = $env:BONGO_WAIFU_INSTALL_TEST -eq '1'

try {
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        throw 'The installer payload is missing.'
    }
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'The installer version is missing.'
    }

    $appVersion = ([System.IO.File]::ReadAllText($versionPath)).Trim()
    if ($appVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'The installer version is invalid.'
    }

    $defaultInstallRoot = Join-Path $env:LOCALAPPDATA "Programs\$appFolderName"
    $requestedInstallRoot = if ([string]::IsNullOrWhiteSpace($env:BONGO_WAIFU_INSTALL_ROOT)) {
        $defaultInstallRoot
    }
    else {
        $env:BONGO_WAIFU_INSTALL_ROOT
    }
    $installRoot = [System.IO.Path]::GetFullPath($requestedInstallRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::GetFileName($installRoot) -ne $appFolderName) {
        throw "The installation folder must end with '$appFolderName'."
    }

    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$installRoot*" -and
            $_.CommandLine -like '*bongo-preview-server.ps1*'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    [System.IO.Directory]::CreateDirectory($installRoot) | Out-Null
    Expand-Archive -LiteralPath $payloadPath -DestinationPath $installRoot -Force

    $launcherPath = Join-Path $installRoot 'Open Bongo Wardrobe.cmd'
    $runtimePath = Join-Path $installRoot 'runtime\python\python.exe'
    $uninstallerPath = Join-Path $installRoot 'Uninstall Bongo Waifu.ps1'
    foreach ($requiredPath in @($launcherPath, $runtimePath, $uninstallerPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "The installed package is incomplete: $requiredPath"
        }
    }

    if (-not $testMode) {
        $shell = New-Object -ComObject WScript.Shell
        $desktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"
        $startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) $appFolderName
        [System.IO.Directory]::CreateDirectory($startMenuFolder) | Out-Null

        foreach ($shortcutPath in @($desktopShortcutPath, (Join-Path $startMenuFolder "$appName.lnk"))) {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $launcherPath
            $shortcut.WorkingDirectory = $installRoot
            $shortcut.Description = 'Open the Bongo Waifu wardrobe'
            $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
            $shortcut.Save()
        }

        $uninstallShortcut = $shell.CreateShortcut((Join-Path $startMenuFolder "Uninstall $appName.lnk"))
        $uninstallShortcut.TargetPath = 'powershell.exe'
        $uninstallShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallerPath`""
        $uninstallShortcut.WorkingDirectory = $installRoot
        $uninstallShortcut.Description = "Uninstall $appName"
        $uninstallShortcut.Save()

        $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BongoWaifuUnlockedClothes'
        New-Item -Path $uninstallKey -Force | Out-Null
        $estimatedSize = [int][Math]::Ceiling(((Get-ChildItem -LiteralPath $installRoot -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB)
        $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallerPath`""
        $quietUninstallCommand = "$uninstallCommand -Quiet"
        $properties = [ordered]@{
            DisplayName = $appName
            DisplayVersion = $appVersion
            Publisher = 'BongoWaifuMods'
            InstallLocation = $installRoot
            UninstallString = $uninstallCommand
            QuietUninstallString = $quietUninstallCommand
            URLInfoAbout = 'https://github.com/BongoWaifuMods/bongo-waifu-unlocked-clothes'
            DisplayIcon = "$env:SystemRoot\System32\shell32.dll,14"
            InstallDate = (Get-Date -Format 'yyyyMMdd')
            EstimatedSize = $estimatedSize
            NoModify = 1
            NoRepair = 1
        }
        foreach ($entry in $properties.GetEnumerator()) {
            $propertyType = if ($entry.Value -is [int]) { 'DWord' } else { 'String' }
            New-ItemProperty -Path $uninstallKey -Name $entry.Key -Value $entry.Value -PropertyType $propertyType -Force | Out-Null
        }
    }

    if ($env:BONGO_WAIFU_NO_LAUNCH -ne '1') {
        Start-Process -FilePath $launcherPath -WorkingDirectory $installRoot | Out-Null
    }
}
catch {
    if (-not $testMode) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            "$appName installation failed",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
    exit 1
}
