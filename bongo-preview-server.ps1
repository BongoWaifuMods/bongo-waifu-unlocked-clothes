param([switch]$NoOpen)

$ErrorActionPreference = 'Stop'

$taskRoot = $PSScriptRoot
$runtimeRoot = Join-Path $PSScriptRoot '.runtime'
$previewRoot = Join-Path $PSScriptRoot 'bongo-waifu-clothes-preview'
$spineAssetRoot = Join-Path $PSScriptRoot 'runtime\bongo-spine-assets'
$pythonSitePackages = Join-Path $runtimeRoot 'Lib\site-packages'
$unityPyRoot = $pythonSitePackages
$dncilRoot = $pythonSitePackages
$pythonPath = Join-Path $runtimeRoot 'Scripts\python.exe'
$rendererPath = Join-Path $PSScriptRoot 'bongo-render-look.py'
$preloaderPath = Join-Path $PSScriptRoot 'bongo-preload-assets.py'
$nativePatcherPath = Join-Path $PSScriptRoot 'bongo-native-apply.py'
$renderRoot = Join-Path $runtimeRoot 'render-cache'
$textureRoot = Join-Path $runtimeRoot 'textures'
$overlayAppRoot = Join-Path $PSScriptRoot 'bongo-overlay-app'
$overlayElectronPath = Join-Path $runtimeRoot 'electron\electron.exe'
$overlayStatePath = Join-Path $runtimeRoot 'bongo-overlay-state.json'
$overlayPidPath = Join-Path $runtimeRoot 'bongo-overlay.pid'
$overlaySettingsPath = Join-Path $runtimeRoot 'bongo-overlay-settings.json'
$nativeBackupRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData').Replace('AppData\Local', 'AppData\LocalLow')) 'RamenCatStudio\BongoWaifu\codex_native_skin_backup'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$apiVersion = 8
$appId = '3861430'
$nativeProxyIds = [ordered]@{
    'Corpo' = 200
    'Partes íntimas' = 400
    'Pelos, genitais e marcas' = 1004
    'Cabelos' = 1002
    'Peças de cima' = 3006
    'Saias' = 4106
    'Sutiãs e biquínis' = 5109
    'Meias' = 8000
    'Calçados' = 9209
    'Brinquedos' = 1
}
$nativeRequiredGroups = @('Corpo', 'Partes íntimas', 'Brinquedos')

[System.IO.Directory]::CreateDirectory($renderRoot) | Out-Null

function Add-SteamRoot([System.Collections.Generic.List[string]]$roots, [string]$candidate) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return }
    try {
        $normalized = [System.IO.Path]::GetFullPath($candidate.Replace('/', '\'))
        if ((Test-Path -LiteralPath $normalized -PathType Container) -and $roots -notcontains $normalized) {
            $roots.Add($normalized)
        }
    }
    catch { }
}

function Get-SteamRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($registryPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $steam = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            $steamRoot = if ($steam.SteamPath) { [string]$steam.SteamPath } else { [string]$steam.InstallPath }
            Add-SteamRoot $roots $steamRoot
        }
        catch { }
    }
    Add-SteamRoot $roots 'C:\Program Files (x86)\Steam'
    Add-SteamRoot $roots 'C:\Program Files\Steam'

    for ($index = 0; $index -lt $roots.Count; $index++) {
        $libraryFile = Join-Path $roots[$index] 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $libraryFile -PathType Leaf)) { continue }
        try {
            $libraryText = [System.IO.File]::ReadAllText($libraryFile)
            foreach ($match in [regex]::Matches($libraryText, '"path"\s+"([^"]+)"')) {
                Add-SteamRoot $roots $match.Groups[1].Value.Replace('\\', '\')
            }
        }
        catch { }
    }
    return $roots.ToArray()
}

function Find-BongoInstallation {
    foreach ($steamRoot in Get-SteamRoots) {
        $steamApps = Join-Path $steamRoot 'steamapps'
        $manifest = Join-Path $steamApps "appmanifest_$appId.acf"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $installDirectory = 'Bongo Waifu'
        try {
            $manifestText = [System.IO.File]::ReadAllText($manifest)
            $installMatch = [regex]::Match($manifestText, '"installdir"\s+"([^"]+)"')
            if ($installMatch.Success) { $installDirectory = $installMatch.Groups[1].Value }
        }
        catch { }
        $gamePath = Join-Path (Join-Path $steamApps 'common') $installDirectory
        $dataPath = Join-Path $gamePath 'BongoWaifu_Data'
        $savePath = Join-Path $dataPath 'Save\playerSave.save'
        if (Test-Path -LiteralPath $savePath -PathType Leaf) {
            return [pscustomobject]@{
                SteamRoot = $steamRoot
                GamePath = $gamePath
                DataPath = $dataPath
                SavePath = $savePath
            }
        }
    }
    return $null
}

function Test-GameRunning {
    return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Bongo Waifu', 'BongoWaifu')
    } | Select-Object -First 1)
}

function Stop-BongoGame {
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Bongo Waifu', 'BongoWaifu')
    })
    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $gentleDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ((Test-GameRunning) -and [DateTime]::UtcNow -lt $gentleDeadline) {
        Start-Sleep -Milliseconds 200
    }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Bongo Waifu', 'BongoWaifu')
    })) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    if (Test-GameRunning) {
        try { Start-Process "steam://stop/$appId" | Out-Null } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ((Test-GameRunning) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (Test-GameRunning) {
        throw 'O Bongo Waifu está em modo Administrador e o Windows bloqueou o encerramento automático. Feche o jogo pela bandeja e clique em Aplicar novamente.'
    }
    return $processes.Count
}

function Start-BongoGame([object]$installation) {
    $steamExe = Join-Path $installation.SteamRoot 'steam.exe'
    if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
        Start-Process -FilePath $steamExe -ArgumentList @('-applaunch', $appId) | Out-Null
    }
    else {
        Start-Process "steam://run/$appId" | Out-Null
    }
}

function Get-InstallationStatus {
    $installation = Find-BongoInstallation
    return [pscustomobject]@{
        Installation = $installation
        Found = $null -ne $installation
        Running = Test-GameRunning
    }
}

