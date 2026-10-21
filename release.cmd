@echo off
setlocal

:: ============================================================================
:: Delphi Refactoring Light - publish the current version as a GitHub release
::
:: Builds the package Release for both platforms and the MCP bridge, takes the
:: notes out of CHANGELOG.md and creates the release with the "gh" CLI, with
:: the compiled .bpl files attached (issue #48: a team can then roll out an
:: update without building anything).
::
::   release.cmd ["Title of the release"] [--draft] [--skip-tests] [--with-maps]
::   release.cmd --upload-only [--skip-tests] [--with-maps]
::
:: --upload-only attaches the binaries to a release that EXISTS already -
:: the case when the release was published from the web page and the files
:: are added afterwards (which is how 2.0.1 happened).
::
:: Nothing is published before the build and the test suite have passed, and
:: the version comes from Source\Expert.Version.pas - the one place the four
:: version strings are checked against (TVersionTests).
:: The build output goes to .\Release, never to the installed BPL, so this
:: works while the IDE has the package loaded.
:: ============================================================================

set RL_BDSVER=37.0
set RL_RSVARS=C:\Program Files (x86)\Embarcadero\Studio\%RL_BDSVER%\bin\rsvars.bat
set RL_REPO=%~dp0
set RL_OUT=%~dp0Release
set RL_TITLE=
set RL_DRAFT=
set RL_TESTS=1
set RL_MAPS=0
set RL_UPLOAD=0
set RL_FAIL=

:args
if "%~1"=="" goto :version
if /i "%~1"=="--draft" set RL_DRAFT=--draft& shift & goto :args
if /i "%~1"=="--skip-tests" set RL_TESTS=0& shift & goto :args
if /i "%~1"=="--with-maps" set RL_MAPS=1& shift & goto :args
if /i "%~1"=="--upload-only" set RL_UPLOAD=1& shift & goto :args
if "%RL_TITLE%"=="" set RL_TITLE=%~1& shift & goto :args
echo Unknown argument: %~1
goto :usage

:: ---------------------------------------------------------------- version --
:version
for /f "tokens=2 delims='" %%V in ('findstr /c:"PluginVersion = " "%RL_REPO%Source\Expert.Version.pas"') do set RL_VER=%%V
if not defined RL_VER echo Could not read PluginVersion from Source\Expert.Version.pas.& goto :fail
if "%RL_TITLE%"=="" set RL_TITLE=Release %RL_VER%
echo.
echo ============================================
echo  Release %RL_VER%
echo ============================================
echo.
goto :state

:: ------------------------------------------------------------ the commit --
:: A release names a COMMIT, so everything has to be in it and pushed - and
:: the tag must not exist yet, or gh would attach these binaries to another
:: version's release.
:state
for /f "delims=" %%S in ('git -C "%RL_REPO%." status --porcelain') do set RL_DIRTY=1
if defined RL_DIRTY echo The working tree has changes - commit them first.& goto :fail
git -C "%RL_REPO%." rev-parse -q --verify "refs/tags/%RL_VER%" >nul
if "%RL_UPLOAD%"=="1" goto :existing
if not errorlevel 1 echo Tag %RL_VER% already exists - bump the version first.& goto :fail
for /f "delims=" %%H in ('git -C "%RL_REPO%." rev-parse HEAD') do set RL_HEAD=%%H
for /f "delims=" %%U in ('git -C "%RL_REPO%." rev-parse "@{u}"') do set RL_UP=%%U
if not "%RL_HEAD%"=="%RL_UP%" echo HEAD is not pushed - push first, a release tags the remote.& goto :fail
goto :notes

:: --upload-only: the release is there, so the question is a different one -
:: do these binaries belong to the commit the tag names? Anything under
:: Source, Packages, Mcp or Standalone that changed since the tag would make
:: the build something else than what was released, and that is refused
:: rather than explained away. Everything else (a changelog, this script)
:: cannot reach the artefacts.
:existing
if errorlevel 1 echo There is no tag %RL_VER% - without --upload-only this script creates it.& goto :fail
gh release view %RL_VER% >nul 2>&1
if errorlevel 1 echo There is no release %RL_VER% to upload to.& goto :fail
for /f "delims=" %%F in ('git -C "%RL_REPO%." diff --name-only "%RL_VER%..HEAD"') do call :srcdiff "%%F"
if defined RL_SRCDIFF echo Sources changed since the tag %RL_VER% (%RL_SRCDIFF%) - check out the tag to build it.& goto :fail
echo Release %RL_VER% exists, and no source changed since its tag.
goto :build

:srcdiff
echo %~1| findstr /i /b /c:"Source/" /c:"Packages/" /c:"Mcp/" /c:"Standalone/" >nul
if not errorlevel 1 set RL_SRCDIFF=%~1
exit /b 0

:: ----------------------------------------------------------------- notes --
:: ONE source of truth: the release body is the CHANGELOG section of this
:: version, so the page and the repository can never drift apart.
:notes
if "%RL_UPLOAD%"=="1" goto :build
set RL_NOTES=%RL_OUT%\notes-%RL_VER%.md
if not exist "%RL_OUT%" mkdir "%RL_OUT%"
:: BOTH ends are pinned to UTF-8: Windows PowerShell reads a file as ANSI by
:: default, which turned every em dash into "a-tilde EUR" (measured), and its
:: -Encoding UTF8 would write a BOM into the release body.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = [IO.File]::ReadAllText('%RL_REPO%CHANGELOG.md', [Text.Encoding]::UTF8); $p = '(?ms)^## ' + [regex]::Escape($env:RL_VER) + '\s.*?(?=^---\s*$|\z)'; $m = [regex]::Match($t, $p); if (-not $m.Success) { exit 1 }; [IO.File]::WriteAllText('%RL_NOTES%', $m.Value.TrimEnd(), (New-Object Text.UTF8Encoding $false))"
if errorlevel 1 echo CHANGELOG.md has no "## %RL_VER%" section - write the notes first.& goto :fail
echo Notes: %RL_NOTES%
goto :build

