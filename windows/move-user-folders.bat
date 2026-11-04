@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem  Move Desktop / Downloads / Documents / Pictures / Music / Videos
rem  to D:\Users (or the folder given as the first argument).
rem  Double-click to run. Do NOT "Run as administrator".
rem ============================================================

rem Re-launch inside "cmd /k" so the window never closes on an error.
if /i not "%~1"=="--inner" (
    start "Move user folders" cmd /k call "%~f0" --inner %*
    exit /b
)
shift

set "BASE=%~1"
if "%BASE%"=="" set "BASE=D:\Users"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"

set "USF=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
set "SF=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

if not exist "%BASE:~0,2%\" (
    echo [ERROR] Drive %BASE:~0,2% does not exist.
    goto :end
)

echo The following folders will be moved to %BASE%:
echo   Desktop   -^> %BASE%\Desktop
echo   Downloads -^> %BASE%\Downloads
echo   Documents -^> %BASE%\Documents
echo   Pictures  -^> %BASE%\Pictures
echo   Music     -^> %BASE%\Music
echo   Videos    -^> %BASE%\Videos
echo.
echo If OneDrive folder backup is on, turn it off in OneDrive settings first.
echo.
choice /c YN /m "Also move the existing files? Y = move files, N = only change location"
if errorlevel 2 (set "MOVE=N") else (set "MOVE=Y")
echo.

call :relocate "Desktop"   "Desktop"     "{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}"
call :relocate "Downloads" "{374DE290-123F-4565-9164-39C4925E467B}" "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}"
call :relocate "Documents" "Personal"    "{F42EE2D3-909F-4907-8871-4C22FC0BF756}"
call :relocate "Pictures"  "My Pictures" "{0DDD015D-B06C-45D5-8C4C-F59713854639}"
call :relocate "Music"     "My Music"    "{A0C69A99-21C8-4671-8703-7934162FCF1D}"
call :relocate "Videos"    "My Video"    "{35286A68-3C57-41A1-BBB1-0EAE73D76C95}"

echo.
echo Restarting Explorer...
taskkill /f /im explorer.exe >nul 2>&1
start "" explorer.exe
echo.
echo Done. Sign out or restart if some programs still use the old paths.

:end
echo.
echo You can close this window now.
endlocal
exit /b

rem ------------------------------------------------------------
rem  :relocate <subfolder> <registry value> <registry value 2>
rem ------------------------------------------------------------
:relocate
set "SUB=%~1"
set "VAL=%~2"
set "VAL2=%~3"
set "NEW=%BASE%\%SUB%"
set "OLD="
set "LINE="

rem Read the current path. Value names may contain spaces, so split on "_SZ".
for /f "delims=" %%L in ('reg query "%USF%" /v "%VAL%" 2^>nul ^| findstr /c:"_SZ"') do set "LINE=%%L"
if defined LINE call set "OLD=%%LINE:*_SZ=%%"
set "LINE="
if defined OLD for /f "tokens=* delims= " %%x in ("%OLD%") do set "OLD=%%x"
if defined OLD call set "OLD=%OLD%"
if defined OLD if "%OLD:~-1%"=="\" set "OLD=%OLD:~0,-1%"

echo [%SUB%] "%OLD%" -^> "%NEW%"

if not exist "%NEW%\" mkdir "%NEW%" 2>nul
if not exist "%NEW%\" goto :mkfail

if not defined OLD goto :setreg
if /i "%OLD%"=="%NEW%" goto :same
if not exist "%OLD%\" goto :setreg

if /i not "%MOVE%"=="Y" goto :copyini
echo   Moving files...
robocopy "%OLD%" "%NEW%" /E /MOVE /XJ /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 echo   [WARN] Some files could not be moved, maybe in use. Check "%OLD%"
goto :setreg

:copyini
rem Copy only desktop.ini so the folder keeps its localized name and icon.
if exist "%OLD%\desktop.ini" robocopy "%OLD%" "%NEW%" desktop.ini /COPY:DAT /R:0 /NFL /NDL /NJH /NJS /NP >nul
goto :setreg

:same
echo   Already at the target location.

:setreg
reg add "%USF%" /v "%VAL%" /t REG_EXPAND_SZ /d "%NEW%" /f >nul
if not "%VAL2%"=="" reg add "%USF%" /v "%VAL2%" /t REG_EXPAND_SZ /d "%NEW%" /f >nul
reg add "%SF%" /v "%VAL%" /t REG_SZ /d "%NEW%" /f >nul
rem Read-only attribute makes Windows honor desktop.ini (localized name and icon).
attrib +r "%NEW%" >nul 2>&1
echo   OK
goto :eof

:mkfail
echo   [ERROR] Cannot create "%NEW%", skipped.
goto :eof
