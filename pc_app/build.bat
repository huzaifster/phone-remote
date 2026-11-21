@echo off
setlocal
cd /d "%~dp0"
echo ===== Phone Remote: one-click build =====
echo.

rem --- 1. Make sure Python 3.13 is available ---
py -3.13 --version >nul 2>&1
if errorlevel 1 (
  echo Python 3.13 was not found. Installing it now.
  echo If Windows asks for permission, click Yes.
  winget install -e --id Python.Python.3.13 --accept-package-agreements --accept-source-agreements
  py -3.13 --version >nul 2>&1
  if errorlevel 1 (
    echo.
    echo Python 3.13 is not ready yet.
    echo If it just installed, close this window and double-click build.bat again.
    echo Otherwise install Python 3.13 from https://www.python.org/downloads/ and run this again.
    pause
    exit /b 1
  )
)

rem --- 2. Private environment so nothing clashes with your other Python ---
if not exist .venv\Scripts\python.exe py -3.13 -m venv .venv
if not exist .venv\Scripts\python.exe (
  echo Could not create the build environment.
  pause
  exit /b 1
)
set PY=.venv\Scripts\python.exe

echo.
echo Installing required packages. This can take a few minutes...
"%PY%" -m pip install --upgrade pip
"%PY%" -m pip install -r requirements.txt pyinstaller
if errorlevel 1 (
  echo.
  echo Installing packages failed. Scroll up to read the error.
  pause
  exit /b 1
)

rem --- 3. Make the icon if it is missing, then build the single .exe ---
if not exist icon.ico "%PY%" make_icons.py
if not exist icon.ico (
  echo Could not create icon.ico
  pause
  exit /b 1
)

for /f "delims=" %%i in ('"%PY%" -c "import sys,os;print(os.path.join(sys.base_prefix,'python3.dll'))"') do set PY3DLL=%%i
set EXTRA=
if exist "%PY3DLL%" set EXTRA=--add-binary "%PY3DLL%;."

rem Close a running copy first, otherwise Windows won't let the old .exe be replaced
taskkill /f /im PhoneRemote.exe >nul 2>&1
timeout /t 2 /nobreak >nul

if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist dist (
  echo.
  echo Could not delete the old dist folder. Something is still using PhoneRemote.exe.
  echo Close PhoneRemote from the tray icon ^(right-click, Quit^), close any Explorer
  echo window showing the dist folder, then run build.bat again.
  pause
  exit /b 1
)

echo.
echo Building PhoneRemote.exe. This takes a few minutes...
"%PY%" -m PyInstaller --clean --noconsole --onefile --name PhoneRemote --icon icon.ico --add-data "icon.ico;." --hidden-import pystray._win32 --collect-all cryptography --collect-all zeroconf %EXTRA% app.py
if errorlevel 1 (
  echo.
  echo BUILD FAILED. Scroll up to read the error.
  pause
  exit /b 1
)

rem --- 4. Tidy up ---
if exist build rmdir /s /q build
if exist PhoneRemote.spec del PhoneRemote.spec

echo.
echo ===== Done! =====
echo Your app is: dist\PhoneRemote.exe
echo Double-click it to run. Right-click its tray icon to pair a phone.
if defined NOPAUSE exit /b 0
explorer dist
pause
