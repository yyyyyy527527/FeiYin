@echo off
rem FeiYin sync server launcher (Windows)
rem Starts the Node service in the foreground. Used by the scheduled task.
setlocal
cd /d "%~dp0"

if "%PORT%"=="" set "PORT=8787"
if "%DATA_DIR%"=="" set "DATA_DIR=%~dp0data"
rem AGC Client ID：只接受 aud 等于它的华为令牌，防止别的应用拿自己的令牌来换账号
if "%EXPECTED_CLIENT_ID%"=="" set "EXPECTED_CLIENT_ID=6917620983568967225"

rem Locate node: PATH first, then the bundled runtime.
set "NODE_EXE="
where node >nul 2>nul && set "NODE_EXE=node"
if not defined NODE_EXE (
  for /d %%d in ("%USERPROFILE%\.workbuddy\binaries\node\versions\*") do (
    if exist "%%d\node.exe" set "NODE_EXE=%%d\node.exe"
  )
)
if not defined NODE_EXE (
  echo [feiyin-sync] node.exe not found. Install Node.js 18+ from https://nodejs.org
  exit /b 1
)

if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
if not exist "logs" mkdir "logs"

echo [feiyin-sync] node  = %NODE_EXE%
echo [feiyin-sync] port  = %PORT%
echo [feiyin-sync] data  = %DATA_DIR%
echo.

"%NODE_EXE%" index.js
echo.
echo [feiyin-sync] exited with code %ERRORLEVEL%
