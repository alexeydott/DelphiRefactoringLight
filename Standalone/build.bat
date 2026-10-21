@echo off
setlocal
rem Standalone Refactoring Light - msbuild driver.
rem
rem Override the config from the command line: build.bat Release
rem Optional second argument: RAD Studio installation directory.
rem Otherwise use the active RAD Studio environment or the Delphi 12 registry.
set "RADSTUDIO=%~2"
if not defined RADSTUDIO set "RADSTUDIO=%BDS%"
if not defined RADSTUDIO for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\23.0" /v RootDir 2^>nul') do set "RADSTUDIO=%%B"
if not exist "%RADSTUDIO%\bin\rsvars.bat" (
  echo RAD Studio not found. Pass its installation directory as the second argument.
  exit /b 1
)
call "%RADSTUDIO%\bin\rsvars.bat"
if errorlevel 1 exit /b 1
pushd "%~dp0"
if not exist DCU mkdir DCU
if not exist Output mkdir Output
set "CONFIG=%~1"
if "%CONFIG%"=="" set CONFIG=Release
msbuild RefactoringLightStandalone.dproj /t:Build /p:Config=%CONFIG% /p:Platform=Win32 /p:DCC_ExeOutput=.\Output /p:DCC_DcuOutput=.\DCU\Win32\%CONFIG% /v:minimal
set "BUILD_RESULT=%ERRORLEVEL%"
popd
echo Exit Code: %BUILD_RESULT%
exit /b %BUILD_RESULT%
