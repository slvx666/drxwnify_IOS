# Ставит свежий .ipa на iPhone (plumesign, бесплатная подпись Apple ID): подпись на ПК, если есть D:\tools\plume\plumesign.exe,
# иначе через ноут Arch.
# Запуск: powershell -ExecutionPolicy Bypass -File ios\scripts\install.ps1 [-Ipa путь]
# Требования: на ноуте ~/drxwnify/bin/plumesign с сохранённым входом в Apple ID; телефон разблокирован и доверяет ноуту.
param(
    [string]$Ipa = "",
    [string]$Laptop = "slvt@192.168.0.140"
)
$ErrorActionPreference = "Stop"
$ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$scp = "$env:WINDIR\System32\OpenSSH\scp.exe"
$opts = @("-i", "D:\macos\ssh\id_ed25519", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "UserKnownHostsFile=D:\macos\ssh\known_hosts")

if (-not $Ipa) {
    $out = Join-Path (Split-Path $PSScriptRoot -Parent) "out"
    $Ipa = (Get-ChildItem $out -Filter "Drxwnify-*.ipa" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $Ipa -or -not (Test-Path $Ipa)) { throw "Нет .ipa: сначала scripts\build.ps1" }
$name = Split-Path $Ipa -Leaf

# Основной путь: подпись на ПК (D:\tools\plume\plumesign.exe, Impactor 2.7.2, вход в Apple ID сохранён) и установка с ПК.
$plume = "D:\tools\plume\plumesign.exe"
$env:PYTHONPATH = 'D:\tools\pmd3'; $env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
if (Test-Path $plume) {
    $local = Join-Path $env:TEMP "signed-$name"
    Remove-Item $local -Force -ErrorAction SilentlyContinue
    $env:RUST_LOG = 'error,plumesign=info'
    # plumesign и pymobiledevice3 пишут журнал в stderr — в PowerShell 5.1 при Stop это считалось бы ошибкой.
    $ErrorActionPreference = "Continue"
    "`r`n`r`n" | & $plume sign --package $Ipa --apple-id -o $local 2>&1 | Select-String 'Saved|ERROR' | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path $local)) { throw "plumesign на ПК не подписал $name (вход в Apple ID: $plume account login -u ПОЧТА)" }
    # Открытое приложение (играет музыка) не даёт себя закрыть, и установка молча висит после загрузки — закрываем сами.
    & python -m pymobiledevice3 developer dvt pkill Drxwnify 2>$null | Out-Null
    & python -m pymobiledevice3 apps install $local
    if ($LASTEXITCODE -ne 0) { throw "pymobiledevice3 не установил $local" }
    Remove-Item $local -Force
    Write-Host "УСТАНОВЛЕНО: $name (подпись и установка с ПК)"
    exit 0
}

& $scp @opts $Ipa "${Laptop}:drxwnify/ipa/$name"
if ($LASTEXITCODE -ne 0) { throw "Не удалось скопировать $name на ноут" }

# iPhone подключён к ПК (ios/DEVICES.md), а не к ноуту: подпись на ноуте, установка с ПК через pymobiledevice3.
$env:PYTHONPATH = 'D:\tools\pmd3'; $env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
$onPc = (& python -m pymobiledevice3 usbmux list 2>$null | Out-String) -match '"UniqueDeviceID"'
if ($onPc) {
    $signed = "signed-$name"
    $remoteSign = "cd ~/drxwnify && rm -f ipa/$signed && printf '\r\r\r' | timeout 300 script -qec " +
        "'bin/plumesign sign --package ipa/$name --apple-id -o ipa/$signed' /dev/null 2>&1 | grep -aE 'Saved|ERROR' | tail -2; ls ipa/$signed"
    $log = & $ssh @opts $Laptop $remoteSign
    $log | ForEach-Object { Write-Host $_ }
    $local = Join-Path $env:TEMP $signed
    & $scp @opts "${Laptop}:drxwnify/ipa/$signed" $local
    if ($LASTEXITCODE -ne 0) { throw "Ноут не подписал $name" }
    & python -m pymobiledevice3 apps install $local
    if ($LASTEXITCODE -ne 0) { throw "pymobiledevice3 не установил $signed" }
    Remove-Item $local -Force
    Write-Host "УСТАНОВЛЕНО: $name (с ПК)"
    exit 0
}

# plumesign выбирает телефон из списка в терминале: даём псевдотерминал и Enter (без --udid — с ним он телефон не находит).
$remote = "cd ~/drxwnify && idevice_id -l | grep -q . || { echo NO_DEVICE; exit 3; }; " +
    "(sleep 8; printf '\r'; sleep 240) | RUST_LOG=error,plumesign=info timeout 280 script -qec " +
    "'bin/plumesign sign --package ipa/$name --apple-id --register-and-install' /dev/null 2>&1 | grep -a 'plumesign::' | tail -6"
$log = & $ssh @opts $Laptop $remote
$log | ForEach-Object { Write-Host $_ }
if ($log -match "NO_DEVICE") { throw "Ноут не видит телефон: проверь кабель и разблокируй экран" }
if (-not ($log -match "Installation complete")) { throw "Установка не подтверждена, см. вывод выше" }
Write-Host "УСТАНОВЛЕНО: $name"