function Get-BongoOverlayProcess {
    if (-not (Test-Path -LiteralPath $overlayPidPath -PathType Leaf)) { return $null }
    $overlayPid = 0
    try { [void][int]::TryParse(([System.IO.File]::ReadAllText($overlayPidPath).Trim()), [ref]$overlayPid) } catch { }
    if ($overlayPid -lt 1) { return $null }
    try {
        $record = Get-CimInstance Win32_Process -Filter "ProcessId = $overlayPid" -ErrorAction Stop
        if ($null -eq $record -or $record.Name -ne 'electron.exe' -or $record.CommandLine -notlike "*$overlayAppRoot*") { return $null }
        return Get-Process -Id $overlayPid -ErrorAction Stop
    }
    catch { return $null }
}

function Test-BongoOverlayRunning {
    return $null -ne (Get-BongoOverlayProcess)
}

function Start-BongoOverlay {
    $existing = Get-BongoOverlayProcess
    if ($null -ne $existing) { return $existing }
    if (-not (Test-Path -LiteralPath $overlayElectronPath -PathType Leaf)) {
        throw 'O runtime local do overlay não foi encontrado.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $overlayAppRoot 'main.cjs') -PathType Leaf)) {
        throw 'O aplicativo local do overlay não foi encontrado.'
    }
    $arguments = @(
        $overlayAppRoot,
        "--preview-url=http://127.0.0.1:$port",
        "--pid-path=$overlayPidPath",
        "--settings-path=$overlaySettingsPath"
    )
    # Esta janela precisa ser visível: é o companion visual solicitado pelo usuário.
    $process = Start-Process -FilePath $overlayElectronPath -ArgumentList $arguments -PassThru
    [System.IO.File]::WriteAllText($overlayPidPath, [string]$process.Id, $utf8NoBom)
    return $process
}

function Stop-BongoOverlay {
    $process = Get-BongoOverlayProcess
    if ($null -eq $process) { return $false }
    try { [void]$process.CloseMainWindow() } catch { }
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 150
        try { $process.Refresh() } catch { break }
    }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $overlayPidPath -PathType Leaf) { Remove-Item -LiteralPath $overlayPidPath -Force }
    return $true
}

function Get-DefaultOverlayState {
    return [ordered]@{
        selectedId = 1
        equipped = [ordered]@{
            'Corpo' = 200
            'Partes íntimas' = 400
            'Brinquedos' = 1
        }
        animation = 'Idle'
        animations = [ordered]@{
            action = 'Idle'
            level = 'Level_0'
            stain = 'body_stain_00'
        }
    }
}

function Get-OverlayState {
    if (-not (Test-Path -LiteralPath $overlayStatePath -PathType Leaf)) { return Get-DefaultOverlayState }
    try { return ([System.IO.File]::ReadAllText($overlayStatePath, $utf8NoBom) | ConvertFrom-Json) }
    catch { return Get-DefaultOverlayState }
}

function Normalize-OverlayState([object]$payload) {
    $default = Get-DefaultOverlayState
    $equipped = [ordered]@{}
    foreach ($group in @('Corpo', 'Partes íntimas', 'Pelos, genitais e marcas', 'Cabelos', 'Peças de cima', 'Saias', 'Sutiãs e biquínis', 'Meias', 'Calçados', 'Brinquedos')) {
        $property = $payload.equipped.PSObject.Properties[$group]
        if ($null -eq $property) { continue }
        $itemId = 0
        if ([int]::TryParse([string]$property.Value, [ref]$itemId) -and $itemId -gt 0) { $equipped[$group] = $itemId }
    }
    foreach ($required in @('Corpo', 'Partes íntimas', 'Brinquedos')) {
        if (-not $equipped.Contains($required)) { $equipped[$required] = $default.equipped[$required] }
    }
    $animations = [ordered]@{}
    foreach ($layer in @('action', 'level', 'stain')) {
        $property = $payload.animations.PSObject.Properties[$layer]
        $value = if ($null -ne $property) { [string]$property.Value } else { [string]$default.animations[$layer] }
        if ($value.Length -gt 64 -or $value -notmatch '^[A-Za-z0-9_]+$') { $value = [string]$default.animations[$layer] }
        $animations[$layer] = $value
    }
    $selectedId = 0
    [void][int]::TryParse([string]$payload.selectedId, [ref]$selectedId)
    return [ordered]@{
        selectedId = if ($selectedId -gt 0) { $selectedId } else { 1 }
        equipped = $equipped
        animation = [string]$animations.action
        animations = $animations
    }
}

function Test-PortInUse([int]$candidatePort) {
    $socket = [System.Net.Sockets.TcpClient]::new()
    try {
        $result = $socket.BeginConnect('127.0.0.1', $candidatePort, $null, $null)
        return $result.AsyncWaitHandle.WaitOne(150) -and $socket.Connected
    }
    catch { return $false }
    finally { $socket.Dispose() }
}

function Get-BongoMcpCandidatePorts {
    $ports = [System.Collections.Generic.List[int]]::new()
    $processIds = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('Bongo Waifu', 'BongoWaifu')
    } | ForEach-Object { [int]$_.Id })
    if ($processIds.Count -gt 0) {
        try {
            Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
                $processIds -contains [int]$_.OwningProcess -and
                $_.LocalAddress -in @('127.0.0.1', '::1')
            } | ForEach-Object {
                $candidate = [int]$_.LocalPort
                if ($ports -notcontains $candidate) { $ports.Add($candidate) }
            }
        }
        catch { }
    }
    foreach ($candidate in 7337..7346) {
        if ((Test-PortInUse $candidate) -and $ports -notcontains $candidate) { $ports.Add($candidate) }
    }
    return $ports.ToArray()
}

