# iOS 26 simulator on the macOS VM (ASCII only: Windows PowerShell 5.1 mangles UTF-8 without BOM).
# How it works and what to do after a VM restart: ios\SIMULATOR.md
#   sim.ps1 build                 sync ios/ to the VM, Debug build for the simulator, boot "Drxwnify-26", install
#   sim.ps1 boot                  only boot the simulator (after a VM restart)
#   sim.ps1 shot <screen> [name]  relaunch with DRX_SCREEN=<screen> ("-" = none), wait, screenshot -> ios\out\sim\<name>.png
#   sim.ps1 snap <screen> [name]  same, but the app draws itself (DRX_SNAPSHOT, CPU render) - when the screen is black
#   sim.ps1 url <link> [name]     open drxwnify://... in the running app, screenshot
#   sim.ps1 cmd "<shell>"         run a shell command on the VM inside the GUI session (simctl etc.)
param(
    [Parameter(Position = 0)][string]$Mode = 'build',
    [Parameter(Position = 1)][string]$Arg = '',
    [Parameter(Position = 2)][string]$Name = '',
    [int]$Wait = 20,
    [string]$SshKey = 'D:\macos\ssh\id_ed25519',
    [string]$KnownHosts = 'D:\macos\ssh\known_hosts',
    [int]$Port = 2222,
    [string]$Remote = 'georgefloyd@127.0.0.1'
)

$iosDir = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $iosDir 'out'
$shotDir = Join-Path $outDir 'sim'
New-Item -ItemType Directory -Force $shotDir | Out-Null

$sshDir = Join-Path $env:SystemRoot 'System32\OpenSSH'
$ssh = Join-Path $sshDir 'ssh.exe'; if (-not (Test-Path $ssh)) { $ssh = 'ssh' }
$scp = Join-Path $sshDir 'scp.exe'; if (-not (Test-Path $scp)) { $scp = 'scp' }
$sshOpts = @('-i', $SshKey, '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=30')
$sim = 'Drxwnify-26'
$bundle = 'com.drxwnify.ios'

function Gui([string]$cmd) {
    # single quotes inside $cmd must be avoided; the whole command goes to drx-gui as one argument
    # Out-Host: otherwise the command output becomes part of the return value and "$rc -ne 0" is always true
    & $ssh @sshOpts -p $Port $Remote "~/bin/drx-gui '$cmd'" | Out-Host
    return $LASTEXITCODE
}

function Fetch([string]$remotePng, [string]$file) {
    $dst = Join-Path $shotDir "$file.png"
    & $scp @sshOpts -P $Port -q "${Remote}:$remotePng" $dst
    if ($LASTEXITCODE -ne 0) { Write-Output 'error: copy failed'; exit 1 }
    Write-Output "SHOT: $dst"
}

function Launch([string]$screen, [string]$extraEnv) {
    $envPart = $extraEnv
    if ($screen -and $screen -ne '-') { $envPart = "$envPart SIMCTL_CHILD_DRX_SCREEN=`"$screen`"" }
    $rc = Gui "xcrun simctl terminate $sim $bundle >/dev/null 2>&1; $envPart xcrun simctl launch $sim $bundle >/dev/null && sleep $Wait"
    if ($rc -ne 0) { Write-Output 'error: launch failed'; exit 1 }
}

if ($Mode -eq 'build') {
    $log = Join-Path $outDir 'last-sim-build.log'
    $tar = Join-Path $env:TEMP 'drxwnify-ios-sim.tar'
    if (Test-Path $tar) { Remove-Item $tar -Force }
    & "$env:SystemRoot\System32\tar.exe" -cf $tar `
        --exclude=./out --exclude=./build --exclude=.build --exclude=DerivedData `
        --exclude=*.xcodeproj --exclude=./.git --exclude=./Generated `
        -C $iosDir .
    if ($LASTEXITCODE -ne 0) { Write-Output 'error: tar failed'; exit 1 }
    & $scp @sshOpts -P $Port -q $tar "${Remote}:drxwnify-ios-src.tar"
    if ($LASTEXITCODE -ne 0) { Write-Output 'error: VM not reachable (run D:\macos\start-docker.ps1)'; exit 1 }
    Remove-Item $tar -Force
    $cmd = 'rm -rf ~/drxwnify-ios && mkdir -p ~/drxwnify-ios && tar -xf ~/drxwnify-ios-src.tar -C ~/drxwnify-ios 2>/dev/null; ' +
           'cd ~/drxwnify-ios && tr -d \\r < scripts/remote-sim.sh > ~/drxwnify-remote-sim.sh && bash ~/drxwnify-remote-sim.sh'
    & $ssh @sshOpts -p $Port $Remote $cmd
    $rc = $LASTEXITCODE
    & $scp @sshOpts -P $Port -q "${Remote}:drxwnify-ios/sim-build.log" $log
    if ($rc -ne 0) {
        Write-Output "SIM BUILD FAILED (code $rc). Log: $log"
        $hits = Select-String -Path $log -Pattern 'error:' -Context 3, 3
        if ($hits) { $hits | Select-Object -First 40 | ForEach-Object { $_.Context.PreContext; $_.Line; $_.Context.PostContext; '---' } }
        else { Get-Content $log -Tail 30 }
        exit $rc
    }
    Write-Output 'SIM READY'
    exit 0
}

if ($Mode -eq 'boot') {
    exit (Gui "xcrun simctl bootstatus $sim -b | tail -2")
}

if ($Mode -eq 'shot') {
    if (-not $Name) { $Name = ($Arg -replace '[^A-Za-z0-9_-]', '_'); if (-not $Name) { $Name = 'root' } }
    Launch $Arg ''
    $rc = Gui "xcrun simctl io $sim screenshot /tmp/drx-shot.png >/dev/null"
    if ($rc -ne 0) { Write-Output 'error: screenshot failed (black screen? try: sim.ps1 snap)'; exit 1 }
    Fetch '/tmp/drx-shot.png' $Name
    exit 0
}

if ($Mode -eq 'snap') {
    if (-not $Name) { $Name = 'snap-' + ($Arg -replace '[^A-Za-z0-9_-]', '_') }
    Launch $Arg 'SIMCTL_CHILD_DRX_SNAPSHOT=3'
    & $ssh @sshOpts -p $Port $Remote "~/bin/drx-gui 'cp `"`$(xcrun simctl get_app_container $sim $bundle data)/Documents/drx-snapshot.png`" /tmp/drx-snap.png'"
    if ($LASTEXITCODE -ne 0) { Write-Output 'error: no snapshot'; exit 1 }
    Fetch '/tmp/drx-snap.png' $Name
    exit 0
}

if ($Mode -eq 'url') {
    if (-not $Name) { $Name = 'url' }
    $rc = Gui "xcrun simctl openurl $sim `"$Arg`" && sleep $Wait && xcrun simctl io $sim screenshot /tmp/drx-shot.png >/dev/null"
    if ($rc -ne 0) { Write-Output 'error: openurl/screenshot failed'; exit 1 }
    Fetch '/tmp/drx-shot.png' $Name
    exit 0
}

if ($Mode -eq 'cmd') {
    exit (Gui $Arg)
}

Write-Output "unknown mode $Mode"
exit 1
