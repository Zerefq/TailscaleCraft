. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\common.ps1')
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
$directory=Join-Path ([IO.Path]::GetTempPath()) ('TailscaleCraft-test-'+[guid]::NewGuid().ToString('N'))
$settings=Get-Settings
$settings.allowOfflineBedrock=$false
# Synthetic addresses represent two unrelated host installations.
Update-ServerConfig '100.70.1.2' $settings $directory
$properties=Join-Path $directory 'server.properties'
$geyser=Join-Path $directory 'plugins\Geyser-Spigot\config.yml'
Write-Utf8 $properties ((Get-Content -LiteralPath $properties -Raw) + "level-seed=987654`nwhite-list=true`nenforce-whitelist=true`n")
Write-Utf8 $geyser ((Get-Content -LiteralPath $geyser -Raw) + "debug-mode: true`n")
$changed=$settings | ConvertTo-Json | ConvertFrom-Json
$changed.javaPort=25580; $changed.bedrockPort=19140; $changed.motd='Test $1 literal'
$changed.viewDistance=4; $changed.simulationDistance=3
Update-ServerConfig '100.90.3.4' $changed $directory
$text=Get-Content -LiteralPath $properties -Raw
$yaml=Get-Content -LiteralPath $geyser -Raw
Assert ($text -match 'server-ip=100.90.3.4') 'Host address did not update'
Assert ($text -notmatch '100.70.1.2') 'Previous host address leaked'
Assert ($text -notmatch '(?m)^(white-list|enforce-whitelist)=true') 'Nickname restrictions remain enabled'
Assert ($text -match 'level-seed=987654') 'Existing world seed was overwritten'
Assert ($text -match 'server-port=25580') 'Custom Java port not applied'
Assert ($text -match 'view-distance=4') 'Custom view distance not applied'
Assert ($text -match 'simulation-distance=3') 'Custom simulation distance not applied'
Assert ($text.Contains('motd=Test $1 literal')) 'Literal replacement characters were corrupted'
Assert ($yaml -match 'address: 100.90.3.4') 'Geyser address did not update'
Assert ($yaml -match 'port: 19140') 'Custom Bedrock port not applied'
Assert ($yaml -match 'debug-mode: true') 'User Geyser setting was lost'
Assert ($yaml -match 'auth-type: floodgate') 'Bedrock authentication not configured'
Assert ($yaml -match 'mtu: 1200') 'Tailscale-friendly Bedrock MTU was not inserted'
$changed.bedrockMtu=1100
$changed.allowOfflineBedrock=$true
Update-ServerConfig '100.90.3.4' $changed $directory
$yaml=Get-Content -LiteralPath $geyser -Raw
Assert ($yaml -match 'auth-type: offline') 'Experimental offline auth type not applied'
Assert ($yaml -match 'validate-bedrock-login: false') 'Bedrock validation was not disabled'
Assert ($yaml -match 'mtu: 1100') 'Custom Bedrock MTU was not applied'
Assert ($yaml -match 'debug-mode: true') 'User settings lost on auth mode switch'
# Restore account verification, including configurations missing the validation field.
$changed.allowOfflineBedrock=$false
Write-Utf8 $geyser ([regex]::Replace($yaml,'(?m)^    validate-bedrock-login:.*\r?\n',''))
Update-ServerConfig '100.90.3.4' $changed $directory
$yaml=Get-Content -LiteralPath $geyser -Raw
Assert ($yaml -match 'auth-type: floodgate') 'Verified auth mode was not restored'
Assert ($yaml -match 'validate-bedrock-login: true') 'Missing validation setting was not inserted'
$bad=Join-Path $directory 'tampered.jar'
Write-Utf8 $bad 'tampered content'
$blocked=$false
try { Get-CheckedDownload 'https://example.invalid/should-not-be-used' $bad ('0'*64) } catch { $blocked=$_.Exception.Message -like '*Checksum mismatch*' }
Assert $blocked 'Tampered cached download was accepted'
$blocked=$false
try { Update-ServerConfig 'not-an-address' $settings $directory } catch { $blocked=$true }
Assert $blocked 'Invalid network address was accepted'
Write-Host 'PASS: independent host addresses, custom ports, user setting preservation, no whitelist, checksum validation.'
Write-Host "Test artifacts: $directory"
