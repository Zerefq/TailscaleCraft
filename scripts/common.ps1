$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$script:ServerDir = Join-Path $script:ProjectRoot 'server'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Headers = @{'User-Agent'='TailscaleCraft/1.0 (local Minecraft server launcher)'}

function Write-Utf8($Path, $Value) {
    $parent = Split-Path $Path -Parent
    if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Value, $script:Utf8)
}

function Get-Settings {
    $settings = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'config.json') -Raw | ConvertFrom-Json
    if ($settings.PSObject.Properties.Name -notcontains 'viewDistance') { $settings | Add-Member -NotePropertyName viewDistance -NotePropertyValue 6 }
    if ($settings.PSObject.Properties.Name -notcontains 'simulationDistance') { $settings | Add-Member -NotePropertyName simulationDistance -NotePropertyValue 4 }
    if ($settings.PSObject.Properties.Name -notcontains 'bedrockMtu') { $settings | Add-Member -NotePropertyName bedrockMtu -NotePropertyValue 1200 }
    $override = Join-Path $script:ProjectRoot 'config.local.json'
    if (Test-Path -LiteralPath $override) {
        $local = Get-Content -LiteralPath $override -Raw | ConvertFrom-Json
        foreach ($property in $local.PSObject.Properties) {
            if ($settings.PSObject.Properties.Name -notcontains $property.Name) { throw "Unknown setting: $($property.Name)" }
            $settings.($property.Name) = $property.Value
        }
    }
    foreach ($key in @('javaPort','bedrockPort','memoryGB','maxPlayers','viewDistance','simulationDistance')) {
        $value = $settings.$key
        if ($null -eq $value -or "$value" -notmatch '^\d+$') { throw "Invalid integer setting: $key" }
        $limit = 65535
        if ($key -eq 'memoryGB') { $limit=128 }
        if ($key -eq 'maxPlayers') { $limit=1000 }
        if ($key -in @('viewDistance','simulationDistance')) { $limit=32 }
        if ([long]$value -lt 1 -or [long]$value -gt $limit) { throw "Setting out of range: $key" }
        if ($key -in @('viewDistance','simulationDistance') -and [long]$value -lt 2) { throw "Minimum chunk distance is 2: $key" }
    }
    if ($settings.motd -match '[\r\n]' -or $settings.motd -match '[^\x20-\x7e]') { throw 'motd must use printable ASCII without newlines.' }
    if ($settings.allowOfflineBedrock -isnot [bool]) { throw 'allowOfflineBedrock must be true or false.' }
    if ("$($settings.bedrockMtu)" -notmatch '^\d+$' -or [long]$settings.bedrockMtu -lt 576 -or [long]$settings.bedrockMtu -gt 1400) { throw 'bedrockMtu must be an integer between 576 and 1400.' }
    return $settings
}

function Find-Tailscale {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $candidate = Join-Path $base 'Tailscale\tailscale.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    throw 'Install Tailscale for Windows from https://tailscale.com/download and sign in.'
}

function Get-TailscaleAddress {
    $exe = Find-Tailscale
    $output = & $exe status --json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Tailscale service is unavailable. Open Tailscale and connect.' }
    $state = ($output -join "`n") | ConvertFrom-Json
    if ($state.BackendState -ne 'Running' -or !$state.Self.Online) { throw 'Tailscale is not connected. Open Tailscale and sign in.' }
    $address = @($state.TailscaleIPs | Where-Object { $_ -match '^100\.\d+\.\d+\.\d+$' }) | Select-Object -First 1
    if (!$address) { throw 'No Tailscale IPv4 address found.' }
    return [string]$address
}

function Assert-Checksum($Path, $Expected) {
    if ($Expected -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing SHA256 checksum for $Path" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "Checksum mismatch: $Path" }
}

function Get-CheckedDownload($Url, $Path, $Hash) {
    if (Test-Path -LiteralPath $Path) { Assert-Checksum $Path $Hash; return }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $tempPath = $Path + '.tmp'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tempPath -Headers $script:Headers -TimeoutSec 240
        Assert-Checksum $tempPath $Hash
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath }
    }
}

