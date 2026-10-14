@echo off
setlocal
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
    echo Flutter SDK was not found on PATH.
    echo Install Flutter and Android Studio, then run "flutter doctor".
    pause
    exit /b 1
)
flutter pub get
if errorlevel 1 (
    echo Dependency resolution failed.
    pause
    exit /b 1
)
flutter run
if errorlevel 1 (
    echo AstroSophy stopped with an error.
    pause
    exit /b 1
)
