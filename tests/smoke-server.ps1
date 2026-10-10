param([Parameter(Mandatory=$true)][string]$JavaPath,[Parameter(Mandatory=$true)][string]$ExistingServer,[switch]$AcceptEula,[int]$JavaPort=0,[int]$BedrockPort=0)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\common.ps1')
if (!$AcceptEula) { throw 'Pass -AcceptEula only after accepting https://www.minecraft.net/eula.' }
$settings=Get-Settings
if ($JavaPort -gt 0) { $settings.javaPort=$JavaPort }
if ($BedrockPort -gt 0) { $settings.bedrockPort=$BedrockPort }
$address=Get-TailscaleAddress
Assert-ServerStopped $settings
$testDir=Join-Path $script:ProjectRoot ('runtime\smoke-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $testDir 'plugins') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ExistingServer 'paper.jar') -Destination $testDir
foreach ($name in @('Geyser-Spigot.jar','floodgate-spigot.jar','ViaVersion.jar')) {
    Copy-Item -LiteralPath (Join-Path $ExistingServer ('plugins\'+$name)) -Destination (Join-Path $testDir 'plugins')
}
foreach ($name in @('cache','libraries','versions')) {
    $path=Join-Path $ExistingServer $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $testDir -Recurse }
}
Update-ServerConfig $address $settings $testDir
Write-Utf8 (Join-Path $testDir 'eula.txt') "eula=true`n"
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=$JavaPath
$info.Arguments='-Dterminal.jline=false -Dterminal.ansi=false -Xms1G -Xmx2G -jar paper.jar --nogui'
$info.WorkingDirectory=$testDir
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
$process=[Diagnostics.Process]::Start($info)
$outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
try {
    $ready=$false
    for ($i=0;$i -lt 120;$i++) {
        Start-Sleep -Seconds 1
        if ($process.HasExited) { throw 'Server exited early' }
        $log=Get-Content -LiteralPath (Join-Path $testDir 'logs\latest.log') -Raw -ErrorAction SilentlyContinue
        if ($log -match 'Done \(') { $ready=$true; break }
    }
    if (!$ready) { throw 'Startup timeout' }
    Start-Sleep -Seconds 2
    $client=New-Object Net.Sockets.TcpClient
    $client.Connect($address,$settings.javaPort)
    $stream=$client.GetStream(); $stream.ReadTimeout=5000
    $port=[int]$settings.javaPort
    [byte[]]$packet=@(15,0,0,9)+[Text.Encoding]::ASCII.GetBytes('localhost')+@(($port -shr 8),($port -band 255),1,1,0)
    $stream.Write($packet,0,$packet.Length)
    [byte[]]$buffer=New-Object byte[] 8192
    $count=$stream.Read($buffer,0,$buffer.Length)
    $response=[Text.Encoding]::UTF8.GetString($buffer,0,$count)
    $client.Close()
    if ($response -notmatch '26.2') { throw 'Wrong Java status response' }
    $udp=New-Object Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout=5000
    $udp.Connect($address,$settings.bedrockPort)
    [byte[]]$ping=@(1)+(New-Object byte[] 8)+@(0,255,255,0,254,254,254,254,253,253,253,253,18,52,86,120)+(New-Object byte[] 8)
    [void]$udp.Send($ping,$ping.Length)
    $remote=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
    $reply=$udp.Receive([ref]$remote)
    $udp.Close()
    if ($reply[0] -ne 28) { throw 'Wrong Bedrock RakNet pong' }
    if ($log -match 'Error occurred while enabling|Could not load|Failed to start') { throw 'Plugin startup error' }
    $process.StandardInput.WriteLine('geyser version')
    $process.StandardInput.WriteLine('datapack list enabled')
    $process.StandardInput.WriteLine('scoreboard objectives list')
    Start-Sleep -Seconds 2
    $log=Get-Content -LiteralPath (Join-Path $testDir 'logs\latest.log') -Raw
    if ($log -match 'Failed to load function|Failed to parse|Failed to load data packs') { throw 'Datapack loading error' }
    if ($log -notmatch 'tc_deaths' -or $log -notmatch 'tailscalecraft-deaths') { throw 'Death coordinates datapack is not active' }
    Write-Host 'PASS: death coordinates datapack loads and creates its deathCount objective.'
    Write-Host 'PASS: clean installation starts, Java status and Bedrock UDP ping respond through the detected Tailscale address.'
} finally {
    if (!$process.HasExited) {
        $process.StandardInput.WriteLine('stop')
        if (!$process.WaitForExit(30000)) { throw 'Server did not stop gracefully' }
    }
    Write-Utf8 (Join-Path $testDir 'smoke-output.log') ($outTask.Result+$errTask.Result)
    Write-Host "Server exit code: $($process.ExitCode); logs: $testDir"
}
