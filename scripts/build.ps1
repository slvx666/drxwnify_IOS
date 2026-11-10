# Сборка Drxwnify для iOS на VM macOS. Запуск с Windows:
#   powershell -ExecutionPolicy Bypass -File ios\scripts\build.ps1
# Результат: ios\out\Drxwnify-<версия>.ipa, полный лог: ios\out\last-build.log
param(
    [string]$SshKey = 'D:\macos\ssh\id_ed25519',
    [string]$KnownHosts = 'D:\macos\ssh\known_hosts',
    [int]$Port = 2222,
    [string]$Remote = 'georgefloyd@127.0.0.1'
)

$iosDir = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $iosDir 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$log = Join-Path $outDir 'last-build.log'

$sshOpts = @('-i', $SshKey, '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')

$m = Select-String -Path (Join-Path $iosDir 'project.yml') -Pattern 'MARKETING_VERSION:\s*"?([0-9.]+)"?' | Select-Object -First 1
if (-not $m) { Write-Output 'error: в project.yml нет MARKETING_VERSION'; exit 1 }
$version = $m.Matches[0].Groups[1].Value

# 1. Архив исходников (через файл: конвейер PowerShell портит двоичные данные)
$tar = Join-Path $env:TEMP 'drxwnify-ios-src.tar'
if (Test-Path $tar) { Remove-Item $tar -Force }
& "$env:SystemRoot\System32\tar.exe" -cf $tar `
    --exclude=./out --exclude=./build --exclude=.build --exclude=DerivedData `
    --exclude=*.xcodeproj --exclude=./.git --exclude=./Generated `
    -C $iosDir .
if ($LASTEXITCODE -ne 0) { Write-Output 'error: tar не собрал архив'; exit 1 }

# 2. Копия на VM
& scp @sshOpts -P $Port -q $tar "${Remote}:drxwnify-ios-src.tar"
if ($LASTEXITCODE -ne 0) { Write-Output 'error: VM не отвечает по SSH (запусти D:\macos\start-docker.ps1)'; exit 1 }
Remove-Item $tar -Force

# 3. Сборка
$remoteCmd = 'rm -rf ~/drxwnify-ios && mkdir -p ~/drxwnify-ios && tar -xf ~/drxwnify-ios-src.tar -C ~/drxwnify-ios 2>/dev/null; ' +
             'cd ~/drxwnify-ios && tr -d \\r < scripts/remote-build.sh > ~/drxwnify-remote-build.sh && bash ~/drxwnify-remote-build.sh'
& ssh @sshOpts -p $Port $Remote $remoteCmd
$rc = $LASTEXITCODE

# 4. Лог обратно
& scp @sshOpts -P $Port -q "${Remote}:drxwnify-ios/build.log" $log

if ($rc -ne 0) {
    Write-Output "СБОРКА УПАЛА (код $rc). Полный лог: $log"
    $hits = Select-String -Path $log -Pattern 'error:' -Context 3, 3
    if ($hits) {
        $hits | Select-Object -First 40 | ForEach-Object {
            $_.Context.PreContext
            $_.Line
            $_.Context.PostContext
            '---'
        }
    } else {
        Get-Content $log -Tail 30
    }
    exit $rc
}

# 5. .ipa обратно
$ipa = Join-Path $outDir "Drxwnify-$version.ipa"
& scp @sshOpts -P $Port -q "${Remote}:drxwnify-ios/out/Drxwnify.ipa" $ipa
if ($LASTEXITCODE -ne 0) { Write-Output 'error: не удалось забрать .ipa'; exit 1 }

$warn = (Select-String -Path $log -Pattern 'warning:' | Measure-Object).Count
$size = [math]::Round((Get-Item $ipa).Length / 1MB, 2)
Write-Output "ГОТОВО: $ipa ($size МБ), предупреждений: $warn"
exit 0
