# Собирает релиз и установщик: dist\ZapretLauncher-Setup-<версия>.exe
# Запуск: powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1 [-Version 0.2.0] [-SkipBuild]
param(
  [string]$Version,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

if (-not $Version) {
  $line = Select-String -Path "$root\pubspec.yaml" -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
  if (-not $line) { throw 'Не нашёл версию в pubspec.yaml' }
  $Version = $line.Matches[0].Groups[1].Value
}

$appInfo = Get-Content "$root\lib\src\app_info.dart" -Raw
if ($appInfo -notmatch "version = '$([regex]::Escape($Version))'") {
  throw "Версия $Version не совпадает с AppInfo.version в lib\src\app_info.dart — поправьте одно из двух"
}

if (-not $SkipBuild) {
  # Встроенный zapret — без него установщик не работал бы сразу после установки.
  & "$PSScriptRoot\fetch_zapret.ps1"
  Push-Location $root
  try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows --release не удался' }
  } finally { Pop-Location }
}

$iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source }
if (-not $iscc) { throw 'Нет Inno Setup 6: winget install JRSoftware.InnoSetup' }

$source = "$root\build\windows\x64\runner\Release"
& $iscc "/DAppVersion=$Version" "/DSourceDir=$source" "$root\installer\ZapretLauncher.iss"
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup не собрал установщик' }

$out = "$root\dist\ZapretLauncher-Setup-$Version.exe"
$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
"Готово: $out"
"SHA-256: $hash"
