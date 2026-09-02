[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.1.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$buildParent = Join-Path $projectRoot '.build'
$buildRoot = Join-Path $buildParent "installer-$Version"
$downloadRoot = Join-Path $buildParent 'downloads'
$distRoot = Join-Path $projectRoot 'dist'
$appStage = Join-Path $buildRoot 'app'
$bundleStage = Join-Path $buildRoot 'bundle'
$pythonRoot = Join-Path $appStage 'runtime\python'
$installerPath = Join-Path $distRoot 'BongoWaifu-Unlocked-Clothes-Setup.exe'

function Assert-ChildPath([string]$Path, [string]$Parent) {
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $resolvedParent + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe build path: $resolvedPath"
    }
    return $resolvedPath
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

function Get-VerifiedDownload(
    [string]$Uri,
    [string]$Destination,
    [string]$ExpectedSha256
) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    }
    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "Download verification failed for $Destination. Expected $ExpectedSha256, received $actualHash."
    }
}

[System.IO.Directory]::CreateDirectory($buildParent) | Out-Null
[System.IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($distRoot) | Out-Null

$safeBuildRoot = Assert-ChildPath $buildRoot $buildParent
if (Test-Path -LiteralPath $safeBuildRoot -PathType Container) {
    Remove-Item -LiteralPath $safeBuildRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($appStage) | Out-Null
[System.IO.Directory]::CreateDirectory($bundleStage) | Out-Null

$rootFiles = @(
    'README.md',
    'Open Bongo Wardrobe.cmd',
    'Open Bongo Wardrobe.ps1',
    'Uninstall Bongo Waifu.ps1',
    'bongo-preview-server.ps1',
    'bongo-native-apply.py',
    'bongo-preload-assets.py'
)
foreach ($relativeFile in $rootFiles) {
    $sourcePath = Join-Path $projectRoot $relativeFile
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required source file not found: $relativeFile"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $appStage $relativeFile)
}

$trackedPaths = @(& git -C $projectRoot ls-files -- 'bongo-waifu-clothes-preview' 'runtime/bongo-spine-assets' 'runtime/bongo-spine-skin-mapping.json')
if ($LASTEXITCODE -ne 0 -or $trackedPaths.Count -lt 1) {
    throw 'Could not read the tracked application assets from Git.'
}
foreach ($relativeFile in $trackedPaths) {
    $windowsRelativePath = $relativeFile.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $sourcePath = Join-Path $projectRoot $windowsRelativePath
    $destinationPath = Join-Path $appStage $windowsRelativePath
    [System.IO.Directory]::CreateDirectory((Split-Path $destinationPath -Parent)) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}
[System.IO.File]::WriteAllText((Join-Path $appStage 'VERSION.txt'), $Version, [System.Text.UTF8Encoding]::new($false))

$pythonVersion = '3.12.10'
$pythonArchive = Join-Path $downloadRoot "python-$pythonVersion-embed-amd64.zip"
$getPipPath = Join-Path $downloadRoot 'get-pip.py'
Get-VerifiedDownload `
    -Uri "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip" `
    -Destination $pythonArchive `
    -ExpectedSha256 '4ACBED6DD1C744B0376E3B1CF57CE906F9DC9E95E68824584C8099A63025A3C3'
Get-VerifiedDownload `
    -Uri 'https://bootstrap.pypa.io/get-pip.py' `
    -Destination $getPipPath `
    -ExpectedSha256 'FB24E693BAB954209A063D90953621412CCAD4A500905A726286E038F508DDF6'

[System.IO.Directory]::CreateDirectory($pythonRoot) | Out-Null
Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force
$pthPath = Join-Path $pythonRoot 'python312._pth'
@('python312.zip', '.', 'Lib\site-packages', 'import site') |
    Set-Content -LiteralPath $pthPath -Encoding ascii

$embeddedPython = Join-Path $pythonRoot 'python.exe'
Invoke-Checked $embeddedPython @($getPipPath, '--no-warn-script-location')
Invoke-Checked $embeddedPython @(
    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
    '--no-warn-script-location', 'setuptools', 'wheel'
)
Invoke-Checked $embeddedPython @(
    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
    '--no-warn-script-location', '--no-build-isolation', '-r', (Join-Path $projectRoot 'requirements.txt')
)

$sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
foreach ($directoryName in @('pip', 'setuptools', 'wheel', 'packaging', '_distutils_hack')) {
    $directoryPath = Assert-ChildPath (Join-Path $sitePackages $directoryName) $pythonRoot
    if (Test-Path -LiteralPath $directoryPath -PathType Container) {
        Remove-Item -LiteralPath $directoryPath -Recurse -Force
    }
}
foreach ($metadataDirectory in @(Get-ChildItem -LiteralPath $sitePackages -Directory | Where-Object {
    $_.Name -match '^(pip|setuptools|wheel|packaging)-.*\.dist-info$'
})) {
    $metadataPath = Assert-ChildPath $metadataDirectory.FullName $pythonRoot
    Remove-Item -LiteralPath $metadataPath -Recurse -Force
}
$distutilsPath = Join-Path $sitePackages 'distutils-precedence.pth'
if (Test-Path -LiteralPath $distutilsPath -PathType Leaf) {
    Remove-Item -LiteralPath $distutilsPath -Force
}
$scriptsPath = Assert-ChildPath (Join-Path $pythonRoot 'Scripts') $pythonRoot
if (Test-Path -LiteralPath $scriptsPath -PathType Container) {
    Remove-Item -LiteralPath $scriptsPath -Recurse -Force
}
foreach ($cacheDirectory in @(Get-ChildItem -LiteralPath $pythonRoot -Directory -Recurse -Filter '__pycache__')) {
    $cachePath = Assert-ChildPath $cacheDirectory.FullName $pythonRoot
    Remove-Item -LiteralPath $cachePath -Recurse -Force
}

Invoke-Checked $embeddedPython @(
    '-c',
    'import UnityPy, dncil, dnfile, PIL, TypeTreeGeneratorAPI; print(1)'
)
Invoke-Checked $embeddedPython @((Join-Path $appStage 'bongo-preload-assets.py'), '--help')

$payloadPath = Join-Path $bundleStage 'payload.zip'
Compress-Archive -Path (Join-Path $appStage '*') -DestinationPath $payloadPath -CompressionLevel Optimal -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'installer\install-package.ps1') -Destination $bundleStage
Copy-Item -LiteralPath (Join-Path $projectRoot 'installer\install.cmd') -Destination $bundleStage
[System.IO.File]::WriteAllText((Join-Path $bundleStage 'version.txt'), $Version, [System.Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
    Remove-Item -LiteralPath $installerPath -Force
}
$sourceDirectory = $bundleStage.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$sedPath = Join-Path $buildRoot 'installer.sed'
$sedContents = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=Install Bongo Waifu - Unlocked Clothes?
DisplayLicense=
FinishMessage=
TargetName=$installerPath
FriendlyName=Bongo Waifu - Unlocked Clothes Setup
AppLaunched=cmd.exe /d /c install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=cmd.exe /d /c install.cmd
UserQuietInstCmd=cmd.exe /d /c install.cmd
FILE0="payload.zip"
FILE1="install-package.ps1"
FILE2="version.txt"
FILE3="install.cmd"
[SourceFiles]
SourceFiles0="$sourceDirectory"
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
"@
[System.IO.File]::WriteAllText($sedPath, $sedContents, [System.Text.Encoding]::ASCII)

$iexpressPath = Join-Path $env:SystemRoot 'System32\iexpress.exe'
Invoke-Checked $iexpressPath @('/N', '/Q', $sedPath)
$iexpressTemporaryDdf = Join-Path $distRoot '~BongoWaifu-Unlocked-Clothes-Setup.DDF'
$minimumInstallerSize = [int64]((Get-Item -LiteralPath $payloadPath).Length * 0.8)
foreach ($attempt in 1..1200) {
    $installerReady = (Test-Path -LiteralPath $installerPath -PathType Leaf) -and
        (Get-Item -LiteralPath $installerPath).Length -ge $minimumInstallerSize
    $builderFinished = -not (Test-Path -LiteralPath $iexpressTemporaryDdf -PathType Leaf)
    if ($installerReady -and $builderFinished) { break }
    Start-Sleep -Milliseconds 250
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf) -or
    (Get-Item -LiteralPath $installerPath).Length -lt $minimumInstallerSize -or
    (Test-Path -LiteralPath $iexpressTemporaryDdf -PathType Leaf)) {
    throw 'IExpress did not create the setup executable.'
}

$installer = Get-Item -LiteralPath $installerPath
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Installer: $($installer.FullName)"
Write-Output "Version: $Version"
Write-Output "Size: $($installer.Length) bytes"
Write-Output "SHA256: $hash"