function Find-Java {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += Join-Path $env:JAVA_HOME 'bin\java.exe' }
    $command = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $runtime = Join-Path $script:ProjectRoot 'runtime'
    if (Test-Path -LiteralPath $runtime) { $candidates += @(Get-ChildItem -LiteralPath $runtime -Filter java.exe -File -Recurse | Select-Object -ExpandProperty FullName) }
    foreach ($candidate in $candidates) {
        if (!(Test-Path -LiteralPath $candidate)) { continue }
        # Native Java writes version information to stderr. Redirect to a file for PS 5.1.
        $versionFile = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.txt')
        try {
            $p = Start-Process -FilePath $candidate -ArgumentList '-version' -WindowStyle Hidden -RedirectStandardError $versionFile -Wait -PassThru
            $version = Get-Content -LiteralPath $versionFile -Raw
            if ($p.ExitCode -eq 0 -and $version -match 'version "25[.\"]') { return $candidate }
        } finally { if (Test-Path -LiteralPath $versionFile) { Remove-Item -LiteralPath $versionFile } }
    }
    return $null
}

function Install-Java {
    if (![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Automatic Java installation supports Windows x64. Install Java 25 manually and set JAVA_HOME on other architectures.' }
    Write-Host 'Downloading portable Java 25 (Eclipse Temurin)...'
    $assets = Invoke-RestMethod -Uri 'https://api.adoptium.net/v3/assets/latest/25/hotspot?architecture=x64&image_type=jre&os=windows&vendor=eclipse' -Headers $script:Headers
    $package = @($assets)[0].binary.package
    if (!$package.link -or !$package.checksum) { throw 'Adoptium returned no Java package.' }
    $archive = Join-Path $script:ProjectRoot 'runtime\java25.zip'
    Get-CheckedDownload $package.link $archive $package.checksum
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $script:ProjectRoot 'runtime') -Force
    $java = Find-Java
    if (!$java) { throw 'Java 25 was not found after installation.' }
    return $java
}

function Install-Server {
    $manifest = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'dependencies.json') -Raw | ConvertFrom-Json
    foreach ($dependency in $manifest.downloads) {
        $url=$dependency.url; $hash=$dependency.sha256
        if ($dependency.releaseApi) {
            $release = Invoke-RestMethod -Uri $dependency.releaseApi -Headers $script:Headers
            $asset = @($release.assets | Where-Object name -eq $dependency.asset)[0]
            if (!$asset -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw "No verified GitHub release asset: $($dependency.asset)" }
            $hash=$Matches[1]; $url=$asset.browser_download_url
        }
        Write-Host "Preparing $($dependency.file)..."
        Get-CheckedDownload $url (Join-Path $script:ServerDir $dependency.file) $hash
    }
}

function Set-PropertyText($Text, $Key, $Value) {
    $pattern = '(?m)^' + [regex]::Escape($Key) + '=.*$'
    if ($Text -match $pattern) {
        $replacement = { param($match) $Key + '=' + $Value }.GetNewClosure()
        return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]$replacement)
    }
    return $Text.TrimEnd() + "`n" + $Key + '=' + $Value + "`n"
}

