@echo off
setlocal EnableExtensions

rem ==========================================================================
rem  GUET Dr.COM launcher
rem  Runs guet_drcom.ps1 so you don't have to type the PowerShell flags.
rem    - Double-click  -> interactive menu
rem    - With args     -> forwarded straight to the script
rem                       e.g.  guet_drcom.bat login
rem ==========================================================================

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%guet_drcom.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] guet_drcom.ps1 was not found next to this launcher.
    echo         Expected: "%PS_SCRIPT%"
    echo.
    pause
    exit /b 1
)

rem Prefer PowerShell 7 (pwsh) when available, otherwise Windows PowerShell.
set "PS_EXE=powershell"
where pwsh >nul 2>nul && set "PS_EXE=pwsh"

rem Any arguments -> forward as-is (CLI / shortcut / scheduled task use).
if not "%~1"=="" goto forward

:menu
cls
echo ==================================
echo    GUET Dr.COM   Launcher
echo ==================================
echo    [1] init      set account / carrier
echo    [2] login     re-login
echo    [3] logout    test logout
echo    [4] auto      enable auto-reconnect
echo    [5] disable   disable auto-reconnect
echo    [6] help      show status / help
echo    [0] exit
echo ==================================
set "choice="
set /p "choice=Select an option: "

if "%choice%"=="1" ( set "SUB=init"    & goto run )
if "%choice%"=="2" ( set "SUB=login"   & goto run )
if "%choice%"=="3" ( set "SUB=logout"  & goto run )
if "%choice%"=="4" ( set "SUB=auto"    & goto run )
if "%choice%"=="5" ( set "SUB=disable" & goto run )
if "%choice%"=="6" ( set "SUB=help"    & goto run )
if "%choice%"=="0" exit /b 0
goto menu

:run
echo.
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %SUB%
echo.
pause
goto menu

:forward
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
