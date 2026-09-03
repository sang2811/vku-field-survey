@echo off
set "ANDROID_HOME=D:\222\Sdk"
set "ANDROID_SDK_ROOT=D:\222\Sdk"

if exist "%ANDROID_HOME%\platform-tools" set "PATH=%ANDROID_HOME%\platform-tools;%PATH%"
if exist "%ANDROID_HOME%\cmdline-tools\latest\bin" set "PATH=%ANDROID_HOME%\cmdline-tools\latest\bin;%PATH%"
if exist "%ANDROID_HOME%\emulator" set "PATH=%ANDROID_HOME%\emulator;%PATH%"

echo ANDROID_HOME=%ANDROID_HOME%
echo Android SDK paths added for this Command Prompt session.
