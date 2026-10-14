@echo off
setlocal
cd /d "%~dp0"
where flutter >nul 2>nul
if errorlevel 1 (
    echo Flutter SDK was not found on PATH.
    pause
    exit /b 1
)
flutter pub get
if errorlevel 1 (
    echo Dependency resolution failed.
    pause
    exit /b 1
)
flutter build apk --release
if errorlevel 1 (
    echo APK build failed. Check "flutter doctor" and Android SDK setup.
    pause
    exit /b 1
)
echo APK created at build\app\outputs\flutter-apk\app-release.apk
pause
