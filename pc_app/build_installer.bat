@echo off
setlocal
cd /d "%~dp0"
echo ===== Phone Remote: build the setup file =====
echo.

rem --- 1. Make sure PhoneRemote.exe exists (and offer to rebuild it) ---
set NEEDBUILD=0
if not exist dist\PhoneRemote.exe (
  set NEEDBUILD=1
) else (
  choice /c YN /m "Rebuild PhoneRemote.exe first? (choose Y if you changed the app code)"
  if not errorlevel 2 set NEEDBUILD=1
)
if "%NEEDBUILD%"=="1" (
  set NOPAUSE=1
  call build.bat
)
if not exist dist\PhoneRemote.exe (
  echo.
  echo dist\PhoneRemote.exe was not built. Fix the error above and run this again.
  pause
  exit /b 1
)

rem --- 2. Find Inno Setup (the free tool that makes the setup file), install it if missing ---
call :find_iscc
if not defined ISCC (
  echo.
  echo Inno Setup was not found. Installing it now.
  echo If Windows asks for permission, click Yes.
  winget install -e --id JRSoftware.InnoSetup --accept-package-agreements --accept-source-agreements
  call :find_iscc
)
if not defined ISCC (
  echo.
  echo Could not find or install Inno Setup.
  echo Install it from https://jrsoftware.org/isdl.php and run this again.
  pause
  exit /b 1
)

rem --- 3. Make the single setup file ---
if not exist icon.ico "%~dp0.venv\Scripts\python.exe" make_icons.py
echo.
echo Building the setup file...
"%ISCC%" PhoneRemote.iss
if errorlevel 1 (
  echo.
  echo SETUP BUILD FAILED. Scroll up to read the error.
  pause
  exit /b 1
)

echo.
echo ===== Done! =====
echo Your installer is: installer_output\PhoneRemote-Setup.exe
echo Copy that ONE file to any Windows PC and double-click it.
explorer installer_output
pause
exit /b 0

:find_iscc
set "ISCC="
for %%P in ("%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" "%ProgramFiles%\Inno Setup 6\ISCC.exe" "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe") do (
  if exist "%%~P" set "ISCC=%%~P"
)
exit /b 0
