# Проверки формата (zip, protobuf, XML, позже протокол Nostr) на VM под macOS.
# Запуск: powershell -ExecutionPolicy Bypass -File ios\scripts\test.ps1
# Исходники берутся из ~/drxwnify-ios, то есть сначала нужен build.ps1 (он их туда копирует)
# или ключ -Sync.
param(
    [switch]$Sync,
    [string]$SshKey = 'D:\macos\ssh\id_ed25519',
    [string]$KnownHosts = 'D:\macos\ssh\known_hosts',
    [int]$Port = 2222,
    [string]$Remote = 'georgefloyd@127.0.0.1'
)

$iosDir = Split-Path -Parent $PSScriptRoot
# Системный OpenSSH: у ssh из Git for Windows другие правила экранирования аргументов.
$sshDir = Join-Path $env:SystemRoot 'System32\OpenSSH'
$ssh = Join-Path $sshDir 'ssh.exe'; if (-not (Test-Path $ssh)) { $ssh = 'ssh' }
$scp = Join-Path $sshDir 'scp.exe'; if (-not (Test-Path $scp)) { $scp = 'scp' }
$sshOpts = @('-i', $SshKey, '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')

if ($Sync) {
    $tar = Join-Path $env:TEMP 'drxwnify-ios-src.tar'
    if (Test-Path $tar) { Remove-Item $tar -Force }
    & "$env:SystemRoot\System32\tar.exe" -cf $tar `
        --exclude=./out --exclude=./build --exclude=.build --exclude=DerivedData `
        --exclude=*.xcodeproj --exclude=./.git --exclude=./Generated `
        -C $iosDir .
    & $scp @sshOpts -P $Port -q $tar "${Remote}:drxwnify-ios-src.tar"
    if ($LASTEXITCODE -ne 0) { Write-Output 'error: VM не отвечает по SSH'; exit 1 }
    Remove-Item $tar -Force
    & $ssh @sshOpts -p $Port $Remote 'mkdir -p ~/drxwnify-ios && tar -xf ~/drxwnify-ios-src.tar -C ~/drxwnify-ios 2>/dev/null; true'
}

& $ssh @sshOpts -p $Port $Remote 'cd ~/drxwnify-ios && tr -d \\r < scripts/host-test.sh > ~/drxwnify-host-test.sh && bash ~/drxwnify-host-test.sh'
exit $LASTEXITCODE