function Update-ServerConfig($Address, $Settings, $Directory = $script:ServerDir) {
    $parsed = $null
    if (![Net.IPAddress]::TryParse($Address, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Invalid server IPv4 address.' }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $propertiesPath = Join-Path $Directory 'server.properties'
    $text = ''
    if (Test-Path -LiteralPath $propertiesPath) { $text = Get-Content -LiteralPath $propertiesPath -Raw }
    $properties = [ordered]@{'server-ip'=$Address;'server-port'=$Settings.javaPort;'white-list'='false';'enforce-whitelist'='false';'online-mode'='false';'enforce-secure-profile'='false';'max-players'=$Settings.maxPlayers;'motd'=$Settings.motd;'enable-rcon'='false';'management-server-enabled'='false'}
    $properties['view-distance']=$Settings.viewDistance
    $properties['simulation-distance']=$Settings.simulationDistance
    if (!$text) { $text="gamemode=survival`ndifficulty=normal`nview-distance=8`nsimulation-distance=6`nspawn-protection=0`n" }
    foreach ($entry in $properties.GetEnumerator()) { $text = Set-PropertyText $text $entry.Key $entry.Value }
    Write-Utf8 $propertiesPath $text
    $geyserPath = Join-Path $Directory 'plugins\Geyser-Spigot\config.yml'
    $authType = 'floodgate'
    $validateLogin = 'true'
    if ($Settings.allowOfflineBedrock) { $authType='offline'; $validateLogin='false' }
    if (Test-Path -LiteralPath $geyserPath) {
        $yaml = Get-Content -LiteralPath $geyserPath -Raw
        # Edit only the network fields; preserve resource packs and other user settings.
        $yaml = [regex]::Replace($yaml,'(?ms)(^bedrock:\s*\r?\n.*?^  address:) [^\r\n]*',('$1 ' + $Address))
        $yaml = [regex]::Replace($yaml,'(?ms)(^bedrock:\s*\r?\n.*?^  port:) \d+',('$1 ' + $Settings.bedrockPort))
        $yaml = [regex]::Replace($yaml,'(?m)^(  auth-type:) .*',('$1 ' + $authType))
        $yaml = [regex]::Replace($yaml,'(?m)^(  clone-remote-port:) .*','$1 false')
        $yaml = [regex]::Replace($yaml,'(?m)^(    use-haproxy-protocol:) .*','$1 false')
        $yaml = [regex]::Replace($yaml,'(?m)^(    broadcast-port:) \d+','$1 0')
        if ($yaml -match '(?m)^    validate-bedrock-login:') {
            $yaml = [regex]::Replace($yaml,'(?m)^(    validate-bedrock-login:) .*',('$1 ' + $validateLogin))
        } elseif ($yaml -match '(?m)^advanced:') {
            if ($yaml -match '(?ms)^advanced:\s*\r?\n.*?^  bedrock:') {
                $yaml = [regex]::Replace($yaml,'(?ms)(^advanced:\s*\r?\n.*?^  bedrock:\s*\r?\n)',('$1    validate-bedrock-login: ' + $validateLogin + "`n"))
            } else { $yaml = [regex]::Replace($yaml,'(?m)^advanced:\s*\r?\n',("advanced:`n  bedrock:`n    validate-bedrock-login: " + $validateLogin + "`n")) }
        } else { $yaml += "`nadvanced:`n  bedrock:`n    validate-bedrock-login: $validateLogin`n" }
    } else {
        $yaml = "bedrock:`n  address: $Address`n  port: $($Settings.bedrockPort)`n  clone-remote-port: false`n  transport: raknet`njava:`n  auth-type: $authType`nadvanced:`n  java:`n    use-direct-connection: true`n    use-haproxy-protocol: false`n  bedrock:`n    broadcast-port: 0`n    use-haproxy-protocol: false`n    validate-bedrock-login: $validateLogin`nconfig-version: 9`n"
    }
    if ($yaml -match '(?m)^    mtu:') {
        $yaml = [regex]::Replace($yaml,'(?m)^(    mtu:) \d+',('$1 ' + $Settings.bedrockMtu))
    } else {
        $yaml = [regex]::Replace($yaml,'(?ms)(^advanced:\s*\r?\n.*?^  bedrock:\s*\r?\n)',('$1    mtu: ' + $Settings.bedrockMtu + "`n"))
    }
    Write-Utf8 $geyserPath $yaml
    Install-DeathCoordinates $Directory
}

function Install-DeathCoordinates($Directory) {
    $properties = Get-Content -LiteralPath (Join-Path $Directory 'server.properties') -Raw
    $worldName = 'world'
    if ($properties -match '(?m)^level-name=([^\r\n]+)') { $worldName=$matches[1].Trim() }
    $serverRoot=[IO.Path]::GetFullPath($Directory).TrimEnd('\','/')
    $worldRoot=[IO.Path]::GetFullPath((Join-Path $serverRoot $worldName))
    if (!$worldRoot.StartsWith($serverRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'World directory must be inside the server directory to install the death coordinates datapack.' }
    $destination=Join-Path $worldRoot 'datapacks\tailscalecraft-deaths'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $source=Join-Path $script:ProjectRoot 'datapacks\tailscalecraft-deaths'
    Copy-Item -LiteralPath (Join-Path $source 'pack.mcmeta') -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $source 'data') -Destination $destination -Recurse -Force
}

function Assert-ServerStopped($Settings) {
    if (Get-NetTCPConnection -LocalPort $Settings.javaPort -State Listen -ErrorAction SilentlyContinue) { throw 'A server is already running on this port. Enter stop in its console before changing configuration.' }
}

function Show-Addresses($Address, $Settings) {
    Write-Host "`nJava:    ${Address}:$($Settings.javaPort)"
    Write-Host "Bedrock: $Address   port $($Settings.bedrockPort)"
    Write-Host 'Friends must enable Tailscale and have access to this PC. No nickname whitelist.'
    if ($Settings.allowOfflineBedrock) {
        Write-Host 'Experimental Bedrock mode: Xbox verification is disabled. Phone clients may still require sign-in.'
        Write-Host 'Player names are not verified. Avoid OP for names that another player could use.'
    }
}
