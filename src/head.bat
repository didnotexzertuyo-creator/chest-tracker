@echo off
setlocal
title Chest Tracker
set "SELF=%~f0"
set "CT=%LOCALAPPDATA%\ChestTracker"
set "URL=http://127.0.0.1:47821/"
if not exist "%CT%" mkdir "%CT%"

rem --- extrait le serveur et l'interface caches a la fin de ce fichier ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); $a=[regex]::Split($t,'(?m)^:::(?:PS1|HTML):::\r?$'); if($a.Count -lt 3){exit 1}; [IO.File]::WriteAllText((Join-Path $env:CT 'tracker.ps1'),$a[1],(New-Object Text.UTF8Encoding $true)); [IO.File]::WriteAllText((Join-Path $env:CT 'tracker.html'),$a[2],(New-Object Text.UTF8Encoding $false))"
if errorlevel 1 goto :broken

rem arrete une ancienne version encore ouverte
curl -s -o nul "%URL%api/quit" >nul 2>&1
timeout /t 1 /nobreak >nul
call :launch
goto :menu

:menu
cls
echo.
echo   ==================================================
echo                 C H E S T   T R A C K E R
echo   ==================================================
echo.
echo     [1]  Ouvrir le tracker
echo     [2]  Changer l'objectif
echo     [3]  Definir le nombre de coffres deja ouverts
echo     [4]  Reset de la session
echo     [5]  Arreter le tracker
echo     [6]  Fermer ce menu (le tracker reste ouvert)
echo.
echo     Touches en jeu : reglables dans le tracker (roue crantee)
echo.
choice /c 123456 /n /m "   Ton choix : "
if errorlevel 6 goto :end
if errorlevel 5 goto :stop
if errorlevel 4 goto :reset
if errorlevel 3 goto :count
if errorlevel 2 goto :goal
if errorlevel 1 goto :open
goto :menu

:open
call :launch
goto :menu

:goal
echo.
set "V="
set /p "V=   Nouvel objectif : "
if not defined V goto :menu
call :ps goal "%V%"
timeout /t 2 /nobreak >nul
goto :menu

:count
echo.
set "V="
set /p "V=   Nombre de coffres deja ouverts : "
if not defined V goto :menu
call :ps count "%V%"
timeout /t 2 /nobreak >nul
goto :menu

:reset
echo.
choice /c ON /n /m "   Remettre la session a zero ? (O/N) : "
if errorlevel 2 goto :menu
call :ps reset ""
timeout /t 2 /nobreak >nul
goto :menu

:stop
echo.
call :ps stop ""
timeout /t 2 /nobreak >nul
goto :menu

:ps
powershell -NoProfile -ExecutionPolicy Bypass -File "%CT%\tracker.ps1" -Action %1 -Value %2
exit /b

:launch
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CT%\tracker.ps1" -Action serve
where curl >nul 2>&1
if errorlevel 1 goto :wait_blind
set /a TRIES=0
:wait_loop
curl -s -o nul "%URL%api/state" >nul 2>&1
if not errorlevel 1 goto :ready
set /a TRIES+=1
if %TRIES% geq 15 goto :ready
timeout /t 1 /nobreak >nul
goto :wait_loop
:wait_blind
timeout /t 3 /nobreak >nul
:ready
set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if exist "%EDGE%" goto :launch_edge
start "" "%URL%"
exit /b
:launch_edge
start "" "%EDGE%" --app=%URL% --window-size=420,640
exit /b

:broken
echo.
echo   Erreur : ce fichier .bat est incomplet ou abime. Retelecharge-le.
pause
goto :end

:end
endlocal
exit /b
