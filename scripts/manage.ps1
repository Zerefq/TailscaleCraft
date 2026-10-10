param([ValidateSet('Setup','Start','Doctor','Firewall','Backup')][string]$Action = 'Start')
. (Join-Path $PSScriptRoot 'common.ps1')
try {
    $settings=Get-Settings
    if ($Action -eq 'Backup') {
        Assert-ServerStopped $settings
        if (!(Test-Path -LiteralPath $script:ServerDir)) { throw 'No server directory to back up.' }
        $backupDir=Join-Path $script:ProjectRoot 'backups'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $file=Join-Path $backupDir ('server-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.zip')
        Compress-Archive -LiteralPath $script:ServerDir -DestinationPath $file
        Write-Host "Backup saved: $file"
        exit 0
    }
    $address=Get-TailscaleAddress
    Show-Addresses $address $settings
    if ($Action -eq 'Firewall') {
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Right-click FIREWALL.cmd and select Run as administrator.' }
        foreach ($rule in @(@{Name='Java';Protocol='TCP';Port=$settings.javaPort},@{Name='Bedrock';Protocol='UDP';Port=$settings.bedrockPort})) {
            $name='TailscaleCraft-'+$rule.Name
            if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
            New-NetFirewallRule -Name $name -DisplayName $name -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.Port -LocalAddress $address -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
        }
        Write-Host 'Firewall configured for Tailscale Minecraft ports.'
        exit 0
    }
    $java=Find-Java
    if ($Action -eq 'Doctor') {
        if ($java) { Write-Host "Java 25: $java" } else { Write-Host 'Java 25 missing. START.cmd will download a portable runtime.' }
        Write-Host ('Paper installed: ' + (Test-Path -LiteralPath (Join-Path $script:ServerDir 'paper.jar')))
        Get-NetFirewallRule -Name 'TailscaleCraft-*' -ErrorAction SilentlyContinue | Select-Object DisplayName,Enabled
        exit 0
    }
    Assert-ServerStopped $settings
    if (!$java) { $java=Install-Java }
    $manifest=Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'dependencies.json') -Raw | ConvertFrom-Json
    $missing=@($manifest.downloads | Where-Object { !(Test-Path -LiteralPath (Join-Path $script:ServerDir $_.file)) })
    if ($Action -eq 'Setup' -or $missing.Count -gt 0 -or !(Test-Path -LiteralPath (Join-Path $script:ServerDir '.installed.json'))) {
        Install-Server
        Write-Utf8 (Join-Path $script:ServerDir '.installed.json') '{"schema":1}'
    }
    Update-ServerConfig $address $settings
    if ($Action -eq 'Setup') { Write-Host 'Setup complete. Run START.cmd to play.'; exit 0 }
    $eula=Join-Path $script:ServerDir 'eula.txt'
    $accepted=(Test-Path -LiteralPath $eula) -and ((Get-Content -LiteralPath $eula -Raw) -match '(?m)^eula=true\s*$')
    if (!$accepted) {
        Write-Host 'Minecraft EULA: https://www.minecraft.net/eula'
        $answer=Read-Host 'Type YES if you accept the Minecraft EULA; anything else cancels'
        if ($answer -cne 'YES') { Write-Host 'Cancelled. EULA not accepted.'; exit 0 }
        Write-Utf8 $eula "eula=true`n"
    }
    Push-Location $script:ServerDir
    try {
        Write-Host 'Wait for Done, then connect. To save and stop, enter: stop'
        & $java '-Dterminal.jline=false' '-Dterminal.ansi=false' '-Xms1G' "-Xmx$($settings.memoryGB)G" '-jar' 'paper.jar' '--nogui'
        if ($LASTEXITCODE -ne 0) { throw "Minecraft exited with code $LASTEXITCODE. See server/logs/latest.log." }
    } finally { Pop-Location }
} catch { Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red; exit 1 }
