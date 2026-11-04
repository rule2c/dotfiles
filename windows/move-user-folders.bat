@echo off
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion
title Move user folders

rem ============================================================
rem  把 桌面/下载/文档/图片/音乐/视频 的位置改到 D:\Users 下
rem  用法: 双击运行，或  move-user-folders.bat [目标目录]
rem  不要"以管理员身份运行"（改的是当前用户的 HKCU）
rem ============================================================

set "BASE=%~1"
if "%BASE%"=="" set "BASE=D:\Users"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"

set "USF=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
set "SF=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

if not exist "%BASE:~0,2%\" (
    echo [错误] 驱动器 %BASE:~0,2% 不存在。
    goto :end
)

echo 将把以下文件夹移到 %BASE%：
echo   桌面 → %BASE%\Desktop
echo   下载 → %BASE%\Downloads
echo   文档 → %BASE%\Documents
echo   图片 → %BASE%\Pictures
echo   音乐 → %BASE%\Music
echo   视频 → %BASE%\Videos
echo.
echo 如果开启了 OneDrive 的"备份桌面/文档/图片"，请先在 OneDrive 设置里关闭。
echo.
choice /c YN /m "是否同时把原文件夹里的文件移动过去（Y=移动，N=只改位置）"
if errorlevel 2 (set "MOVE=N") else (set "MOVE=Y")
echo.

call :relocate "Desktop"   "Desktop"     "{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}"
call :relocate "Downloads" "{374DE290-123F-4565-9164-39C4925E467B}" "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}"
call :relocate "Documents" "Personal"    "{F42EE2D3-909F-4907-8871-4C22FC0BF756}"
call :relocate "Pictures"  "My Pictures" "{0DDD015D-B06C-45D5-8C4C-F59713854639}"
call :relocate "Music"     "My Music"    "{A0C69A99-21C8-4671-8703-7934162FCF1D}"
call :relocate "Videos"    "My Video"    "{35286A68-3C57-41A1-BBB1-0EAE73D76C95}"

echo.
echo 正在重启资源管理器...
taskkill /f /im explorer.exe >nul 2>&1
start "" explorer.exe
echo.
echo 完成。如有程序仍使用旧路径，注销或重启后即可生效。

:end
echo.
pause
endlocal
exit /b

rem ------------------------------------------------------------
rem  :relocate <子目录名> <注册表值名> <注册表值名2>
rem ------------------------------------------------------------
:relocate
set "SUB=%~1"
set "VAL=%~2"
set "VAL2=%~3"
set "NEW=%BASE%\%SUB%"
set "OLD="
set "LINE="

rem 读取当前路径（值名可能带空格，所以按 _SZ 切分）
for /f "delims=" %%L in ('reg query "%USF%" /v "%VAL%" 2^>nul ^| findstr /c:"_SZ"') do set "LINE=%%L"
if defined LINE call set "OLD=%%LINE:*_SZ=%%"
set "LINE="
if defined OLD for /f "tokens=* delims= " %%x in ("%OLD%") do set "OLD=%%x"
if defined OLD call set "OLD=%OLD%"
if defined OLD if "%OLD:~-1%"=="\" set "OLD=%OLD:~0,-1%"

echo [%SUB%] "%OLD%"  →  "%NEW%"

if not exist "%NEW%\" mkdir "%NEW%" 2>nul
if not exist "%NEW%\" (
    echo   [错误] 无法创建 %NEW%，跳过。
    goto :eof
)

if not defined OLD goto :setreg
if /i "%OLD%"=="%NEW%" (
    echo   已经是目标位置，跳过移动。
    goto :setreg
)
if not exist "%OLD%\" goto :setreg

if /i not "%MOVE%"=="Y" goto :copyini
echo   正在移动文件...
robocopy "%OLD%" "%NEW%" /E /MOVE /XJ /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 echo   [警告] 部分文件未能移动（可能正被占用），请稍后手动处理："%OLD%"
goto :setreg

:copyini
rem 只复制 desktop.ini，让新文件夹继续显示中文名称
if exist "%OLD%\desktop.ini" robocopy "%OLD%" "%NEW%" desktop.ini /COPY:DAT /R:0 /NFL /NDL /NJH /NJS /NP >nul

:setreg
reg add "%USF%" /v "%VAL%" /t REG_EXPAND_SZ /d "%NEW%" /f >nul
if not "%VAL2%"=="" reg add "%USF%" /v "%VAL2%" /t REG_EXPAND_SZ /d "%NEW%" /f >nul
reg add "%SF%" /v "%VAL%" /t REG_SZ /d "%NEW%" /f >nul
rem 只读属性让 desktop.ini 生效（显示"桌面""文档"等名称和图标）
attrib +r "%NEW%" >nul 2>&1
echo   已完成。
goto :eof