function Get-BongoLiveState {
    if (-not (Test-GameRunning)) {
        return [ordered]@{
            running = $false
            connected = $false
            character = $null
            inventory = @()
            error = $null
        }
    }

    foreach ($candidate in Get-BongoMcpCandidatePorts) {
        try {
            $mcpUri = "http://127.0.0.1:$candidate/mcp"
            $initializeBody = [ordered]@{
                jsonrpc = '2.0'
                id = 1
                method = 'initialize'
                params = [ordered]@{
                    protocolVersion = '2025-03-26'
                    capabilities = @{}
                    clientInfo = @{ name = 'Bongo local preview'; version = '1.0' }
                }
            } | ConvertTo-Json -Depth 8 -Compress
            $initialize = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $mcpUri -Headers @{
                Origin = 'http://127.0.0.1'
            } -ContentType 'application/json' -Body $initializeBody -TimeoutSec 2
            $sessionHeaders = @($initialize.Headers['Mcp-Session-Id'])
            $sessionId = if ($sessionHeaders.Count -gt 0) { [string]$sessionHeaders[0] } else { '' }
            if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }

            $stateBody = [ordered]@{
                jsonrpc = '2.0'
                id = 2
                method = 'tools/call'
                params = [ordered]@{
                    name = 'get_game_state'
                    arguments = @{ sections = @('character', 'inventory') }
                }
            } | ConvertTo-Json -Depth 8 -Compress
            $stateResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $mcpUri -Headers @{
                Origin = 'http://127.0.0.1'
                'Mcp-Session-Id' = $sessionId
            } -ContentType 'application/json' -Body $stateBody -TimeoutSec 3
            $rpc = $stateResponse.Content | ConvertFrom-Json
            $textBlock = @($rpc.result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1)
            if ($textBlock.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$textBlock[0].text)) { continue }
            $gameState = ([string]$textBlock[0].text) | ConvertFrom-Json
            $inventory = @($gameState.inventory | ForEach-Object {
                [ordered]@{
                    definitionId = [int]$_.definition_id
                    name = [string]$_.name
                    quantity = [int]$_.quantity
                }
            })
            return [ordered]@{
                running = $true
                connected = $true
                character = $gameState.character
                inventory = $inventory
                error = $null
            }
        }
        catch { }
    }

    return [ordered]@{
        running = $true
        connected = $false
        character = $null
        inventory = @()
        error = 'O jogo está aberto, mas o estado visual ainda não ficou disponível.'
    }
}

function Test-PreviewServer([int]$candidatePort) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$candidatePort/api/status" -TimeoutSec 1
        return $response.StatusCode -eq 200 -and $response.Content.Contains("`"apiVersion`":$apiVersion")
    }
    catch { return $false }
}

$port = $null
foreach ($candidate in 54811..54820) {
    if ((Test-PortInUse $candidate) -and (Test-PreviewServer $candidate)) {
        if (-not $NoOpen) { Start-Process "http://127.0.0.1:$candidate/all-clothes.html" }
        exit 0
    }
}
foreach ($candidate in 54811..54820) {
    if (-not (Test-PortInUse $candidate)) {
        $port = $candidate
        break
    }
}
if ($null -eq $port) { throw 'Não encontrei uma porta local livre para abrir o provador.' }

function Send-Response(
    [System.IO.Stream]$stream,
    [string]$status,
    [string]$contentType,
    [byte[]]$body,
    [bool]$headOnly = $false,
    [string]$cacheControl = 'no-store'
) {
    $headers = @(
        "HTTP/1.1 $status",
        "Content-Type: $contentType",
        "Content-Length: $($body.Length)",
        "Cache-Control: $cacheControl",
        'X-Content-Type-Options: nosniff',
        'Referrer-Policy: no-referrer',
        "Content-Security-Policy: default-src 'self'; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
        'Connection: close',
        '',
        ''
    ) -join "`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $headOnly) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Send-TextResponse(
    [System.IO.Stream]$stream,
    [string]$status,
    [string]$message,
    [bool]$headOnly = $false
) {
    Send-Response $stream $status 'text/plain; charset=utf-8' $utf8NoBom.GetBytes($message) $headOnly
}

function Send-JsonResponse(
    [System.IO.Stream]$stream,
    [string]$status,
    [object]$value,
    [bool]$headOnly = $false
) {
    $json = ConvertTo-Json $value -Depth 12 -Compress
    Send-Response $stream $status 'application/json; charset=utf-8' $utf8NoBom.GetBytes($json) $headOnly
}

function Read-RequestBody([System.IO.StreamReader]$reader, [hashtable]$headers) {
    $contentLength = 0
    if ($headers.ContainsKey('content-length')) {
        [void][int]::TryParse($headers['content-length'], [ref]$contentLength)
    }
    if ($contentLength -lt 1) { return '' }
    if ($contentLength -gt 4194304) { throw 'Corpo da requisição grande demais.' }
    # Content-Length counts UTF-8 bytes, not decoded .NET characters. Reading
    # that many chars deadlocks when JSON contains names such as "Partes íntimas".
    $builder = [System.Text.StringBuilder]::new([Math]::Min($contentLength, 65536))
    $encoder = $utf8NoBom.GetEncoder()
    $singleCharacter = [char[]]::new(1)
    $encodedBytes = [byte[]]::new(4)
    $bytesRead = 0
    while ($bytesRead -lt $contentLength) {
        $value = $reader.Read()
        if ($value -lt 0) { break }
        $singleCharacter[0] = [char]$value
        [void]$builder.Append($singleCharacter[0])
        $bytesRead += $encoder.GetBytes($singleCharacter, 0, 1, $encodedBytes, 0, $false)
    }
    return $builder.ToString()
}

function Test-SameOrigin([hashtable]$headers) {
    return $headers.ContainsKey('origin') -and $headers['origin'] -eq "http://127.0.0.1:$port"
}

function Get-Hash([string]$value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($utf8NoBom.GetBytes($value)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Test-EncryptedSave([string]$contents) {
    if (-not $contents.StartsWith('ENCRYPTED_')) { return $false }
    try {
        $bytes = [System.Convert]::FromBase64String($contents.Substring(10).Trim())
        return $bytes.Length -gt 0 -and ($bytes.Length % 16) -eq 0
    }
    catch { return $false }
}

function Get-FileSha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $file = [System.IO.File]::OpenRead($path)
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($file))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $file.Dispose()
        $sha.Dispose()
    }
}

