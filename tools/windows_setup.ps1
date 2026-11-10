# Generates the Windows desktop runner (if missing) and brands it:
# title "TVCleanzer", phone-like window size, product names, icon.
# Safe to run again. Used by CI (.github/workflows/windows.yml) and locally:
#   powershell -ExecutionPolicy Bypass -File tools\windows_setup.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not (Test-Path 'windows\runner\main.cpp')) {
  flutter create --platforms=windows --org com.tvcleanzer --project-name tvcleanzer .
  if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
}

function Edit-File($path, [scriptblock]$fn) {
  $t = [IO.File]::ReadAllText($path)
  $n = & $fn $t
  if ($n -ne $t) { [IO.File]::WriteAllText($path, $n, (New-Object Text.UTF8Encoding($true))) }
}

Edit-File 'windows\runner\main.cpp' {
  param($t)
  $t = $t -replace 'Win32Window::Size size\(\d+, \d+\);', 'Win32Window::Size size(480, 900);'
  $t -replace 'window\.Create\(L"[^"]*"', 'window.Create(L"TVCleanzer"'
}

Edit-File 'windows\runner\Runner.rc' {
  param($t)
  $t = $t -replace 'VALUE "CompanyName", "[^"]*"', 'VALUE "CompanyName", "TVCleanzer"'
  $t = $t -replace 'VALUE "FileDescription", "[^"]*"', 'VALUE "FileDescription", "TVCleanzer"'
  $t = $t -replace 'VALUE "ProductName", "[^"]*"', 'VALUE "ProductName", "TVCleanzer"'
  $t = $t -replace 'VALUE "InternalName", "[^"]*"', 'VALUE "InternalName", "TVCleanzer"'
  $t -replace 'VALUE "OriginalFilename", "[^"]*"', 'VALUE "OriginalFilename", "TVCleanzer.exe"'
}

Edit-File 'windows\CMakeLists.txt' {
  param($t)
  $t -replace 'set\(BINARY_NAME "[^"]*"\)', 'set(BINARY_NAME "TVCleanzer")'
}

flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
dart run flutter_launcher_icons
if ($LASTEXITCODE -ne 0) { throw 'icons failed' }
Write-Host 'Windows runner ready.'
