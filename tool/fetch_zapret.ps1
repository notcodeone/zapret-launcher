# Встроенный zapret: скачивает релиз zapret-discord-youtube, версия которого записана
# в assets\zapret\version.txt, в assets\zapret\zapret-<версия>.zip — оттуда он попадает
# в сборку. Хэш сверяется с тем, что публикует GitHub. Уже скачанный архив не качается снова.
#
#   powershell -ExecutionPolicy Bypass -File tool\fetch_zapret.ps1
#
# Встроить новую версию zapret: поменять version.txt и добавить запись в CHANGELOG.md.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path $PSScriptRoot
$dir = Join-Path $root 'assets\zapret'
$version = (Get-Content (Join-Path $dir 'version.txt') -Raw).Trim()
$zip = Join-Path $dir "zapret-$version.zip"

# Архивы прежних версий в сборку не нужны.
Get-ChildItem $dir -Filter 'zapret-*.zip*' | Where-Object { $_.FullName -ne $zip } |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName }

if (Test-Path $zip) {
  "Встроенный zapret $version уже скачан"
  return
}

$repo = 'Flowseal/zapret-discord-youtube'
$headers = @{ 'User-Agent' = 'ZapretLauncher-build'; 'Accept' = 'application/vnd.github+json' }
# В GitHub Actions — с токеном: без него лимит запросов к API общий на всех.
if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$version" -Headers $headers
$asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $asset) { throw "В релизе zapret $version нет архива .zip" }
if (-not $asset.digest) { throw "GitHub не опубликовал хэш архива zapret $version — сверить не с чем" }

# Сначала во временный файл: оборванная загрузка не должна выглядеть как готовый архив.
$part = "$zip.part"
Invoke-WebRequest $asset.browser_download_url -OutFile $part -Headers @{ 'User-Agent' = 'ZapretLauncher-build' }
$hash = (Get-FileHash $part -Algorithm SHA256).Hash.ToLower()
$expected = ($asset.digest -replace '^sha256:', '').ToLower()
if ($hash -ne $expected) {
  Remove-Item -LiteralPath $part
  throw "Архив zapret $version не совпал с опубликованным: $hash вместо $expected"
}
Move-Item -LiteralPath $part -Destination $zip
"Встроенный zapret ${version}: $($asset.name), SHA-256 $hash"
