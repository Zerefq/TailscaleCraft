. (Join-Path $PSScriptRoot 'common.ps1')
$files=@('START.cmd','SETUP.cmd','CHECK.cmd','FIREWALL.cmd','BACKUP.cmd','config.json','dependencies.json','.gitignore','LICENSE','README.md','CONNECT.md','THIRD-PARTY.md','scripts','tests','datapacks')
$stage=Join-Path $script:ProjectRoot ('dist\stage-' + [guid]::NewGuid().ToString('N'))
$output=Join-Path $stage 'TailscaleCraft'
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($item in $files) {
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot $item) -Destination $output -Recurse -Force
}
$archive=Join-Path $script:ProjectRoot 'dist\TailscaleCraft-source.zip'
Compress-Archive -LiteralPath $output -DestinationPath $archive -Force
Write-Host "Source archive: $archive"
Write-Host 'Only source files are included. Server data, runtime and accounts are excluded.'