function Get-NativePaths([object]$installation) {
    return [pscustomobject]@{
        AssetPath = Join-Path $installation.DataPath 'sharedassets0.assets'
        ManagedPath = Join-Path $installation.DataPath 'Managed'
        AssemblyPath = Join-Path $installation.DataPath 'Managed\Assembly-CSharp.dll'
        BackupRoot = $nativeBackupRoot
        OriginalPath = Join-Path $nativeBackupRoot 'sharedassets0.assets.original'
        OriginalAssemblyPath = Join-Path $nativeBackupRoot 'Assembly-CSharp.dll.original'
        LatestManifestPath = Join-Path $nativeBackupRoot 'native-look-latest.json'
        HistoryPath = Join-Path $nativeBackupRoot 'history'
    }
}

function Normalize-NativeSelection([object]$selection) {
    if ($null -eq $selection) { throw 'A seleção visual não foi enviada.' }
    foreach ($property in $selection.PSObject.Properties) {
        if ($nativeProxyIds.Keys -notcontains $property.Name) {
            throw "Categoria visual desconhecida: $($property.Name)"
        }
    }
    $normalized = [ordered]@{}
    foreach ($group in $nativeProxyIds.Keys) {
        $itemId = 0
        $property = $selection.PSObject.Properties[$group]
        if ($null -ne $property -and -not [int]::TryParse([string]$property.Value, [ref]$itemId)) {
            throw "ID inválido em $group."
        }
        if ($itemId -lt 0) { throw "ID inválido em $group." }
        if ($nativeRequiredGroups -contains $group -and $itemId -eq 0) {
            throw "A categoria obrigatória $group não pode ficar vazia."
        }
        $normalized[$group] = $itemId
    }
    return $normalized
}

function Ensure-NativeOriginal([object]$installation) {
    $paths = Get-NativePaths $installation
    if (-not (Test-Path -LiteralPath $paths.AssetPath -PathType Leaf)) {
        throw "O asset visual do jogo não foi encontrado: $($paths.AssetPath)"
    }
    if (-not (Test-Path -LiteralPath $paths.AssemblyPath -PathType Leaf)) {
        throw "Assembly-CSharp.dll não foi encontrado: $($paths.AssemblyPath)"
    }
    [System.IO.Directory]::CreateDirectory($paths.BackupRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($paths.HistoryPath) | Out-Null
    if (-not (Test-Path -LiteralPath $paths.OriginalPath -PathType Leaf)) {
        Copy-Item -LiteralPath $paths.AssetPath -Destination $paths.OriginalPath
    }
    if (-not (Test-Path -LiteralPath $paths.OriginalAssemblyPath -PathType Leaf)) {
        Copy-Item -LiteralPath $paths.AssemblyPath -Destination $paths.OriginalAssemblyPath
    }
    if ((Get-Item -LiteralPath $paths.OriginalPath).Length -lt 1024) {
        throw 'O backup original do asset está vazio ou inválido.'
    }

    # Depois da primeira aplicação dinâmica, uma divergência que não seja nem
    # a fonte nem o patch mais recente indica atualização/reparo pela Steam.
    if (Test-Path -LiteralPath $paths.LatestManifestPath -PathType Leaf) {
        try {
            $latest = [System.IO.File]::ReadAllText($paths.LatestManifestPath, $utf8NoBom) | ConvertFrom-Json
            $currentHash = Get-FileSha256 $paths.AssetPath
            $originalHash = Get-FileSha256 $paths.OriginalPath
            $knownHashes = @([string]$latest.source_sha256, [string]$latest.patched_sha256, $originalHash)
            if ($knownHashes -notcontains $currentHash) {
                $archiveName = "sharedassets0.assets.original-$($originalHash.Substring(0, 12)).bak"
                $archivePath = Join-Path $paths.HistoryPath $archiveName
                if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
                    Copy-Item -LiteralPath $paths.OriginalPath -Destination $archivePath
                }
                Copy-Item -LiteralPath $paths.AssetPath -Destination $paths.OriginalPath -Force
            }
            $currentAssemblyHash = Get-FileSha256 $paths.AssemblyPath
            $originalAssemblyHash = Get-FileSha256 $paths.OriginalAssemblyPath
            $knownAssemblyHashes = @([string]$latest.runtime.source_sha256, [string]$latest.runtime.patched_sha256, $originalAssemblyHash)
            if ($knownAssemblyHashes -notcontains $currentAssemblyHash) {
                $assemblyArchiveName = "Assembly-CSharp.dll.original-$($originalAssemblyHash.Substring(0, 12)).bak"
                $assemblyArchivePath = Join-Path $paths.HistoryPath $assemblyArchiveName
                if (-not (Test-Path -LiteralPath $assemblyArchivePath -PathType Leaf)) {
                    Copy-Item -LiteralPath $paths.OriginalAssemblyPath -Destination $assemblyArchivePath
                }
                Copy-Item -LiteralPath $paths.AssemblyPath -Destination $paths.OriginalAssemblyPath -Force
            }
        }
        catch {
            throw "Não foi possível validar o backup nativo: $($_.Exception.Message)"
        }
    }
    return $paths
}

function Get-NativeIntegrationStatus([object]$installation) {
    $available = (Test-Path -LiteralPath $pythonPath -PathType Leaf) -and
        (Test-Path -LiteralPath $nativePatcherPath -PathType Leaf) -and
        (Test-Path -LiteralPath $unityPyRoot -PathType Container) -and
        (Test-Path -LiteralPath $dncilRoot -PathType Container)
    $result = [ordered]@{
        available = $available
        installed = $false
        originalBackup = $false
        supportsAllCatalogItems = $true
        proxyIds = $nativeProxyIds
        selection = $null
        error = $null
    }
    if ($null -eq $installation) { return $result }
    $paths = Get-NativePaths $installation
    $result.originalBackup = (Test-Path -LiteralPath $paths.OriginalPath -PathType Leaf) -and
        (Test-Path -LiteralPath $paths.OriginalAssemblyPath -PathType Leaf)
    if (-not (Test-Path -LiteralPath $paths.LatestManifestPath -PathType Leaf)) { return $result }
    try {
        $manifest = [System.IO.File]::ReadAllText($paths.LatestManifestPath, $utf8NoBom) | ConvertFrom-Json
        $result.selection = $manifest.selection
        if ((Test-Path -LiteralPath $paths.AssetPath -PathType Leaf) -and (Test-Path -LiteralPath $paths.AssemblyPath -PathType Leaf)) {
            $assetMatches = (Get-FileSha256 $paths.AssetPath) -eq [string]$manifest.patched_sha256
            $assemblyMatches = $null -eq $manifest.runtime -or (Get-FileSha256 $paths.AssemblyPath) -eq [string]$manifest.runtime.patched_sha256
            $result.installed = $assetMatches -and $assemblyMatches
        }
    }
    catch { $result.error = $_.Exception.Message }
    return $result
}

