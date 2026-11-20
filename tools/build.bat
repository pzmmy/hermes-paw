@echo off
rem ============================================================
rem  HermesPaw build + sign + install : Windows (DevEco Studio 6.x)
rem  Verified on real device 2026-10-28 (hvigorw 6.26.8):
rem    JAVA_HOME      = %DEVECO%\jbr
rem    DEVECO_SDK_HOME= %DEVECO%\sdk
rem    PATH += %JAVA_HOME%\bin + %DEVECO%\tools\node (hvigorw needs node.exe,
rem            the Node bundled with DevEco)
rem  Usage: pure-CLI run is fine (hvigorw wrapper is committed);
rem         the very first run still needs the project opened once in
rem         DevEco to configure signing, then double-click this script
rem         or run it from cmd.
rem  NOTE: keep this file CRLF line endings + ASCII only (cmd.exe requirement).
rem ============================================================
setlocal

rem --- DevEco install location (edit ONLY this line if yours differs) ---
set "DEVECO=D:\Program Files\Huawei\DevEco Studio"

rem --- the three env vars (missing any = failure, verified via CLI) ---
set "JAVA_HOME=%DEVECO%\jbr"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "PATH=%JAVA_HOME%\bin;%DEVECO%\tools\node;%PATH%"

cd /d "%~dp0.."

if not exist "hvigorw.bat" (
  echo [build.bat] hvigorw.bat not found: open the project in DevEco first, wait for sync, then retry.
  exit /b 1
)

echo [build.bat] Building debug HAP ...
call hvigorw.bat --mode module -p product=default -p buildMode=debug assembleHap
if errorlevel 1 (
  echo [build.bat] Build FAILED - see hvigor output above for the cause.
  exit /b 1
)

set "HAP="
if exist "entry\build\default\outputs\default\entry-default-signed.hap" set "HAP=entry\build\default\outputs\default\entry-default-signed.hap"
if not defined HAP if exist "entry\build\default\outputs\default\entry-default-unsigned.hap" set "HAP=entry\build\default\outputs\default\entry-default-unsigned.hap"
if not defined HAP (
  echo [build.bat] HAP not found - check entry\build\default\outputs\.
  exit /b 1
)

echo [build.bat] Installing %HAP% ...
hdc install -r "%HAP%"
if errorlevel 1 (
  echo [build.bat] Install FAILED - check the device is USB-connected and hdc is online (hdc list targets).
  exit /b 1
)
echo [build.bat] Done.
endlocal
