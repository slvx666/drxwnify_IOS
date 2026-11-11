# Выпуск на GitHub: пуш ветки ios, тег v<версия>, релиз с .ipa и заметками.
# Запуск: powershell -ExecutionPolicy Bypass -File ios\scripts\release.ps1
# Версия — MARKETING_VERSION из project.yml; .ipa — ios\out\Drxwnify-<версия>.ipa (после build.ps1);
# заметки — ios\release-notes\<версия>.md (обязательно, по-русски, коротко: что нового и что проверить).
param(
    [string]$Repo = "slvx666/drxwnify_IOS",
    [switch]$Prerelease
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$version = (Select-String -Path "project.yml" -Pattern 'MARKETING_VERSION:\s*"([^"]+)"').Matches[0].Groups[1].Value
if (-not $version) { throw "Не нашёл MARKETING_VERSION в project.yml" }
$ipa = Join-Path $root "out\Drxwnify-$version.ipa"
$notes = Join-Path $root "release-notes\$version.md"
if (-not (Test-Path $ipa)) { throw "Нет $ipa — сначала scripts\build.ps1" }
if (-not (Test-Path $notes)) { throw "Нет заметок $notes" }

$dirty = git status --porcelain
if ($dirty) { throw "Есть незакоммиченные изменения в ios/: сначала коммит" }

git push origin ios
if ($LASTEXITCODE -ne 0) { throw "git push не прошёл" }

$tag = "v$version"
$exists = git tag --list $tag
if (-not $exists) {
    git tag -a $tag -m "Drxwnify $version"
    git push origin $tag
    if ($LASTEXITCODE -ne 0) { throw "Не удалось запушить тег $tag" }
}

$flags = @()
if ($Prerelease) { $flags += "--prerelease" }
gh release view $tag -R $Repo *> $null
if ($LASTEXITCODE -eq 0) {
    gh release upload $tag $ipa -R $Repo --clobber
    gh release edit $tag -R $Repo --notes-file $notes
} else {
    gh release create $tag $ipa -R $Repo --title "Drxwnify $version" --notes-file $notes @flags
}
if ($LASTEXITCODE -ne 0) { throw "gh release не прошёл" }
Write-Host "ВЫПУЩЕНО: https://github.com/$Repo/releases/tag/$tag"
