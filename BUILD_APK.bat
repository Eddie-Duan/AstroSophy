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
rem The product is handed over as AstroSophy.apk. `flutter build apk` names it
rem app-release.apk and there is no supported way to change that from Gradle
rem (AGP 8 dropped archivesBaseName, and the variant API only exposes a
rem read-only Provider<Directory> for the APK), so the rename happens here.
set "APK=build\app\outputs\flutter-apk\AstroSophy.apk"
if not exist "%APK%" if exist "build\app\outputs\flutter-apk\app-release.apk" (
    move /y "build\app\outputs\flutter-apk\app-release.apk" "%APK%" >nul
)
if not exist "%APK%" (
    echo APK was built, but not at the expected path. Look in build\app\outputs\flutter-apk\.
    pause
    exit /b 1
)
echo APK created at %APK%
pause
