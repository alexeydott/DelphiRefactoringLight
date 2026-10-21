@echo off
setlocal
rem Optional argument: Delphi 11 installation directory.
set "DELPHI11=%~1"
if not defined DELPHI11 for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\22.0" /v RootDir 2^>nul') do set "DELPHI11=%%B"
if not defined DELPHI11 for /f "tokens=2,*" %%A in ('reg query "HKLM\Software\Embarcadero\BDS\22.0" /v RootDir /reg:32 2^>nul') do set "DELPHI11=%%B"
if not exist "%DELPHI11%\bin\rsvars.bat" (
  echo Delphi 11 not found. Pass its installation directory as the first argument.
  exit /b 1
)
call "%DELPHI11%\bin\rsvars.bat"
if errorlevel 1 exit /b 1
pushd "%~dp0"
rem Delphi 11 uses a Win32 IDE. Keep its DCUs separate from other compilers.
msbuild Packages\DelphiRefactoringLight.dproj /t:Rebuild /p:Config=Release /p:Platform=Win32 /p:DCC_DcuOutput=..\DCU\Delphi11\Win32\Release /p:DCC_BplOutput=..\Output\Delphi11 /p:DCC_DcpOutput=..\Output\Delphi11 /v:minimal
set "BUILD_RESULT=%ERRORLEVEL%"
popd
exit /b %BUILD_RESULT%
