$env:ANDROID_HOME = 'D:\222\Sdk'
$env:ANDROID_SDK_ROOT = 'D:\222\Sdk'

$platformTools = Join-Path $env:ANDROID_HOME 'platform-tools'
$cmdlineTools = Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin'
$emulatorTools = Join-Path $env:ANDROID_HOME 'emulator'

$paths = @($platformTools, $cmdlineTools, $emulatorTools) |
  Where-Object { Test-Path $_ }

foreach ($path in $paths) {
  if (($env:Path -split ';') -notcontains $path) {
    $env:Path = "$path;$env:Path"
  }
}

Write-Host "ANDROID_HOME=$env:ANDROID_HOME"
Write-Host "Android SDK paths added for this terminal session."
