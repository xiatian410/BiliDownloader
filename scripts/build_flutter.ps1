$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this script on Windows with PowerShell 7 and Visual Studio C++ tools.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $projectRoot 'flutter_app')
try {
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    $output = Join-Path $projectRoot 'artifacts'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    Compress-Archive -Path 'build/windows/x64/runner/Release/*' -DestinationPath (Join-Path $output 'BiliDownloader-windows-x64.zip') -Force
} finally { Pop-Location }