:: ----------------------------------------------------------------- build --
:build
if not exist "%RL_RSVARS%" echo RAD Studio %RL_BDSVER% not found at "%RL_RSVARS%".& goto :fail
call "%RL_RSVARS%" >nul
for %%P in (Win32 Win64) do (
  echo === package %%P
  msbuild "%RL_REPO%Packages\DelphiRefactoringLight.dproj" /t:Build /tv:4.0 ^
    /p:Config=Release /p:Platform=%%P ^
    /p:DCC_BplOutput="%RL_OUT%\%%P" /p:DCC_DcpOutput="%RL_OUT%\%%P" ^
    /p:DCC_HppOutput="%RL_OUT%\%%P" /v:minimal /nologo
  if errorlevel 1 set RL_FAIL=1
)
echo === MCP bridge Win32
msbuild "%RL_REPO%Mcp\RefactoringLightMcp.dproj" /t:Build /tv:4.0 ^
  /p:Config=Release /p:Platform=Win32 /v:minimal /nologo
if errorlevel 1 set RL_FAIL=1
if defined RL_FAIL echo A build failed - nothing was published.& goto :fail
goto :tests

:: ----------------------------------------------------------------- tests --
:: Both platforms, because a Win64-only error is invisible to a Win32 run.
:tests
if "%RL_TESTS%"=="0" echo Tests skipped.& goto :collect
pushd "%RL_REPO%Tests"
call "%RL_REPO%Tests\run-tests.cmd" Win32
if errorlevel 1 set RL_FAIL=1
call "%RL_REPO%Tests\run-tests.cmd" Win64
if errorlevel 1 set RL_FAIL=1
popd
if defined RL_FAIL echo The test suite failed - nothing was published.& goto :fail
goto :collect

:: --------------------------------------------------------------- collect --
:: The two packages carry the same file name, so the platform goes into the
:: asset name - a download must say which IDE it is for.
:collect
set RL_ASSETS="%RL_OUT%\DelphiRefactoringLight370-Win32.bpl" "%RL_OUT%\DelphiRefactoringLight370-Win64.bpl" "%RL_OUT%\RefactoringLightMcp.exe"
copy /y "%RL_OUT%\Win32\DelphiRefactoringLight370.bpl" "%RL_OUT%\DelphiRefactoringLight370-Win32.bpl" >nul
if errorlevel 1 set RL_FAIL=1
copy /y "%RL_OUT%\Win64\DelphiRefactoringLight370.bpl" "%RL_OUT%\DelphiRefactoringLight370-Win64.bpl" >nul
if errorlevel 1 set RL_FAIL=1
copy /y "%RL_REPO%Mcp\Bin\RefactoringLightMcp.exe" "%RL_OUT%\RefactoringLightMcp.exe" >nul
if errorlevel 1 set RL_FAIL=1
if "%RL_MAPS%"=="1" call :addmap
if defined RL_FAIL echo An artefact is missing - nothing was published.& goto :fail
goto :publish

:: The detailed map resolves an address from a crash log, but only the map of
:: exactly THIS build does - hence an option rather than a default (25 MB).
:addmap
copy /y "%RL_OUT%\Win32\DelphiRefactoringLight370.map" "%RL_OUT%\DelphiRefactoringLight370-Win32.map" >nul
if errorlevel 1 set RL_FAIL=1
copy /y "%RL_OUT%\Win64\DelphiRefactoringLight370.map" "%RL_OUT%\DelphiRefactoringLight370-Win64.map" >nul
if errorlevel 1 set RL_FAIL=1
set RL_ASSETS=%RL_ASSETS% "%RL_OUT%\DelphiRefactoringLight370-Win32.map" "%RL_OUT%\DelphiRefactoringLight370-Win64.map"
exit /b 0

:: --------------------------------------------------------------- publish --
:publish
if "%RL_UPLOAD%"=="1" goto :upload
echo.
echo Creating release %RL_VER% %RL_DRAFT%
gh release create %RL_VER% --title "%RL_TITLE%" --notes-file "%RL_NOTES%" %RL_DRAFT% %RL_ASSETS%
if errorlevel 1 echo gh failed - the release was NOT created.& goto :fail
goto :verify

:: No --clobber: replacing a file somebody may already have downloaded is a
:: decision, not a retry.
:upload
echo.
echo Attaching the binaries to release %RL_VER%
gh release upload %RL_VER% %RL_ASSETS%
if errorlevel 1 echo gh failed - nothing was attached. An asset of that name may already be there; remove it on the release page first.& goto :fail
goto :verify

:verify
echo.
echo Attached:
gh release view %RL_VER% --json assets -q ".assets[] | .name + \"  \" + (.size|tostring) + \" bytes\""
echo.
echo Done: https://github.com/jaenicke/DelphiRefactoringLight/releases/tag/%RL_VER%
goto :done

:usage
echo.
echo   release.cmd ["Title"] [--draft] [--skip-tests] [--with-maps]
echo.
echo   The version comes from Source\Expert.Version.pas, the notes from the
echo   matching "## version" section of CHANGELOG.md.
goto :fail

:fail
endlocal
exit /b 1

:done
endlocal
exit /b 0