function Invoke-NativeLookApply(
    [object]$installation,
    [object]$selectionValue,
    [string]$expectedSave,
    [string]$updatedSave,
    [bool]$restartGame
) {
    if (Test-GameRunning) { throw 'Feche o Bongo Waifu antes de aplicar a skin nativa.' }
    if (-not (Test-EncryptedSave $updatedSave)) { throw 'O novo save não tem o formato criptografado esperado.' }
    if (-not (Test-Path -LiteralPath $nativePatcherPath -PathType Leaf)) { throw 'O aplicador nativo local não foi encontrado.' }
    if (-not (Test-Path -LiteralPath $unityPyRoot -PathType Container)) { throw 'A biblioteca local de assets Unity não foi encontrada.' }
    if (-not (Test-Path -LiteralPath $dncilRoot -PathType Container)) { throw 'A biblioteca local de IL não foi encontrada.' }

    $selection = Normalize-NativeSelection $selectionValue
    $paths = Ensure-NativeOriginal $installation
    $currentSave = [System.IO.File]::ReadAllText($installation.SavePath, $utf8NoBom)
    if ($currentSave -cne $expectedSave) { throw 'O save mudou desde a leitura. Tente aplicar novamente.' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $token = "$PID-$([guid]::NewGuid().ToString('N'))"
    $selectionPath = Join-Path $paths.BackupRoot "selection-$token.json"
    $builtAssetPath = Join-Path $paths.BackupRoot "sharedassets0-$token.assets"
    $builtAssemblyPath = Join-Path $paths.BackupRoot "Assembly-CSharp-$token.dll"
    $manifestPath = Join-Path $paths.BackupRoot "manifest-$token.json"
    $assetSwapPath = "$($paths.AssetPath).codex-native-$token.tmp"
    $assetReplaceBackup = "$($paths.AssetPath).codex-native-$token.replace.bak"
    $assemblySwapPath = "$($paths.AssemblyPath).codex-native-$token.tmp"
    $assemblyReplaceBackup = "$($paths.AssemblyPath).codex-native-$token.replace.bak"
    $saveSwapPath = "$($installation.SavePath).codex-native-$token.tmp"
    $saveReplaceBackup = "$($installation.SavePath).codex-native-$token.replace.bak"
    $assetBackupName = "sharedassets0.assets.before-$stamp.bak"
    $assemblyBackupName = "Assembly-CSharp.dll.before-$stamp.bak"
    $saveBackupName = "playerSave.save.before-native-$stamp.bak"
    $assetBackupPath = Join-Path $paths.HistoryPath $assetBackupName
    $assemblyBackupPath = Join-Path $paths.HistoryPath $assemblyBackupName
    $saveBackupPath = Join-Path $paths.HistoryPath $saveBackupName
    $assetChanged = $false
    $assemblyChanged = $false
    $saveChanged = $false

    try {
        $selectionJson = ConvertTo-Json $selection -Depth 4
        [System.IO.File]::WriteAllText($selectionPath, $selectionJson, $utf8NoBom)
        $patchArguments = @(
            $nativePatcherPath, 'build',
            '--asset', $paths.OriginalPath,
            '--output', $builtAssetPath,
            '--selection', $selectionPath,
            '--manifest', $manifestPath,
            '--unitypy', $unityPyRoot,
            '--managed', $paths.ManagedPath,
            '--assembly', $paths.OriginalAssemblyPath,
            '--assembly-output', $builtAssemblyPath,
            '--dncil', $dncilRoot
        )
        $patchOutput = & $pythonPath @patchArguments 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $builtAssetPath -PathType Leaf) -or -not (Test-Path -LiteralPath $builtAssemblyPath -PathType Leaf)) {
            $details = ($patchOutput | Out-String).Trim()
            throw "Falha ao gerar a skin nativa. $details"
        }
        $manifest = [System.IO.File]::ReadAllText($manifestPath, $utf8NoBom) | ConvertFrom-Json
        if (-not [bool]$manifest.verified -or -not [bool]$manifest.runtime.verified) { throw 'O asset ou o ajuste de controlador não passou na verificação estrutural.' }

        $currentSave = [System.IO.File]::ReadAllText($installation.SavePath, $utf8NoBom)
        if ($currentSave -cne $expectedSave) { throw 'O save mudou durante a geração. Nenhum arquivo foi substituído.' }
        Copy-Item -LiteralPath $paths.AssetPath -Destination $assetBackupPath
        Copy-Item -LiteralPath $paths.AssemblyPath -Destination $assemblyBackupPath
        Copy-Item -LiteralPath $installation.SavePath -Destination $saveBackupPath

        Copy-Item -LiteralPath $builtAssemblyPath -Destination $assemblySwapPath
        [System.IO.File]::Replace($assemblySwapPath, $paths.AssemblyPath, $assemblyReplaceBackup)
        $assemblyChanged = $true
        if ((Get-FileSha256 $paths.AssemblyPath) -ne [string]$manifest.runtime.patched_sha256) {
            throw 'A verificação SHA-256 do controlador instalado falhou.'
        }

        Copy-Item -LiteralPath $builtAssetPath -Destination $assetSwapPath
        [System.IO.File]::Replace($assetSwapPath, $paths.AssetPath, $assetReplaceBackup)
        $assetChanged = $true
        if ((Get-FileSha256 $paths.AssetPath) -ne [string]$manifest.patched_sha256) {
            throw 'A verificação SHA-256 do asset instalado falhou.'
        }

        [System.IO.File]::WriteAllText($saveSwapPath, $updatedSave, $utf8NoBom)
        [System.IO.File]::Replace($saveSwapPath, $installation.SavePath, $saveReplaceBackup)
        $saveChanged = $true
        if ([System.IO.File]::ReadAllText($installation.SavePath, $utf8NoBom) -cne $updatedSave) {
            throw 'A verificação do save instalado falhou.'
        }

        $registryPath = 'HKCU:\Software\RamenCatStudio\BongoWaifu'
        New-Item -Path $registryPath -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name 'Settings_CharacterMode_h3247276325' -PropertyType DWord -Value 0 -Force | Out-Null
        Copy-Item -LiteralPath $manifestPath -Destination $paths.LatestManifestPath -Force

        $restarted = $false
        $restartError = $null
        if ($restartGame) {
            try {
                Start-BongoGame $installation
                $restarted = $true
            }
            catch { $restartError = $_.Exception.Message }
        }
        return [ordered]@{
            applied = $true
            verified = $true
            selection = $selection
            proxyIds = $nativeProxyIds
            patchedSha256 = [string]$manifest.patched_sha256
            assetBackupName = $assetBackupName
            assemblyBackupName = $assemblyBackupName
            saveBackupName = $saveBackupName
            originalBackup = $paths.OriginalPath
            restarted = $restarted
            restartError = $restartError
        }
    }
    catch {
        $failure = $_
        if ($saveChanged -and (Test-Path -LiteralPath $saveBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $saveBackupPath -Destination $installation.SavePath -Force
        }
        if ($assetChanged -and (Test-Path -LiteralPath $assetBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $assetBackupPath -Destination $paths.AssetPath -Force
        }
        if ($assemblyChanged -and (Test-Path -LiteralPath $assemblyBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $assemblyBackupPath -Destination $paths.AssemblyPath -Force
        }
        throw $failure
    }
    finally {
        foreach ($temporary in @($selectionPath, $builtAssetPath, $builtAssemblyPath, $manifestPath, $assetSwapPath, $assetReplaceBackup, $assemblySwapPath, $assemblyReplaceBackup, $saveSwapPath, $saveReplaceBackup)) {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function Invoke-NativeLookRestore([object]$installation, [bool]$restartGame) {
    if (Test-GameRunning) { throw 'Feche o Bongo Waifu antes de restaurar o asset original.' }
    $paths = Get-NativePaths $installation
    if (-not (Test-Path -LiteralPath $paths.OriginalPath -PathType Leaf) -or -not (Test-Path -LiteralPath $paths.OriginalAssemblyPath -PathType Leaf)) { throw 'Os backups originais não foram encontrados.' }
    [System.IO.Directory]::CreateDirectory($paths.HistoryPath) | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupName = "sharedassets0.assets.before-restore-$stamp.bak"
    $assemblyBackupName = "Assembly-CSharp.dll.before-restore-$stamp.bak"
    $backupPath = Join-Path $paths.HistoryPath $backupName
    $assemblyBackupPath = Join-Path $paths.HistoryPath $assemblyBackupName
    $swapPath = "$($paths.AssetPath).codex-restore-$PID.tmp"
    $replaceBackup = "$($paths.AssetPath).codex-restore-$PID.replace.bak"
    $assemblySwapPath = "$($paths.AssemblyPath).codex-restore-$PID.tmp"
    $assemblyReplaceBackup = "$($paths.AssemblyPath).codex-restore-$PID.replace.bak"
    $assetChanged = $false
    $assemblyChanged = $false
    try {
        Copy-Item -LiteralPath $paths.AssetPath -Destination $backupPath
        Copy-Item -LiteralPath $paths.AssemblyPath -Destination $assemblyBackupPath
        Copy-Item -LiteralPath $paths.OriginalAssemblyPath -Destination $assemblySwapPath
        [System.IO.File]::Replace($assemblySwapPath, $paths.AssemblyPath, $assemblyReplaceBackup)
        $assemblyChanged = $true
        if ((Get-FileSha256 $paths.AssemblyPath) -ne (Get-FileSha256 $paths.OriginalAssemblyPath)) {
            throw 'A verificação da restauração do controlador falhou.'
        }
        Copy-Item -LiteralPath $paths.OriginalPath -Destination $swapPath
        [System.IO.File]::Replace($swapPath, $paths.AssetPath, $replaceBackup)
        $assetChanged = $true
        if ((Get-FileSha256 $paths.AssetPath) -ne (Get-FileSha256 $paths.OriginalPath)) {
            throw 'A verificação da restauração do asset falhou.'
        }
        $restarted = $false
        $restartError = $null
        if ($restartGame) {
            try { Start-BongoGame $installation; $restarted = $true } catch { $restartError = $_.Exception.Message }
        }
        return [ordered]@{ restored = $true; backupName = $backupName; assemblyBackupName = $assemblyBackupName; restarted = $restarted; restartError = $restartError }
    }
    catch {
        $failure = $_
        if ($assetChanged -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $backupPath -Destination $paths.AssetPath -Force
        }
        if ($assemblyChanged -and (Test-Path -LiteralPath $assemblyBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $assemblyBackupPath -Destination $paths.AssemblyPath -Force
        }
        throw $failure
    }
    finally {
        foreach ($temporary in @($swapPath, $replaceBackup, $assemblySwapPath, $assemblyReplaceBackup)) {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png' = 'image/png'
    '.webp' = 'image/webp'
    '.svg' = 'image/svg+xml'
    '.atlas' = 'text/plain; charset=utf-8'
    '.skel' = 'application/octet-stream'
}

$startupInstallation = Find-BongoInstallation
$assetsReady = $false
$preloadedTextureCount = 0
if ($null -ne $startupInstallation) {
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $preloaderPath -PathType Leaf)) {
        throw 'O pré-carregador local não está disponível.'
    }
    $preloadOutput = & $pythonPath $preloaderPath '--game-data' $startupInstallation.DataPath '--output' $textureRoot '--icon-output' (Join-Path $previewRoot 'assets') 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao pré-carregar os recursos do jogo. $(($preloadOutput | Out-String).Trim())"
    }
    $preloadedTextureCount = @(Get-ChildItem -LiteralPath $textureRoot -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
    $assetsReady = $preloadedTextureCount -gt 0 -and
        (Test-Path -LiteralPath (Join-Path $spineAssetRoot 'BaseBody.skel') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $spineAssetRoot 'BaseBody.atlas') -PathType Leaf)
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
if (-not $NoOpen) { Start-Process "http://127.0.0.1:$port/all-clothes.html" }

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, $utf8NoBom, $true, 4096, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }

            $headers = @{}
            while ($true) {
                $headerLine = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($headerLine)) { break }
                $separator = $headerLine.IndexOf(':')
                if ($separator -gt 0) {
                    $headers[$headerLine.Substring(0, $separator).Trim().ToLowerInvariant()] = $headerLine.Substring($separator + 1).Trim()
                }
            }

            $parts = $requestLine -split ' '
            $method = if ($parts.Count -gt 0) { $parts[0].ToUpperInvariant() } else { '' }
            $requestTarget = if ($parts.Count -gt 1) { ($parts[1] -split '\?', 2)[0] } else { '/' }
            $requestPath = [System.Uri]::UnescapeDataString($requestTarget)
            $headOnly = $method -eq 'HEAD'

            if ($requestPath -eq '/api/status' -and $method -in @('GET', 'HEAD')) {
                $state = Get-InstallationStatus
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    apiVersion = $apiVersion
                    found = $state.Found
                    running = $state.Running
                    assetsReady = $assetsReady
                    preloadedTextures = $preloadedTextureCount
                    gamePath = if ($state.Found) { $state.Installation.GamePath } else { $null }
                    savePath = if ($state.Found) { $state.Installation.SavePath } else { $null }
                    native = Get-NativeIntegrationStatus $state.Installation
                }) $headOnly
                continue
            }

            if ($requestPath -eq '/api/overlay-state' -and $method -in @('GET', 'HEAD')) {
                Send-JsonResponse $stream '200 OK' (Get-OverlayState) $headOnly
                continue
            }

            if ($requestPath -eq '/api/overlay-state' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $requestBody = Read-RequestBody $reader $headers
                $payload = $requestBody | ConvertFrom-Json
                if ($null -eq $payload.equipped -or $null -eq $payload.animations) {
                    Send-JsonResponse $stream '400 Bad Request' @{ error = 'Estado visual incompleto.' }
                    continue
                }
                $normalized = Normalize-OverlayState $payload
                $stateJson = ConvertTo-Json $normalized -Depth 8 -Compress
                $temporaryPath = Join-Path (Split-Path $overlayStatePath -Parent) "bongo-overlay-state-$PID-$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    [System.IO.File]::WriteAllText($temporaryPath, $stateJson, $utf8NoBom)
                    Move-Item -LiteralPath $temporaryPath -Destination $overlayStatePath -Force
                }
                finally {
                    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
                }
                Send-JsonResponse $stream '200 OK' @{ updated = $true; state = $normalized }
                continue
            }

            if ($requestPath -eq '/api/overlay' -and $method -in @('GET', 'HEAD')) {
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    available = (Test-Path -LiteralPath $overlayElectronPath -PathType Leaf)
                    running = Test-BongoOverlayRunning
                }) $headOnly
                continue
            }

            if ($requestPath -eq '/api/overlay' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $payload = (Read-RequestBody $reader $headers) | ConvertFrom-Json
                $action = [string]$payload.action
                if ($action -eq 'start') {
                    $overlayProcess = Start-BongoOverlay
                    Send-JsonResponse $stream '200 OK' ([ordered]@{ available = $true; running = $true; processId = $overlayProcess.Id })
                    continue
                }
                if ($action -eq 'stop') {
                    $stopped = Stop-BongoOverlay
                    Send-JsonResponse $stream '200 OK' ([ordered]@{ available = $true; running = $false; stopped = $stopped })
                    continue
                }
                Send-JsonResponse $stream '400 Bad Request' @{ error = 'Ação de overlay inválida.' }
                continue
            }

            if ($requestPath -eq '/api/game-state' -and $method -in @('GET', 'HEAD')) {
                Send-JsonResponse $stream '200 OK' (Get-BongoLiveState) $headOnly
                continue
            }

            if ($requestPath -eq '/api/game-stop' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                $stopped = Stop-BongoGame
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    stopped = $stopped
                    running = Test-GameRunning
                })
                continue
            }

            if ($requestPath -eq '/api/native-apply' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                if ($state.Running) {
                    Send-JsonResponse $stream '409 Conflict' @{ error = 'Feche o Bongo Waifu antes de aplicar a skin nativa.' }
                    continue
                }
                $payload = (Read-RequestBody $reader $headers) | ConvertFrom-Json
                $result = Invoke-NativeLookApply $state.Installation $payload.selection ([string]$payload.original) ([string]$payload.updated) ([bool]$payload.restartGame)
                Send-JsonResponse $stream '200 OK' $result
                continue
            }

            if ($requestPath -eq '/api/native-restore' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                if ($state.Running) {
                    Send-JsonResponse $stream '409 Conflict' @{ error = 'Feche o Bongo Waifu antes de restaurar o asset original.' }
                    continue
                }
                $payload = (Read-RequestBody $reader $headers) | ConvertFrom-Json
                $result = Invoke-NativeLookRestore $state.Installation ([bool]$payload.restartGame)
                Send-JsonResponse $stream '200 OK' $result
                continue
            }

            if ($requestPath -eq '/api/render' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $requestBody = Read-RequestBody $reader $headers
                $payload = $requestBody | ConvertFrom-Json
                $ids = @($payload.ids | ForEach-Object { [int]$_ })
                if ($ids.Count -lt 1 -or $ids.Count -gt 8 -or @($ids | Select-Object -Unique).Count -ne $ids.Count) {
                    Send-JsonResponse $stream '400 Bad Request' @{ error = 'Seleção inválida.' }
                    continue
                }
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $rendererPath -PathType Leaf)) {
                    Send-JsonResponse $stream '500 Internal Server Error' @{ error = 'O renderizador local não está disponível.' }
                    continue
                }
                $selectionKey = ($ids | Sort-Object) -join '-'
                $cacheName = "look-$(Get-Hash $selectionKey).webp"
                $cachePath = Join-Path $renderRoot $cacheName
                $wasCached = Test-Path -LiteralPath $cachePath -PathType Leaf
                if (-not $wasCached) {
                    $rendererOutput = & $pythonPath $rendererPath '--game-data' $state.Installation.DataPath '--ids' ($ids -join ',') '--output' $cachePath 2>&1
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
                        $details = ($rendererOutput | Out-String).Trim()
                        throw "Falha ao montar o visual. $details"
                    }
                }
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    url = "/generated/$cacheName"
                    itemCount = $ids.Count
                    cached = $wasCached
                })
                continue
            }

            if ($requestPath -eq '/api/game-save' -and $method -eq 'GET') {
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                $contents = [System.IO.File]::ReadAllText($state.Installation.SavePath, $utf8NoBom)
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    gamePath = $state.Installation.GamePath
                    savePath = $state.Installation.SavePath
                    running = $state.Running
                    contents = $contents
                })
                continue
            }

            if ($requestPath -eq '/api/game-save' -and $method -eq 'POST') {
                if (-not (Test-SameOrigin $headers)) {
                    Send-JsonResponse $stream '403 Forbidden' @{ error = 'Origem não autorizada.' }
                    continue
                }
                $state = Get-InstallationStatus
                if (-not $state.Found) {
                    Send-JsonResponse $stream '404 Not Found' @{ error = 'Bongo Waifu não foi encontrado nas bibliotecas Steam.' }
                    continue
                }
                if ($state.Running) {
                    Send-JsonResponse $stream '409 Conflict' @{ error = 'Feche o Bongo Waifu antes de salvar.' }
                    continue
                }
                $requestBody = Read-RequestBody $reader $headers
                $payload = $requestBody | ConvertFrom-Json
                $original = [string]$payload.original
                $updated = [string]$payload.updated
                $restartGame = [bool]$payload.restartGame
                $current = [System.IO.File]::ReadAllText($state.Installation.SavePath, $utf8NoBom)
                if ($current -cne $original) {
                    Send-JsonResponse $stream '409 Conflict' @{ error = 'O save mudou desde a leitura. Tente salvar novamente.' }
                    continue
                }
                if (-not (Test-EncryptedSave $updated)) {
                    Send-JsonResponse $stream '400 Bad Request' @{ error = 'O novo save não tem o formato criptografado esperado.' }
                    continue
                }
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                $backupName = "playerSave.save.codex-$stamp.bak"
                $saveDirectory = Split-Path $state.Installation.SavePath -Parent
                $backupPath = Join-Path $saveDirectory $backupName
                $temporaryPath = Join-Path $saveDirectory "playerSave.save.codex-write-$PID-$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    [System.IO.File]::WriteAllText($temporaryPath, $updated, $utf8NoBom)
                    [System.IO.File]::Replace($temporaryPath, $state.Installation.SavePath, $backupPath)
                }
                finally {
                    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                        Remove-Item -LiteralPath $temporaryPath -Force
                    }
                }
                $restarted = $false
                $restartError = $null
                if ($restartGame) {
                    try {
                        Start-BongoGame $state.Installation
                        $restarted = $true
                    }
                    catch {
                        $restartError = $_.Exception.Message
                    }
                }
                Send-JsonResponse $stream '200 OK' ([ordered]@{
                    saved = $true
                    savePath = $state.Installation.SavePath
                    backupName = $backupName
                    restarted = $restarted
                    restartError = $restartError
                })
                continue
            }

            if ($requestPath.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-JsonResponse $stream '404 Not Found' @{ error = 'API local não encontrada.' } $headOnly
                continue
            }

            if ($method -notin @('GET', 'HEAD')) {
                Send-TextResponse $stream '405 Method Not Allowed' 'Método não permitido.'
                continue
            }

            if ($requestPath -eq '/') { $requestPath = '/all-clothes.html' }
            $isGenerated = $requestPath.StartsWith('/generated/', [System.StringComparison]::OrdinalIgnoreCase)
            $isTexture = $requestPath.StartsWith('/textures/', [System.StringComparison]::OrdinalIgnoreCase)
            $isSpineAsset = $requestPath.StartsWith('/spine-assets/', [System.StringComparison]::OrdinalIgnoreCase)
            if ($isGenerated) {
                $rootPath = $renderRoot
                $relative = $requestPath.Substring('/generated/'.Length)
            }
            elseif ($isTexture) {
                $rootPath = $textureRoot
                $relative = $requestPath.Substring('/textures/'.Length)
            }
            elseif ($isSpineAsset) {
                $rootPath = $spineAssetRoot
                $relative = $requestPath.Substring('/spine-assets/'.Length)
            }
            else {
                $rootPath = $previewRoot
                $relative = $requestPath.TrimStart('/')
            }
            $resolvedRoot = [System.IO.Path]::GetFullPath($rootPath)
            $rootPrefix = $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            $relativePath = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $filePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativePath))
            if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-TextResponse $stream '403 Forbidden' 'Acesso negado.' $headOnly
                continue
            }
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Send-TextResponse $stream '404 Not Found' 'Arquivo não encontrado.' $headOnly
                continue
            }
            $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
            $contentType = if ($mimeTypes.ContainsKey($extension)) { $mimeTypes[$extension] } else { 'application/octet-stream' }
            $cacheControl = if ($isTexture -or $isSpineAsset -or $requestPath.StartsWith('/vendor/', [System.StringComparison]::OrdinalIgnoreCase)) {
                'public, max-age=31536000, immutable'
            }
            else { 'no-store' }
            Send-Response $stream '200 OK' $contentType ([System.IO.File]::ReadAllBytes($filePath)) $headOnly $cacheControl
        }
        catch {
            if ($null -ne $stream) {
                try { Send-JsonResponse $stream '500 Internal Server Error' @{ error = $_.Exception.Message } } catch { }
            }
        }
        finally {
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
}
