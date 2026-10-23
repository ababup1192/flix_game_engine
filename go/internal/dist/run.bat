@echo off
rem Starts {{.Game}} on Windows x64. Saves and logs go to %LOCALAPPDATA%\{{.Game}}.
rem   FGE_JAVA_OPTS  extra java flags (after the defaults, so they win)
rem   FGE_DATA_DIR   where saves and logs are written
rem   FGE_ENTRY      entry point (default main = play)
rem ASCII only: cmd reads .bat files in the console code page, so other characters can break parsing.
setlocal EnableExtensions

rem Restart minimized so the console window does not sit in front of the game.
if /i not "%~1"=="--here" (
  start "" /min "%~f0" --here
  exit /b
)

set "HERE=%~dp0"
set "GAME={{.Game}}"
if defined FGE_DATA_DIR (set "DATA=%FGE_DATA_DIR%") else (set "DATA=%LOCALAPPDATA%\%GAME%")
if not exist "%DATA%\logs" mkdir "%DATA%\logs"
if not exist "%DATA%\cache\lwjgl" mkdir "%DATA%\cache\lwjgl"
set "LOG=%DATA%\logs\run.log"
if exist "%LOG%" move /y "%LOG%" "%DATA%\logs\run.prev.log" >nul
echo [run] %DATE% %TIME% game=%HERE% data=%DATA%>>"%LOG%"

rem The game reads assets relative to the working directory and writes saves next to them.
rem Folders are linked as junctions (symlinks need admin rights); files are copied.
rem rmdir removes a junction or an empty folder only; a real folder left behind stops the start.
for /d %%D in ("%HERE%game\*") do (
  rmdir "%DATA%\%%~nxD" 2>nul
  if exist "%DATA%\%%~nxD" (
    echo [run] %DATA%\%%~nxD is not a junction. Delete the old copy and start again.>>"%LOG%"
    exit /b 1
  )
  mklink /J "%DATA%\%%~nxD" "%%~fD" >nul
)
for %%F in ("%HERE%game\*") do if /i not "%%~nxF"=="game.jar" copy /y "%%~fF" "%DATA%\" >nul
cd /d "%DATA%"

if not defined FGE_ENTRY set "FGE_ENTRY=main"
"%HERE%jre\bin\java.exe" -Xss32m -XX:MaxRAMPercentage=50 "-Dorg.lwjgl.system.SharedLibraryExtractPath=%DATA%\cache\lwjgl" %FGE_JAVA_OPTS% -jar "%HERE%game\game.jar" >>"%LOG%" 2>&1
