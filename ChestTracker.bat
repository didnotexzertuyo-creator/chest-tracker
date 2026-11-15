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
:::PS1:::
param([string]$Action = 'serve', [string]$Value = '')
# Chest Tracker - local server + global hotkeys (Windows PowerShell 5.1+)
$ErrorActionPreference = 'Stop'
$Dir = Join-Path $env:LOCALAPPDATA 'ChestTracker'
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
$StatePath = Join-Path $Dir 'state.json'
$HtmlPath  = Join-Path $Dir 'tracker.html'
$Port = 47821
$VK_ADD  = [uint32]0x77   # F8
$VK_UNDO = [uint32]0x76   # F7

function NowMs { return [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function New-State {
  return [pscustomobject]@{ count = [long]0; goal = [long]20; best = [long]0; start = (NowMs); log = @(); rev = [long]0; last = 'init'; keyAdd = [long]0x77; keyUndo = [long]0x76; keyAddName = 'F8'; keyUndoName = 'F7' }
}

function Read-State {
  if (Test-Path -LiteralPath $StatePath) {
    try {
      $o = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
      $s = New-State
      foreach ($k in @('count', 'goal', 'best', 'start', 'rev', 'keyAdd', 'keyUndo')) {
        if ($null -ne $o.$k) { $s.$k = [long]$o.$k }
      }
      if ($null -ne $o.last) { $s.last = [string]$o.last }
      if ($o.keyAddName) { $s.keyAddName = [string]$o.keyAddName }
      if ($o.keyUndoName) { $s.keyUndoName = [string]$o.keyUndoName }
      if ($null -ne $o.log) { $s.log = @($o.log | Where-Object { $null -ne $_ } | ForEach-Object { [long]$_ }) }
      if ($s.goal -lt 1) { $s.goal = 20 }
      return $s
    } catch { }
  }
  return New-State
}

function Write-State($s) {
  $json = $s | ConvertTo-Json -Compress -Depth 4
  [IO.File]::WriteAllText($StatePath, $json)
}

function Apply-Action($s, [string]$act, [long]$val) {
  switch ($act) {
    'add' {
      $s.count = $s.count + 1
      $s.log = @(@($s.log) + (NowMs) | Select-Object -Last 200)
    }
    'undo' {
      if ($s.count -gt 0) {
        $s.count = $s.count - 1
        $l = @($s.log)
        if ($l.Count -gt 1) { $s.log = @($l[0..($l.Count - 2)]) } else { $s.log = @() }
      }
    }
    'goal'  { if ($val -ge 1) { $s.goal = [Math]::Min($val, 9999) } }
    'count' { if ($val -ge 0) { $s.count = [Math]::Min($val, 99999) } }
    'reset' { $s.count = 0; $s.log = @(); $s.start = (NowMs) }
  }
  if ($s.count -gt $s.best) { $s.best = $s.count }
  $s.rev = $s.rev + 1
  $s.last = $act
  return $s
}

# ---------------------------------------------------------------- CLI actions (from the .bat menu)
if ($Action -ne 'serve') {
  if ($Action -eq 'stop') {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "http://127.0.0.1:$Port/api/quit" | Out-Null; Write-Host '   Tracker arrete.' }
    catch { Write-Host "   Le tracker n'etait pas lance." }
    exit 0
  }
  $n = [long]0
  if ($Action -eq 'goal' -or $Action -eq 'count') {
    if (-not [long]::TryParse(($Value -replace '\s', ''), [ref]$n) -or $n -lt 0 -or ($Action -eq 'goal' -and $n -lt 1)) {
      Write-Host '   Valeur invalide : tape un nombre entier.' -ForegroundColor Red
      exit 1
    }
  }
  $s = Apply-Action (Read-State) $Action $n
  Write-State $s
  switch ($Action) {
    'goal'  { Write-Host "   Objectif regle sur $($s.goal) coffres." -ForegroundColor Green }
    'count' { Write-Host "   Compteur regle sur $($s.count) coffres." -ForegroundColor Green }
    'reset' { Write-Host '   Session remise a zero (record conserve).' -ForegroundColor Green }
  }
  exit 0
}

# ---------------------------------------------------------------- server
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch { exit 0 }   # already running

$hot = $false
try {
  $code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CTHot {
  [StructLayout(LayoutKind.Sequential)]
  public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public static void PinTop() {
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) {
        StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
        if (sb.ToString().StartsWith("Chest Tracker")) SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0013);
      }
      return true;
    }, IntPtr.Zero);
  }
  public static int Poll() { MSG m; if (PeekMessage(out m, IntPtr.Zero, 0x0312, 0x0312, 1)) return m.wParam.ToInt32(); return 0; }
}
"@
  Add-Type -TypeDefinition $code
  $script:hasApi = $true
} catch { $script:hasApi = $false }

function Register-Keys {
  $script:hot = $false
  if (-not $script:hasApi) { return }
  [void][CTHot]::UnregisterHotKey([IntPtr]::Zero, 1)
  [void][CTHot]::UnregisterHotKey([IntPtr]::Zero, 2)
  $a = [CTHot]::RegisterHotKey([IntPtr]::Zero, 1, 0x4000, [uint32]$script:state.keyAdd)
  $u = [CTHot]::RegisterHotKey([IntPtr]::Zero, 2, 0x4000, [uint32]$script:state.keyUndo)
  $script:hot = $a -or $u
}

$script:state = Read-State
Write-State $script:state
$script:mtime = (Get-Item -LiteralPath $StatePath).LastWriteTimeUtc
Register-Keys

function Save-Now {
  Write-State $script:state
  $script:mtime = (Get-Item -LiteralPath $StatePath).LastWriteTimeUtc
}

function State-Json {
  $j = $script:state | ConvertTo-Json -Compress -Depth 4
  $hk = 'false'; if ($script:hot) { $hk = 'true' }
  return $j.Substring(0, $j.Length - 1) + ',"hotkeys":' + $hk + '}'
}

function Send-Response($stream, [string]$status, [string]$ctype, [byte[]]$body) {
  $hdr = "HTTP/1.1 $status`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

function Handle-Client($client) {
  $keepRunning = $true
  try {
    $client.ReceiveTimeout = 400
    $client.SendTimeout = 1500
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
    $first = $reader.ReadLine()
    if ([string]::IsNullOrEmpty($first)) { return $true }
    while ($true) { $h = $reader.ReadLine(); if ([string]::IsNullOrEmpty($h)) { break } }
    $parts = $first.Split(' ')
    $target = '/'; if ($parts.Length -ge 2) { $target = $parts[1] }
    $path = $target; $query = ''
    $qi = $target.IndexOf('?'); if ($qi -ge 0) { $path = $target.Substring(0, $qi); $query = $target.Substring($qi + 1) }
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    if ($path -eq '/' -or $path -eq '/index.html') {
      Send-Response $stream '200 OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($HtmlPath))
      return $true
    }
    if ($path -eq '/api/quit') {
      Send-Response $stream '200 OK' 'application/json' ($utf8.GetBytes('{"ok":true}'))
      return $false
    }
    if ($path.StartsWith('/api/')) {
      $act = $path.Substring(5)
      $changed = $true
      if ($act -eq 'add' -or $act -eq 'undo' -or $act -eq 'reset') {
        $script:state = Apply-Action $script:state $act 0
      } elseif ($act -eq 'set') {
        $changed = $false
        foreach ($pair in $query.Split('&')) {
          $kv = $pair.Split('=')
          if ($kv.Length -eq 2 -and ($kv[0] -eq 'goal' -or $kv[0] -eq 'count')) {
            $n = [long]0
            if ([long]::TryParse($kv[1], [ref]$n)) { $script:state = Apply-Action $script:state $kv[0] $n; $changed = $true }
          }
        }
      } elseif ($act -eq 'keys') {
        foreach ($pair in $query.Split('&')) {
          $kv = $pair.Split('=')
          if ($kv.Length -ne 2) { continue }
          $v = [Uri]::UnescapeDataString($kv[1])
          $n = [long]0
          switch ($kv[0]) {
            'add'      { if ([long]::TryParse($v, [ref]$n) -and $n -gt 0 -and $n -lt 255) { $script:state.keyAdd = $n } }
            'undo'     { if ([long]::TryParse($v, [ref]$n) -and $n -gt 0 -and $n -lt 255) { $script:state.keyUndo = $n } }
            'addName'  { $script:state.keyAddName = $v.Substring(0, [Math]::Min(20, $v.Length)) }
            'undoName' { $script:state.keyUndoName = $v.Substring(0, [Math]::Min(20, $v.Length)) }
          }
        }
        $script:state.rev = $script:state.rev + 1; $script:state.last = 'keys'
        Register-Keys
      } else { $changed = $false }
      if ($changed) { Save-Now }
      Send-Response $stream '200 OK' 'application/json; charset=utf-8' ($utf8.GetBytes((State-Json)))
      return $true
    }
    Send-Response $stream '404 Not Found' 'text/plain' ($utf8.GetBytes('not found'))
  } catch {
  } finally {
    try { $client.Close() } catch { }
  }
  return $keepRunning
}

$tick = 0; $running = $true
while ($running) {
  try {
    if ($listener.Pending()) {
      $c = $listener.AcceptTcpClient()
      $running = Handle-Client $c
      continue
    }
    if ($script:hot) {
      while (($id = [CTHot]::Poll()) -ne 0) {
        if ($id -eq 1) { $script:state = Apply-Action $script:state 'add' 0;  Save-Now }
        if ($id -eq 2) { $script:state = Apply-Action $script:state 'undo' 0; Save-Now }
      }
    }
    $tick++
    if ($script:hasApi -and $tick % 10 -eq 0) { try { [CTHot]::PinTop() } catch { } }
    if ($tick % 20 -eq 0) {
      # pick up changes made from the .bat menu while running
      $mt = (Get-Item -LiteralPath $StatePath).LastWriteTimeUtc
      if ($mt -ne $script:mtime) { $script:state = Read-State; $script:mtime = $mt }
    }
    Start-Sleep -Milliseconds 20
  } catch { Start-Sleep -Milliseconds 100 }
}
$listener.Stop()
if ($script:hasApi) { try { [void][CTHot]::UnregisterHotKey([IntPtr]::Zero, 1); [void][CTHot]::UnregisterHotKey([IntPtr]::Zero, 2) } catch { } }
:::HTML:::
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chest Tracker</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Luckiest+Guy&family=Rubik:wght@500;700;900&display=swap" rel="stylesheet">
<style>
:root{
  --gold:#ffd54a;--gold2:#ff9f1c;--gold3:#b85c00;--cyan:#4ff3ff;--violet:#9d6bff;--pink:#ff5fd2;
  --ink:#fff;--muted:#b9b2e6;--glass:rgba(22,14,58,.55);--stroke:rgba(255,255,255,.14);
  --shake-x:0px;--shake-y:0px;
}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden;background:#07041a}
body{font-family:Rubik,"Segoe UI",Arial,sans-serif;color:var(--ink);user-select:none;-webkit-user-select:none}
.layer{position:fixed;inset:0;pointer-events:none}
#sky{z-index:0}
.aurora{z-index:1;filter:blur(60px);opacity:.75;mix-blend-mode:screen}
.aurora i{position:absolute;border-radius:50%;display:block}
.aurora i:nth-child(1){width:70vw;height:30vh;left:-10vw;top:8vh;background:radial-gradient(closest-side,rgba(79,243,255,.55),transparent);animation:au1 18s ease-in-out infinite alternate}
.aurora i:nth-child(2){width:60vw;height:34vh;right:-10vw;top:2vh;background:radial-gradient(closest-side,rgba(157,107,255,.6),transparent);animation:au2 22s ease-in-out infinite alternate}
.aurora i:nth-child(3){width:50vw;height:26vh;left:25vw;top:18vh;background:radial-gradient(closest-side,rgba(255,95,210,.4),transparent);animation:au3 16s ease-in-out infinite alternate}
@keyframes au1{to{transform:translate(18vw,6vh) scale(1.2)}}
@keyframes au2{to{transform:translate(-20vw,8vh) scale(.9)}}
@keyframes au3{to{transform:translate(-10vw,-6vh) scale(1.3)}}
#land{z-index:2;transition:transform .6s ease-out}
.clouds{z-index:3}
.cloud{position:absolute;height:60px;border-radius:60px;background:linear-gradient(180deg,rgba(255,220,240,.22),rgba(140,110,220,.08));filter:blur(6px);animation:drift linear infinite}
.cloud::before,.cloud::after{content:"";position:absolute;background:inherit;border-radius:50%}
.cloud::before{width:55%;height:150%;left:15%;top:-70%}
.cloud::after{width:40%;height:120%;right:12%;top:-45%}
@keyframes drift{from{transform:translateX(-30vw)}to{transform:translateX(130vw)}}
#motes{z-index:4}
.vignette{z-index:5;background:radial-gradient(ellipse at 50% 45%,transparent 45%,rgba(4,2,16,.75) 100%)}
#fx{z-index:40}
.flash{z-index:39;background:radial-gradient(circle at var(--fx,50%) var(--fy,50%),rgba(255,240,180,.55),transparent 55%);opacity:0}
.flash.on{animation:flash .6s ease-out}
@keyframes flash{0%{opacity:0}15%{opacity:1}100%{opacity:0}}

/* ---------- layout ---------- */
.app{position:relative;z-index:10;height:100%;display:grid;grid-template-rows:auto 1fr;padding:14px 18px 16px;gap:10px;
  transform:translate(var(--shake-x),var(--shake-y))}
header{display:flex;align-items:center;gap:10px}
.logo{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:26px;letter-spacing:1.5px;line-height:1;
  background:linear-gradient(180deg,#fff 0%,var(--gold) 45%,var(--gold2) 100%);-webkit-background-clip:text;background-clip:text;color:transparent;
  filter:drop-shadow(0 3px 0 #5a2a00) drop-shadow(0 0 12px rgba(255,180,40,.35))}
.pill{display:flex;align-items:center;gap:7px;font:700 11px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:.6px;text-transform:uppercase;color:var(--muted);
  background:var(--glass);border:1px solid var(--stroke);padding:6px 10px;border-radius:99px;backdrop-filter:blur(8px)}
.pill .led{width:8px;height:8px;border-radius:50%;background:#666}
.pill.ok .led{background:#5dff9a;box-shadow:0 0 10px #5dff9a}
.pill kbd{font:800 10px Rubik,"Segoe UI",Arial,sans-serif;color:#fff;background:rgba(255,255,255,.14);border-radius:5px;padding:1px 5px;border-bottom:2px solid rgba(0,0,0,.35)}
.sp{flex:1}
.ibtn{width:38px;height:38px;border-radius:12px;display:grid;place-items:center;cursor:pointer;color:#fff;font:800 16px Rubik,"Segoe UI",Arial,sans-serif;
  background:var(--glass);border:1px solid var(--stroke);backdrop-filter:blur(8px);transition:transform .12s,background .12s}
.ibtn:hover{transform:translateY(-2px);background:rgba(60,40,140,.6)}
.ibtn svg{width:18px;height:18px}

main{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(250px,.85fr);gap:16px;min-height:0}
body.compact main,
.narrow main{grid-template-columns:1fr}
body.compact aside{display:none}

/* ---------- stage ---------- */
.stage{position:relative;min-height:0;display:flex;flex-direction:column;align-items:center;justify-content:center;cursor:pointer}
.scene{position:relative;width:min(100%,58vh,520px);aspect-ratio:1/1;display:grid;place-items:center}
.rays{position:absolute;inset:-12%;border-radius:50%;
  background:repeating-conic-gradient(from 0deg,rgba(255,213,74,.18) 0deg 6deg,transparent 6deg 22deg);
  -webkit-mask:radial-gradient(closest-side,#000 25%,transparent 100%);mask:radial-gradient(closest-side,#000 25%,transparent 100%);
  animation:spin 40s linear infinite;opacity:.45;transition:opacity .4s}
.scene.opening .rays{opacity:1;animation-duration:3s}
@keyframes spin{to{transform:rotate(360deg)}}

.ring{position:absolute;inset:4%;}
.ring .seg{fill:none;stroke-width:9;stroke-linecap:round;transition:stroke .4s, filter .4s}
.ring .seg.off{stroke:rgba(255,255,255,.09)}
.ring .seg.on{stroke:url(#segGrad);filter:drop-shadow(0 0 5px rgba(255,190,60,.9))}
.ring .seg.new{animation:segpop .7s ease-out}
@keyframes segpop{0%{stroke-width:20;stroke:#fff}100%{stroke-width:9}}
.ring .track{fill:none;stroke:rgba(255,255,255,.09);stroke-width:9}
.ring .fill{fill:none;stroke:url(#segGrad);stroke-width:9;stroke-linecap:round;transition:stroke-dashoffset 1s cubic-bezier(.2,.9,.2,1);filter:drop-shadow(0 0 6px rgba(255,190,60,.9))}

.pedestal{position:absolute;left:50%;bottom:16%;width:62%;height:16%;transform:translateX(-50%);border-radius:50%;
  background:radial-gradient(closest-side,rgba(79,243,255,.55),rgba(157,107,255,.25) 55%,transparent 72%);filter:blur(2px);animation:pulse 3s ease-in-out infinite}
.pedestal::after{content:"";position:absolute;inset:12% 6%;border-radius:50%;border:2px dashed rgba(170,250,255,.55);animation:spin 14s linear infinite}
.scene.opening .pedestal{animation:pulse .5s ease-in-out 3}
@keyframes pulse{50%{opacity:.6;transform:translateX(-50%) scale(1.05)}}

.beam{position:absolute;left:50%;bottom:44%;width:34%;height:120%;transform:translateX(-50%) scaleY(0);transform-origin:50% 100%;opacity:0;
  background:linear-gradient(0deg,rgba(255,250,210,1) 0%,rgba(255,213,74,.75) 25%,rgba(255,160,40,.25) 65%,transparent 100%);
  -webkit-mask:linear-gradient(90deg,transparent,#000 30%,#000 70%,transparent);mask:linear-gradient(90deg,transparent,#000 30%,#000 70%,transparent);
  mix-blend-mode:screen;filter:blur(3px)}
.scene.opening .beam{animation:beam 1.5s cubic-bezier(.2,.8,.2,1) .42s}
@keyframes beam{0%{opacity:0;transform:translateX(-50%) scaleY(0) scaleX(.4)}20%{opacity:1;transform:translateX(-50%) scaleY(1) scaleX(1.15)}60%{opacity:.85;transform:translateX(-50%) scaleY(1) scaleX(.9)}100%{opacity:0;transform:translateX(-50%) scaleY(1.05) scaleX(.3)}}

.shock{position:absolute;left:50%;top:56%;width:20%;aspect-ratio:1;border-radius:50%;transform:translate(-50%,-50%) scale(0);
  border:6px solid rgba(255,235,160,.9);box-shadow:0 0 30px rgba(255,200,80,.8),inset 0 0 30px rgba(255,200,80,.6);opacity:0}
.scene.opening .shock{animation:shock .8s ease-out .42s}
.scene.opening .shock.s2{animation-delay:.55s;border-color:rgba(79,243,255,.8)}
@keyframes shock{0%{opacity:1;transform:translate(-50%,-50%) scale(.3)}100%{opacity:0;transform:translate(-50%,-50%) scale(4.2);border-width:1px}}

.chest-wrap{position:relative;width:60%;margin-top:6%;animation:hover 3.2s ease-in-out infinite}
@keyframes hover{50%{transform:translateY(-8px)}}
.chest{width:100%;display:block;overflow:visible;filter:drop-shadow(0 18px 18px rgba(0,0,0,.55))}
.chest .lid{transform-box:fill-box;transform-origin:50% 100%}
.chest .seam{opacity:.35}
.chest .inner{opacity:0}
.chest .gem{animation:gem 2.4s ease-in-out infinite}
@keyframes gem{50%{filter:brightness(1.6) drop-shadow(0 0 6px #4ff3ff)}}
.scene.rattle .chest-wrap{animation:rattle .42s linear}
.scene.rattle .chest .seam{animation:seam .42s ease-in forwards}
@keyframes seam{to{opacity:1}}
@keyframes rattle{0%{transform:translate(0,0) rotate(0)}10%{transform:translate(-2px,1px) rotate(-1deg)}20%{transform:translate(3px,0) rotate(1.5deg)}30%{transform:translate(-4px,-1px) rotate(-2deg)}40%{transform:translate(4px,1px) rotate(2deg)}50%{transform:translate(-5px,0) rotate(-2.5deg)}60%{transform:translate(5px,-2px) rotate(2.5deg)}70%{transform:translate(-6px,1px) rotate(-3deg)}80%{transform:translate(6px,0) rotate(3deg)}90%{transform:translate(-3px,-3px) scale(1.04,.96)}100%{transform:translate(0,4px) scale(1.08,.9)}}
.scene.opening .chest-wrap{animation:jump 1.6s cubic-bezier(.2,1.2,.3,1)}
@keyframes jump{0%{transform:translateY(4px) scale(1.08,.9)}12%{transform:translateY(-22px) scale(.95,1.07)}28%{transform:translateY(0) scale(1.04,.97)}40%{transform:translateY(-4px) scale(1)}100%{transform:none}}
.scene.opening .chest .lid{animation:lid 1.6s cubic-bezier(.25,1.5,.35,1)}
@keyframes lid{0%{transform:none}14%{transform:translateY(-34%) rotate(-9deg) scaleY(.55)}70%{transform:translateY(-30%) rotate(-7deg) scaleY(.6)}86%{transform:translateY(2%) scaleY(1.04)}100%{transform:none}}
.scene.opening .chest .inner{animation:inner 1.6s ease-out}
@keyframes inner{0%{opacity:0}12%{opacity:1}70%{opacity:.9}88%{opacity:0}}
.scene.opening .chest .seam{animation:seamOut 1.6s ease-out forwards}
@keyframes seamOut{0%{opacity:1}80%{opacity:.8}100%{opacity:.35}}

/* ---------- counter ---------- */
.counter{position:relative;margin-top:-4%;text-align:center;line-height:.9;pointer-events:none}
.num{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:clamp(70px,13vh,130px);letter-spacing:2px;display:inline-block;
  background:linear-gradient(180deg,#fffbe6 8%,var(--gold) 46%,var(--gold2) 72%,#e86d00);-webkit-background-clip:text;background-clip:text;color:transparent;
  filter:drop-shadow(0 5px 0 #4a1f00) drop-shadow(0 0 26px rgba(255,170,30,.45))}
.num.slam{animation:slam .65s cubic-bezier(.2,1.6,.35,1)}
@keyframes slam{0%{transform:scale(1.9) translateY(-20px);filter:blur(4px) drop-shadow(0 5px 0 #4a1f00);opacity:.2}55%{transform:scale(.92)}100%{transform:scale(1)}}
.num.down{animation:down .45s ease-out}
@keyframes down{0%{transform:translateY(-12px);opacity:.3}100%{transform:none}}
.goalline{font:900 15px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;color:var(--muted);margin-top:4px}
.goalline b{color:#fff}
.floater{position:absolute;left:50%;top:30%;font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:44px;color:var(--gold);pointer-events:none;
  text-shadow:0 4px 0 #4a1f00,0 0 22px rgba(255,190,40,.9);animation:floatUp 1.3s cubic-bezier(.2,.8,.3,1) forwards;z-index:5}
@keyframes floatUp{0%{opacity:0;transform:translate(-50%,20px) scale(.5)}20%{opacity:1;transform:translate(-50%,-10px) scale(1.2)}100%{opacity:0;transform:translate(-50%,-150px) scale(1)}}
.tap{margin-top:12px;font:700 12px Rubik,"Segoe UI",Arial,sans-serif;color:var(--muted);opacity:.8;letter-spacing:.5px}
.tap kbd{font:800 11px Rubik,"Segoe UI",Arial,sans-serif;color:#fff;background:rgba(255,255,255,.14);border-radius:5px;padding:1px 6px;border-bottom:2px solid rgba(0,0,0,.35)}

/* ---------- side panel ---------- */
aside{display:flex;flex-direction:column;gap:12px;min-height:0}
.card{position:relative;background:var(--glass);border:1px solid var(--stroke);border-radius:20px;padding:14px 16px;backdrop-filter:blur(12px);
  box-shadow:0 10px 30px rgba(0,0,0,.25),inset 0 1px 0 rgba(255,255,255,.08)}
.card h3{font:900 11px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;color:var(--muted);margin-bottom:10px;display:flex;align-items:center;gap:8px}
.card h3::before{content:"";width:6px;height:6px;border-radius:2px;background:var(--gold);transform:rotate(45deg);box-shadow:0 0 8px var(--gold)}
.goalbig{display:flex;align-items:baseline;gap:8px;font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:34px}
.goalbig small{font:700 13px Rubik,"Segoe UI",Arial,sans-serif;color:var(--muted)}
.bar{position:relative;height:14px;border-radius:99px;background:rgba(0,0,0,.35);margin-top:10px;overflow:hidden;border:1px solid rgba(255,255,255,.08)}
.bar i{position:absolute;inset:0 auto 0 0;width:0;border-radius:99px;background:linear-gradient(90deg,var(--violet),var(--pink),var(--gold));transition:width 1s cubic-bezier(.2,.9,.2,1)}
.bar i::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,transparent,rgba(255,255,255,.55),transparent);background-size:60px 100%;animation:shine 1.8s linear infinite}
@keyframes shine{from{background-position:-60px 0}to{background-position:400px 0}}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.stat{background:rgba(0,0,0,.25);border-radius:14px;padding:9px 11px;border:1px solid rgba(255,255,255,.05)}
.stat .v{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:24px;letter-spacing:1px}
.stat .l{font:700 10px Rubik,"Segoe UI",Arial,sans-serif;color:var(--muted);letter-spacing:1px;text-transform:uppercase}
.c1{color:var(--cyan)}.c2{color:var(--pink)}.c3{color:var(--gold)}.c4{color:#7dffb0}
.logcard{flex:1;min-height:0;display:flex;flex-direction:column}
.log{flex:1;min-height:0;overflow:auto;display:flex;flex-direction:column;gap:6px;padding-right:2px}
.log::-webkit-scrollbar{width:6px}.log::-webkit-scrollbar-thumb{background:rgba(255,255,255,.15);border-radius:6px}
.row{display:flex;align-items:center;gap:10px;background:rgba(0,0,0,.25);border-radius:12px;padding:7px 10px;font:600 13px Rubik}
.row.fresh{animation:rowIn .5s cubic-bezier(.2,1.3,.4,1)}
@keyframes rowIn{from{opacity:0;transform:translateX(30px) scale(.9)}}
.row .n{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;color:var(--gold);min-width:40px;font-size:16px}
.row .ic{width:18px;height:14px}
.row .t{margin-left:auto;color:var(--muted);font-variant-numeric:tabular-nums;font-size:12px}
.empty{color:var(--muted);font:600 13px Rubik,"Segoe UI",Arial,sans-serif;text-align:center;padding:18px 6px}

@media (max-width:760px){main{grid-template-columns:1fr} aside{display:none} .pill{display:none}}
@media (max-height:560px){.tap{display:none}}
/* ---------- settings drawer ---------- */
.drawer-bg{position:fixed;inset:0;z-index:60;background:rgba(5,2,20,.55);backdrop-filter:blur(3px);opacity:0;pointer-events:none;transition:opacity .25s}
.drawer{position:fixed;z-index:61;top:0;right:0;height:100%;width:min(360px,92vw);padding:20px;display:flex;flex-direction:column;gap:14px;
  background:linear-gradient(180deg,#26186a,#120a36);border-left:1px solid var(--stroke);transform:translateX(105%);transition:transform .35s cubic-bezier(.2,.9,.2,1);
  box-shadow:-20px 0 50px rgba(0,0,0,.5)}
body.settings .drawer{transform:none}
body.settings .drawer-bg{opacity:1;pointer-events:auto}
.drawer h2{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:26px;letter-spacing:1px;color:var(--gold)}
.field label{display:block;font:900 11px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:1.5px;text-transform:uppercase;color:var(--muted);margin-bottom:6px}
.stepper{display:flex;gap:8px}
.stepper button{width:44px;border-radius:12px;border:1px solid var(--stroke);background:rgba(255,255,255,.08);color:#fff;font:900 20px Rubik,"Segoe UI",Arial,sans-serif;cursor:pointer}
.stepper input{flex:1;min-width:0;height:46px;border-radius:12px;border:1px solid var(--stroke);background:rgba(0,0,0,.3);color:#fff;text-align:center;
  font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:24px;letter-spacing:1px;outline:none}
.stepper input:focus{border-color:var(--gold);box-shadow:0 0 0 3px rgba(255,213,74,.25)}
.btn{height:46px;border-radius:14px;border:none;cursor:pointer;font:900 14px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:1px;text-transform:uppercase}
.btn.gold{color:#3a1a00;background:linear-gradient(180deg,#fff2a8,var(--gold) 40%,var(--gold2));box-shadow:0 5px 0 var(--gold3)}
.btn.gold:active{transform:translateY(4px);box-shadow:0 1px 0 var(--gold3)}
.btn.red{color:#fff;background:linear-gradient(180deg,#ff7a95,#d81f4a);box-shadow:0 5px 0 #7e0b26}
.btn.red:active{transform:translateY(4px);box-shadow:0 1px 0 #7e0b26}
.btn.ghost{color:#fff;background:rgba(255,255,255,.1)}
.note{font:600 12px Rubik,"Segoe UI",Arial,sans-serif;color:var(--muted);line-height:1.5}
.note kbd{font:800 10px Rubik,"Segoe UI",Arial,sans-serif;color:#fff;background:rgba(255,255,255,.14);border-radius:5px;padding:1px 5px}
.confirm{display:none;gap:8px}
.confirm.show{display:flex}
.confirm .btn{flex:1}
.keys{display:flex;gap:8px}
.keybtn{flex:1;display:flex;flex-direction:column;align-items:center;gap:4px;padding:10px;border-radius:14px;border:1px solid var(--stroke);background:rgba(0,0,0,.3);color:#fff;cursor:pointer;font:700 11px Rubik,"Segoe UI",Arial,sans-serif;letter-spacing:1px;text-transform:uppercase}
.keybtn b{font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:22px;letter-spacing:1px;color:var(--gold)}
.keybtn.wait{border-color:var(--gold);box-shadow:0 0 0 3px rgba(255,213,74,.3);animation:pulse2 1s infinite}
@keyframes pulse2{50%{background:rgba(255,213,74,.15)}}
hr{border:none;border-top:1px solid var(--stroke)}

/* ---------- victory ---------- */
.victory{position:fixed;inset:0;z-index:50;display:none;place-items:center;pointer-events:none}
.victory.show{display:grid;background:radial-gradient(ellipse at 50% 50%,rgba(10,4,30,.65),transparent 60%)}
.victory .v{text-align:center;font-family:"Luckiest Guy","Arial Black",Impact,sans-serif;font-size:clamp(46px,9vw,110px);line-height:.95;letter-spacing:2px;
  background:linear-gradient(180deg,#fff 10%,var(--gold) 50%,var(--gold2));-webkit-background-clip:text;background-clip:text;color:transparent;
  filter:drop-shadow(0 7px 0 #4a1f00) drop-shadow(0 0 40px rgba(255,170,0,.85));animation:vic 3.6s cubic-bezier(.2,1.4,.3,1) forwards}
.victory .v small{display:block;font-size:.3em;letter-spacing:6px;margin-top:10px}
@keyframes vic{0%{opacity:0;transform:scale(.2) rotate(-10deg)}14%{opacity:1;transform:scale(1.12) rotate(2deg)}24%{transform:scale(1) rotate(0)}85%{opacity:1}100%{opacity:0;transform:scale(1.06) translateY(-20px)}}

.toast{position:fixed;left:50%;bottom:22px;transform:translate(-50%,30px);opacity:0;z-index:70;background:var(--glass);border:1px solid var(--stroke);
  backdrop-filter:blur(10px);padding:9px 16px;border-radius:99px;font:700 13px Rubik,"Segoe UI",Arial,sans-serif;transition:.3s}
.toast.show{opacity:1;transform:translate(-50%,0)}
</style>
</head>
<body>
<canvas id="sky" class="layer"></canvas>
<div class="layer aurora"><i></i><i></i><i></i></div>
<canvas id="land" class="layer"></canvas>
<div class="layer clouds" id="clouds"></div>
<canvas id="motes" class="layer"></canvas>
<div class="layer vignette"></div>
<div class="layer flash" id="flash"></div>
<canvas id="fx" class="layer"></canvas>

<div class="app">
  <header>
    <div class="logo">CHEST TRACKER</div>
    <div class="pill" id="pill"><span class="led"></span><span id="pillTxt">Hors ligne</span></div>
    <div class="sp"></div>
    <button class="ibtn" id="undoBtn" title="Annuler le dernier coffre (Z)">↶</button>
    <button class="ibtn" id="compactBtn" title="Mode compact (C)"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"><path d="M9 4H4v5M15 4h5v5M9 20H4v-5M15 20h5v-5"/></svg></button>
    <button class="ibtn" id="setBtn" title="Réglages (S)"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.2"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg></button>
  </header>

  <main>
    <section class="stage" id="stage">
      <div class="scene" id="scene">
        <div class="rays"></div>
        <svg class="ring" id="ring" viewBox="0 0 200 200">
          <defs><linearGradient id="segGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9d6bff"/><stop offset=".5" stop-color="#ff5fd2"/><stop offset="1" stop-color="#ffd54a"/></linearGradient></defs>
          <g id="segs" transform="rotate(-90 100 100)"></g>
        </svg>
        <div class="pedestal"></div>
        <div class="beam"></div>
        <div class="shock"></div><div class="shock s2"></div>
        <div class="chest-wrap" id="chestWrap">
          <svg class="chest" viewBox="0 0 260 220">
            <defs>
              <linearGradient id="cWood" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3d4fc9"/><stop offset=".55" stop-color="#2a2f97"/><stop offset="1" stop-color="#171960"/></linearGradient>
              <linearGradient id="cWoodL" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5b6cf0"/><stop offset=".6" stop-color="#3442b8"/><stop offset="1" stop-color="#232a8a"/></linearGradient>
              <linearGradient id="cGold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff7c2"/><stop offset=".35" stop-color="#ffd54a"/><stop offset=".75" stop-color="#f09a12"/><stop offset="1" stop-color="#a85200"/></linearGradient>
              <linearGradient id="cGoldH" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#c46a00"/><stop offset=".25" stop-color="#ffd54a"/><stop offset=".5" stop-color="#fff7c2"/><stop offset=".75" stop-color="#ffd54a"/><stop offset="1" stop-color="#c46a00"/></linearGradient>
              <radialGradient id="cGem" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#e9ffff"/><stop offset=".35" stop-color="#4ff3ff"/><stop offset="1" stop-color="#0a6c9e"/></radialGradient>
              <radialGradient id="cGemP" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#ffe6ff"/><stop offset=".4" stop-color="#ff5fd2"/><stop offset="1" stop-color="#7a0f6b"/></radialGradient>
              <radialGradient id="cInner" cx=".5" cy=".6" r=".6"><stop offset="0" stop-color="#fffbe0"/><stop offset=".45" stop-color="#ffd54a"/><stop offset="1" stop-color="#ff9f1c" stop-opacity="0"/></radialGradient>
              <filter id="cGlow" x="-50%" y="-200%" width="200%" height="500%"><feGaussianBlur stdDeviation="3.5"/></filter>
            </defs>
            <!-- inner light (visible when lid is up) -->
            <ellipse class="inner" cx="130" cy="112" rx="110" ry="44" fill="url(#cInner)"/>
            <!-- BODY -->
            <g class="body">
              <path d="M28 112 H232 L226 196 Q225 206 214 206 H46 Q35 206 34 196 Z" fill="url(#cWood)" stroke="#0d0b33" stroke-width="4" stroke-linejoin="round"/>
              <path d="M36 136 H224 M37 160 H223 M38 184 H222" stroke="#1a1c6a" stroke-width="3" opacity=".8"/>
              <path d="M36 134 H224 M37 158 H223 M38 182 H222" stroke="#5b6cf0" stroke-width="1.5" opacity=".45"/>
              <!-- bottom band -->
              <path d="M33 188 H227 L226 196 Q225 206 214 206 H46 Q35 206 34 196 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <!-- top rim band -->
              <rect x="24" y="110" width="212" height="16" rx="4" fill="url(#cGoldH)" stroke="#0d0b33" stroke-width="3.5"/>
              <!-- side straps -->
              <path d="M58 126 H80 L79 206 H59 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <path d="M180 126 H202 L201 206 H181 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <circle cx="69" cy="142" r="3" fill="#7a3a00"/><circle cx="69" cy="172" r="3" fill="#7a3a00"/>
              <circle cx="191" cy="142" r="3" fill="#7a3a00"/><circle cx="191" cy="172" r="3" fill="#7a3a00"/>
              <!-- corner caps -->
              <path d="M28 112 H46 V136 L30 140 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3" stroke-linejoin="round"/>
              <path d="M232 112 H214 V136 L230 140 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3" stroke-linejoin="round"/>
              <!-- lock plate -->
              <path d="M108 118 H152 V150 Q152 172 130 182 Q108 172 108 150 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <path d="M114 124 H146 V149 Q146 166 130 174 Q114 166 114 149 Z" fill="#7a3a00" opacity=".35"/>
              <g class="gem"><path d="M130 132 L142 146 L130 164 L118 146 Z" fill="url(#cGem)" stroke="#0d0b33" stroke-width="3" stroke-linejoin="round"/>
              <path d="M124 142 L130 135 L133 140" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" opacity=".9"/></g>
              <!-- highlight -->
              <path d="M40 132 Q130 126 220 132" stroke="#fff" stroke-width="2" opacity=".12" fill="none"/>
            </g>
            <!-- seam glow -->
            <rect class="seam" x="30" y="106" width="200" height="8" rx="4" fill="#fff3b0" filter="url(#cGlow)"/>
            <!-- LID -->
            <g class="lid">
              <path d="M24 112 V82 Q24 30 130 30 Q236 30 236 82 V112 Z" fill="url(#cWoodL)" stroke="#0d0b33" stroke-width="4" stroke-linejoin="round"/>
              <path d="M26 72 Q130 50 234 72 M25 92 Q130 76 235 92" stroke="#1a1c6a" stroke-width="3" fill="none" opacity=".7"/>
              <path d="M40 52 Q130 32 220 52" stroke="#fff" stroke-width="3" fill="none" opacity=".18" stroke-linecap="round"/>
              <!-- lid straps following dome -->
              <path d="M58 112 V64 Q60 46 68 41 L80 38 Q80 50 80 62 V112 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <path d="M202 112 V64 Q200 46 192 41 L180 38 Q180 50 180 62 V112 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <!-- lid bottom rim -->
              <rect x="20" y="100" width="220" height="14" rx="4" fill="url(#cGoldH)" stroke="#0d0b33" stroke-width="3.5"/>
              <!-- crest -->
              <path d="M112 30 L130 16 L148 30 L142 50 H118 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3.5" stroke-linejoin="round"/>
              <g class="gem"><path d="M130 22 L139 32 L130 44 L121 32 Z" fill="url(#cGemP)" stroke="#0d0b33" stroke-width="2.5" stroke-linejoin="round"/></g>
              <!-- lock tab -->
              <path d="M118 100 H142 V118 Q130 126 118 118 Z" fill="url(#cGold)" stroke="#0d0b33" stroke-width="3" stroke-linejoin="round"/>
              <!-- side gems -->
              <circle cx="40" cy="88" r="6" fill="url(#cGem)" stroke="#0d0b33" stroke-width="2.5"/>
              <circle cx="220" cy="88" r="6" fill="url(#cGem)" stroke="#0d0b33" stroke-width="2.5"/>
            </g>
          </svg>
        </div>
      </div>
      <div class="counter">
        <div class="num" id="num">0</div>
        <div class="goalline" id="goalline">Objectif <b>0 / 20</b></div>
      </div>
      <div class="tap" id="tapHint">Clique ici ou <kbd>Espace</kbd> &nbsp;·&nbsp; en jeu : <kbd class="kA">F8</kbd> +1 &nbsp;<kbd class="kU">F7</kbd> annuler</div>
    </section>

    <aside>
      <div class="card">
        <h3>Objectif</h3>
        <div class="goalbig"><span id="gNow">0</span><small>/ <span id="gGoal">20</span> coffres</small></div>
        <div class="bar"><i id="bar"></i></div>
      </div>
      <div class="card">
        <h3>Session</h3>
        <div class="stats">
          <div class="stat"><div class="v c1" id="sTime">00:00</div><div class="l">Durée</div></div>
          <div class="stat"><div class="v c2" id="sRate">0</div><div class="l">Coffres / h</div></div>
          <div class="stat"><div class="v c3" id="sLeft">20</div><div class="l">Restants</div></div>
          <div class="stat"><div class="v c4" id="sBest">0</div><div class="l">Record</div></div>
        </div>
      </div>
      <div class="card logcard">
        <h3>Derniers coffres</h3>
        <div class="log" id="log"></div>
      </div>
    </aside>
  </main>
</div>

<div class="drawer-bg" id="drawerBg"></div>
<div class="drawer" id="drawer">
  <h2>Réglages</h2>
  <div class="field">
    <label>Objectif de coffres</label>
    <div class="stepper"><button data-t="fGoal" data-d="-1">−</button><input id="fGoal" type="number" min="1" max="9999"><button data-t="fGoal" data-d="1">+</button></div>
  </div>
  <div class="field">
    <label>Coffres déjà ouverts</label>
    <div class="stepper"><button data-t="fCount" data-d="-1">−</button><input id="fCount" type="number" min="0" max="99999"><button data-t="fCount" data-d="1">+</button></div>
  </div>
  <button class="btn gold" id="applyBtn">Appliquer</button>
  <div class="field">
    <label>Touches en jeu</label>
    <div class="keys">
      <button class="keybtn" id="kAdd" data-k="add"><span>+1 coffre</span><b id="kAddName">F8</b></button>
      <button class="keybtn" id="kUndo" data-k="undo"><span>Annuler</span><b id="kUndoName">F7</b></button>
    </div>
    <p class="note" id="keyNote">Clique sur une touche puis appuie sur la nouvelle touche.</p>
  </div>
  <hr>
  <button class="btn ghost" id="resetBtn">Reset de la session</button>
  <div class="confirm" id="confirm"><button class="btn ghost" id="cNo">Annuler</button><button class="btn red" id="cYes">Remettre à 0</button></div>
  <p class="note">Le reset remet le compteur, le chrono et l'historique à zéro. Ton record est gardé.</p>
  <div class="sp"></div>
  <p class="note">Les touches en jeu marchent même quand Fortnite est au premier plan (lancé via le .bat).<br>Dans cette fenêtre : <kbd>Espace</kbd> +1 · <kbd>Z</kbd> annuler · <kbd>S</kbd> réglages · <kbd>C</kbd> compact.</p>
  <button class="btn ghost" id="closeSet">Fermer</button>
</div>

<div class="victory" id="victory"><div class="v">OBJECTIF<br>ATTEINT !<small id="vicSub">20 COFFRES</small></div></div>
<div class="toast" id="toast"></div>

<script>
(() => {
'use strict';
const $ = id => document.getElementById(id);
const DPR = Math.min(window.devicePixelRatio || 1, 1.5);
const W = () => innerWidth, H = () => innerHeight;

/* =========================================================
   STORE — talks to the local .bat server, or falls back to
   localStorage when the page is opened on its own.
   ========================================================= */
const LS_KEY = 'chest-tracker-local-v2';
let remote = false, state = null, hotkeys = false;
const now = () => Date.now();
function newState(){ return {count:0, goal:20, best:0, start:now(), log:[], rev:0, last:'init'}; }
function lsLoad(){ try{ const s = JSON.parse(localStorage.getItem(LS_KEY)); if(s && typeof s.count==='number') return s; }catch(e){} return newState(); }
function lsSave(s){ try{ localStorage.setItem(LS_KEY, JSON.stringify(s)); }catch(e){} }
function localApply(act, val){
  const s = state;
  if(act==='add'){ s.count++; s.log.push(now()); if(s.log.length>200) s.log.shift(); }
  else if(act==='undo'){ if(s.count>0){ s.count--; s.log.pop(); } }
  else if(act==='goal'){ s.goal = Math.max(1, Math.min(9999, val|0)); }
  else if(act==='count'){ s.count = Math.max(0, Math.min(99999, val|0)); }
  else if(act==='reset'){ s.count=0; s.log=[]; s.start=now(); }
  s.best = Math.max(s.best, s.count); s.rev++; s.last = act;
  lsSave(s); return Promise.resolve(Object.assign({}, s, {log:s.log.slice()}));
}
async function api(path){
  const r = await fetch(path, {cache:'no-store'});
  if(!r.ok) throw new Error(r.status);
  return r.json();
}
function act(a, v){
  if(!remote) return localApply(a, v).then(onState);
  let p = '/api/' + a;
  if(a==='goal' || a==='count') p = '/api/set?' + a + '=' + encodeURIComponent(v);
  return api(p).then(onState).catch(()=>toast('Serveur injoignable'));
}
async function boot(){
  if(location.protocol.startsWith('http')){
    for(let i=0;i<12;i++){
      try{ const s = await api('/api/state'); remote = true; onState(s, true); poll(); return; }catch(e){ await new Promise(r=>setTimeout(r,500)); }
    }
  }
  remote = false; state = lsLoad(); onState(Object.assign({}, state, {log:state.log.slice()}), true);
}
function poll(){
  setInterval(()=>{ api('/api/state').then(s=>onState(s)).catch(()=>setPill(false,'Serveur arrêté')); }, 250);
}

/* =========================================================
   STATE → UI
   ========================================================= */
let shown = null;
function onState(s, first){
  hotkeys = !!s.hotkeys;
  if(!remote) state = state || s;
  const prev = shown;
  shown = s;
  if(remote) setPill(true, 'Connecté (touche refusée par Windows)', hotkeys);
  else setPill(false, 'Mode local');
  if(first || !prev){ render(s, null); return; }
  if(s.rev === prev.rev && s.goal === prev.goal) { tickStats(); return; }
  if(s.last === 'keys'){ tickStats(); return; }
  render(s, prev);
}
const esc = t => String(t).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let capturing = null;
function setPill(on, txt, keys){
  $('pill').classList.toggle('ok', !!on);
  const a = esc((shown&&shown.keyAddName)||'F8'), u = esc((shown&&shown.keyUndoName)||'F7');
  $('pillTxt').innerHTML = keys ? `En jeu : <kbd>${a}</kbd> +1 · <kbd>${u}</kbd> annuler` : txt;
  document.querySelectorAll('.kA').forEach(e=>e.textContent=(shown&&shown.keyAddName)||'F8');
  document.querySelectorAll('.kU').forEach(e=>e.textContent=(shown&&shown.keyUndoName)||'F7');
  if(!capturing){ $('kAddName').textContent=(shown&&shown.keyAddName)||'F8'; $('kUndoName').textContent=(shown&&shown.keyUndoName)||'F7'; }
}

let lastGoalRendered = -1;
function render(s, prev){
  const num = $('num');
  const delta = prev ? s.count - prev.count : 0;
  num.textContent = s.count;
  if(prev && delta !== 0){
    num.classList.remove('slam','down'); void num.offsetWidth;
    num.classList.add(delta > 0 ? 'slam' : 'down');
  }
  $('goalline').innerHTML = `Objectif <b>${s.count} / ${s.goal}</b>`;
  $('gNow').textContent = s.count; $('gGoal').textContent = s.goal;
  const pct = Math.min(s.count / s.goal, 1);
  $('bar').style.width = (pct*100) + '%';
  $('sLeft').textContent = Math.max(s.goal - s.count, 0);
  $('sBest').textContent = Math.max(s.best, s.count);
  drawRing(s, prev);
  renderLog(s, prev);
  tickStats();
  if(prev && s.last === 'add' && delta > 0) openChest(delta);
  if(prev && prev.count < s.goal && s.count >= s.goal && s.last === 'add') setTimeout(victory, 900);
}

/* ---------- segmented goal ring ---------- */
function drawRing(s, prev){
  const g = $('segs'), R = 92, C = 2*Math.PI*R;
  if(s.goal <= 60){
    if(lastGoalRendered !== s.goal || !g.querySelector('.seg')){
      g.innerHTML = '';
      const n = s.goal, gap = n > 30 ? 2.2 : 3.4, len = C/n - gap;
      for(let i=0;i<n;i++){
        const c = document.createElementNS('http://www.w3.org/2000/svg','circle');
        c.setAttribute('cx',100); c.setAttribute('cy',100); c.setAttribute('r',R);
        c.setAttribute('stroke-dasharray', `${Math.max(len,0.6)} ${C}`);
        c.setAttribute('stroke-dashoffset', -(i*(C/n)) - gap/2);
        c.setAttribute('class','seg off');
        g.appendChild(c);
      }
      lastGoalRendered = s.goal;
    }
    const segs = g.querySelectorAll('.seg');
    segs.forEach((c,i)=>{
      const on = i < s.count;
      const was = prev ? i < prev.count : on;
      c.setAttribute('class', 'seg ' + (on ? 'on' : 'off') + (on && !was ? ' new' : ''));
    });
  } else {
    if(lastGoalRendered <= 60 || !g.querySelector('.fill')){
      g.innerHTML = `<circle class="track" cx="100" cy="100" r="${R}"/><circle class="fill" cx="100" cy="100" r="${R}" stroke-dasharray="${C}" stroke-dashoffset="${C}"/>`;
      lastGoalRendered = s.goal;
    }
    g.querySelector('.fill').style.strokeDashoffset = C*(1 - Math.min(s.count/s.goal,1));
  }
}

/* ---------- log ---------- */
const chestIcon = '<svg class="ic" viewBox="0 0 24 18"><path d="M2 8V6Q2 1 12 1T22 6V8Z" fill="#4a5ae0" stroke="#0d0b33" stroke-width="1.5"/><path d="M2 8H22L21 17H3Z" fill="#2a2f97" stroke="#0d0b33" stroke-width="1.5"/><rect x="1" y="7" width="22" height="3" fill="#ffd54a" stroke="#0d0b33" stroke-width="1.2"/><rect x="10" y="8" width="4" height="5" fill="#ffd54a" stroke="#0d0b33" stroke-width="1"/></svg>';
function renderLog(s, prev){
  const L = $('log'), log = s.log || [];
  if(!log.length){ L.innerHTML = '<div class="empty">Aucun coffre pour l\'instant.<br>Go loot !</div>'; return; }
  const first = Math.max(0, s.count - log.length);
  const rows = [];
  const freshFrom = prev ? (prev.log||[]).length : log.length;
  for(let i = log.length - 1; i >= Math.max(0, log.length - 40); i--){
    const d = new Date(log[i]);
    const fresh = prev && s.last==='add' && i >= freshFrom;
    rows.push(`<div class="row${fresh?' fresh':''}">${chestIcon}<span class="n">#${first + i + 1}</span><span>Coffre ouvert</span><span class="t">${d.toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit',second:'2-digit'})}</span></div>`);
  }
  L.innerHTML = rows.join('');
}

/* ---------- stats ---------- */
function tickStats(){
  const s = shown; if(!s) return;
  const ms = Math.max(0, now() - s.start), sec = Math.floor(ms/1000), m = Math.floor(sec/60), h = Math.floor(m/60);
  $('sTime').textContent = h ? `${h}h${String(m%60).padStart(2,'0')}` : `${String(m).padStart(2,'0')}:${String(sec%60).padStart(2,'0')}`;
  const hrs = ms/3600000, n = (s.log||[]).length;
  $('sRate').textContent = hrs > 1/60 ? Math.round(n/hrs) : 0;
}
setInterval(tickStats, 1000);

/* =========================================================
   CHEST OPENING ANIMATION
   ========================================================= */
let animT = [];
function openChest(times){
  const scene = $('scene');
  animT.forEach(clearTimeout); animT = [];
  scene.classList.remove('rattle','opening'); void scene.offsetWidth;
  const fast = scene.dataset.busy === '1';
  scene.dataset.busy = '1';
  const pop = () => {
    scene.classList.remove('rattle'); void scene.offsetWidth;
    scene.classList.add('opening');
    const r = $('chestWrap').getBoundingClientRect();
    const cx = r.left + r.width/2, cy = r.top + r.height*0.48;
    const fl = $('flash'); fl.style.setProperty('--fx', cx+'px'); fl.style.setProperty('--fy', cy+'px');
    fl.classList.remove('on'); void fl.offsetWidth; fl.classList.add('on');
    loot(cx, cy, r.width);
    shake(14);
    floater(times);
    animT.push(setTimeout(()=>{ scene.classList.remove('opening'); scene.dataset.busy='0'; }, 1700));
  };
  if(fast){ pop(); }
  else { scene.classList.add('rattle'); animT.push(setTimeout(pop, 420)); }
}
function floater(times){
  const f = document.createElement('div'); f.className = 'floater'; f.textContent = '+' + times;
  $('stage').appendChild(f); setTimeout(()=>f.remove(), 1400);
}
let shakeAmt = 0;
function shake(a){ shakeAmt = Math.max(shakeAmt, a); }

/* ---------- particles ---------- */
const fx = $('fx'), fc = fx.getContext('2d');
let parts = [];
const GOLD = ['#fff7c2','#ffd54a','#ffb52e','#ff9f1c'];
const GEMS = ['#4ff3ff','#ff5fd2','#9d6bff','#7dffb0'];
function loot(x, y, w){
  const s = w/300;
  // coins fountain
  for(let i=0;i<46;i++){
    const a = -Math.PI/2 + (Math.random()-.5)*1.7, v = (9+Math.random()*9)*s;
    parts.push({k:'coin',x:x+(Math.random()-.5)*40*s,y,vx:Math.cos(a)*v,vy:Math.sin(a)*v,g:.38*s,life:1,dec:.009+Math.random()*.006,r:(7+Math.random()*5)*s,rot:Math.random()*6,vr:.15+Math.random()*.25,c:GOLD[i%4],bounce:1});
  }
  // gems
  for(let i=0;i<16;i++){
    const a = -Math.PI/2 + (Math.random()-.5)*1.4, v = (10+Math.random()*8)*s;
    parts.push({k:'gem',x,y,vx:Math.cos(a)*v,vy:Math.sin(a)*v,g:.34*s,life:1,dec:.008+Math.random()*.005,r:(8+Math.random()*5)*s,rot:Math.random()*6,vr:(Math.random()-.5)*.25,c:GEMS[i%4],bounce:1});
  }
  // sparks (radial)
  for(let i=0;i<70;i++){
    const a = Math.random()*Math.PI*2, v = (4+Math.random()*12)*s;
    parts.push({k:'spark',x,y,vx:Math.cos(a)*v,vy:Math.sin(a)*v-3*s,g:.05,life:1,dec:.02+Math.random()*.02,r:(1.5+Math.random()*2.5)*s,c:Math.random()<.7?'#fff3b0':GEMS[i%4],drag:.94});
  }
  // lingering twinkles
  for(let i=0;i<24;i++){
    parts.push({k:'star',x:x+(Math.random()-.5)*w*1.1,y:y-Math.random()*w*0.9,vx:0,vy:-.3,g:0,life:1,dec:.008+Math.random()*.01,r:(4+Math.random()*7)*s,c:'#fff7c2',delay:20+Math.random()*50});
  }
  floorY = y + w*0.42;
  kick();
}
let floorY = 0;
function bigBurst(x, y, n){
  for(let i=0;i<n;i++){
    const a = Math.random()*Math.PI*2, v = 4+Math.random()*13;
    const k = Math.random() < .55 ? 'coin' : (Math.random()<.5 ? 'gem':'spark');
    parts.push({k,x,y,vx:Math.cos(a)*v,vy:Math.sin(a)*v-4,g:.3,life:1,dec:.007+Math.random()*.008,r:6+Math.random()*7,rot:Math.random()*6,vr:.2,c:k==='gem'?GEMS[i%4]:GOLD[i%4],drag:k==='spark'?.95:1});
  }
  kick();
}
function drawStar(c, r){
  c.beginPath();
  for(let i=0;i<8;i++){ const a = i*Math.PI/4, rr = i%2 ? r*.22 : r; c.lineTo(Math.cos(a)*rr, Math.sin(a)*rr); }
  c.closePath(); c.fill();
}
let fxRaf = 0;
function kick(){ if(!fxRaf) fxRaf = requestAnimationFrame(fxLoop); }
function fxLoop(){
  fc.clearRect(0,0,W(),H());
  parts = parts.filter(p => p.life > 0);
  for(const p of parts){
    if(p.delay){ p.delay--; continue; }
    p.vy += p.g; if(p.drag){ p.vx*=p.drag; p.vy*=p.drag; }
    p.x += p.vx; p.y += p.vy; p.life -= p.dec;
    if(p.bounce && p.vy > 0 && p.y > floorY && floorY){ p.y = floorY; p.vy *= -.42; p.vx *= .7; p.bounce--; }
    fc.globalAlpha = Math.max(0, Math.min(1, p.life*1.6));
    fc.save(); fc.translate(p.x, p.y);
    if(p.k==='coin'){
      p.rot += p.vr; const sx = Math.abs(Math.cos(p.rot));
      fc.scale(Math.max(sx,.12), 1);
      fc.fillStyle = '#9a4b00'; fc.beginPath(); fc.arc(0, 1.5, p.r, 0, 7); fc.fill();
      fc.fillStyle = p.c; fc.beginPath(); fc.arc(0, 0, p.r, 0, 7); fc.fill();
      fc.fillStyle = 'rgba(255,255,255,.65)'; fc.beginPath(); fc.arc(-p.r*.3, -p.r*.3, p.r*.35, 0, 7); fc.fill();
      fc.strokeStyle = 'rgba(120,60,0,.6)'; fc.lineWidth = 1.5; fc.beginPath(); fc.arc(0,0,p.r*.62,0,7); fc.stroke();
    } else if(p.k==='gem'){
      p.rot += p.vr; fc.rotate(p.rot);
      fc.shadowColor = p.c; fc.shadowBlur = 14;
      fc.fillStyle = p.c; fc.beginPath(); fc.moveTo(0,-p.r); fc.lineTo(p.r*.75,-p.r*.2); fc.lineTo(0,p.r); fc.lineTo(-p.r*.75,-p.r*.2); fc.closePath(); fc.fill();
      fc.shadowBlur = 0; fc.fillStyle = 'rgba(255,255,255,.7)'; fc.beginPath(); fc.moveTo(0,-p.r); fc.lineTo(p.r*.3,-p.r*.2); fc.lineTo(-p.r*.2,-p.r*.1); fc.closePath(); fc.fill();
    } else if(p.k==='spark'){
      fc.shadowColor = p.c; fc.shadowBlur = 10; fc.strokeStyle = p.c; fc.lineWidth = p.r; fc.lineCap = 'round';
      fc.beginPath(); fc.moveTo(0,0); fc.lineTo(-p.vx*2.2, -p.vy*2.2); fc.stroke();
    } else {
      const tw = Math.sin(p.life*14)*.5+.5;
      fc.shadowColor = '#ffd54a'; fc.shadowBlur = 12; fc.fillStyle = p.c; drawStar(fc, p.r*(.4+tw*.6));
    }
    fc.restore();
  }
  fc.globalAlpha = 1;
  // screen shake
  if(shakeAmt > .3){
    document.documentElement.style.setProperty('--shake-x', ((Math.random()-.5)*shakeAmt)+'px');
    document.documentElement.style.setProperty('--shake-y', ((Math.random()-.5)*shakeAmt)+'px');
    shakeAmt *= .86;
  } else if(shakeAmt){ shakeAmt = 0; document.documentElement.style.setProperty('--shake-x','0px'); document.documentElement.style.setProperty('--shake-y','0px'); }
  if(parts.length || shakeAmt){ fxRaf = requestAnimationFrame(fxLoop); }
  else { fxRaf = 0; fc.clearRect(0,0,W(),H()); }
}

/* ---------- victory ---------- */
function victory(){
  const s = shown; $('vicSub').textContent = s.goal + ' COFFRES';
  const v = $('victory'); v.classList.remove('show'); void v.offsetWidth; v.classList.add('show');
  shake(22);
  const pts = [[.18,.7],[.5,.35],[.82,.7],[.32,.3],[.68,.3],[.5,.75]];
  pts.forEach((p,i)=>setTimeout(()=>bigBurst(W()*p[0], H()*p[1], 90), i*240));
  setTimeout(()=>v.classList.remove('show'), 3700);
}

/* =========================================================
   BACKGROUND — sky, stars, landscape, clouds, motes
   ========================================================= */
const sky = $('sky'), sc = sky.getContext('2d');
const land = $('land'), lc = land.getContext('2d');
const motes = $('motes'), mc = motes.getContext('2d');
let stars = [], flies = [], shooting = null;
function rnd(seed){ let t = seed; return () => { t += 0x6D2B79F5; let r = Math.imul(t ^ t >>> 15, 1 | t); r ^= r + Math.imul(r ^ r >>> 7, 61 | r); return ((r ^ r >>> 14) >>> 0) / 4294967296; }; }
function sizeCanvas(cv, ctx){ cv.width = W()*DPR; cv.height = H()*DPR; ctx.setTransform(DPR,0,0,DPR,0,0); }
function setupBg(){
  [ [sky,sc],[land,lc],[motes,mc],[fx,fc] ].forEach(([c,x])=>sizeCanvas(c,x));
  const R = rnd(7); stars = [];
  const n = Math.round(W()*H()/2600);
  for(let i=0;i<n;i++) stars.push({x:R()*W(), y:R()*H()*.62, r:R()*1.4+.3, p:R()*6.28, s:.5+R()*2});
  drawLand();
}
function ridge(R, y0, amp, step, rough){
  const pts = []; let y = y0;
  for(let x=-20; x<=W()+40; x+=step){ y = y0 + (Math.sin(x*rough) * amp*.5) + (R()-.5)*amp; pts.push([x,y]); }
  return pts;
}
function fillRidge(pts, color){
  lc.fillStyle = color; lc.beginPath(); lc.moveTo(-20, H());
  pts.forEach(([x,y],i)=>{ if(i===0) lc.lineTo(x,y); else { const [px,py] = pts[i-1]; lc.quadraticCurveTo(px,py,(px+x)/2,(py+y)/2); } });
  lc.lineTo(W()+40, H()); lc.closePath(); lc.fill();
}
function pine(x, y, h, color){
  lc.fillStyle = color; lc.beginPath();
  const w = h*.42;
  for(let i=0;i<3;i++){ const ty = y - h + i*h*.26; const bw = w*(.55+i*.25);
    lc.moveTo(x, ty); lc.lineTo(x+bw, ty + h*.42); lc.lineTo(x-bw, ty + h*.42); }
  lc.fill(); lc.fillRect(x-h*.04, y-h*.12, h*.08, h*.14);
}
function drawLand(){
  lc.clearRect(0,0,W(),H());
  const R = rnd(42), h = H(), w = W();
  // far jagged mountains
  const far = []; for(let x=-20;x<=w+40;x+=w/14){ far.push([x, h*.56 - R()*h*.2]); }
  lc.fillStyle = '#2b1f6e'; lc.beginPath(); lc.moveTo(-20,h); far.forEach(([x,y])=>lc.lineTo(x,y)); lc.lineTo(w+40,h); lc.fill();
  // snow caps / rim light
  lc.strokeStyle = 'rgba(160,140,255,.35)'; lc.lineWidth = 2; lc.beginPath(); far.forEach(([x,y],i)=>i?lc.lineTo(x,y):lc.moveTo(x,y)); lc.stroke();
  // horizon haze
  const hz = lc.createLinearGradient(0,h*.45,0,h*.75); hz.addColorStop(0,'rgba(255,120,200,0)'); hz.addColorStop(1,'rgba(255,140,120,.28)');
  lc.fillStyle = hz; lc.fillRect(0,h*.45,w,h*.3);
  // floating island silhouette (distant)
  lc.fillStyle = '#3a2a86';
  const ix = w*.78, iy = h*.34, iw = w*.12;
  lc.beginPath(); lc.ellipse(ix, iy, iw, iw*.18, 0, 0, Math.PI*2); lc.fill();
  lc.beginPath(); lc.moveTo(ix-iw*.9, iy); lc.lineTo(ix-iw*.2, iy+iw*.9); lc.lineTo(ix+iw*.3, iy+iw*.5); lc.lineTo(ix+iw*.9, iy); lc.fill();
  for(let i=0;i<5;i++) pine(ix - iw*.7 + i*iw*.33, iy - iw*.05, iw*.38 + R()*iw*.15, '#2f2273');
  lc.fillStyle='rgba(79,243,255,.35)'; lc.beginPath(); lc.ellipse(ix,iy+iw*.15,iw*.6,iw*.06,0,0,7); lc.fill();
  // mid hills with trees
  const mid = ridge(R, h*.7, h*.06, w/9, .004);
  fillRidge(mid, '#1d1554');
  for(let i=0;i<46;i++){ const x = R()*w; const yy = h*.69 + Math.sin(x*.004)*h*.03 + R()*h*.02; pine(x, yy+h*.03, h*(.06+R()*.05), '#160f43'); }
  // near ground
  const near = ridge(R, h*.86, h*.05, w/6, .006);
  fillRidge(near, '#0e0930');
  for(let i=0;i<18;i++){ const x = R()*w; pine(x, h*.88 + R()*h*.08, h*(.11+R()*.08), '#0a0624'); }
  // rim glow on near ridge
  const rg = lc.createLinearGradient(0,h*.8,0,h); rg.addColorStop(0,'rgba(157,107,255,.25)'); rg.addColorStop(1,'rgba(0,0,0,0)');
  lc.fillStyle = rg; lc.fillRect(0,h*.8,w,h*.2);
}
function makeClouds(){
  const box = $('clouds'); box.innerHTML = '';
  for(let i=0;i<6;i++){
    const c = document.createElement('div'); c.className = 'cloud';
    const w = 140 + Math.random()*260;
    c.style.width = w+'px'; c.style.height = (w*.22)+'px';
    c.style.top = (6 + Math.random()*40)+'vh';
    c.style.opacity = .4 + Math.random()*.5;
    const d = 70 + Math.random()*90;
    c.style.animationDuration = d+'s'; c.style.animationDelay = (-Math.random()*d)+'s';
    box.appendChild(c);
  }
}
function initFlies(){
  flies = [];
  for(let i=0;i<46;i++) flies.push(newFly(true));
}
function newFly(any){
  return {x:Math.random()*W(), y:any? Math.random()*H() : H()+10, vy:-(.15+Math.random()*.5), ph:Math.random()*6.28, r:1+Math.random()*2.4,
    c: Math.random()<.5 ? '255,213,74' : (Math.random()<.5 ? '79,243,255' : '255,95,210')};
}
let t0 = performance.now(), lastFrame = 0;
function bgLoop(t){
  requestAnimationFrame(bgLoop);
  if(t - lastFrame < 33) return; lastFrame = t;
  const tt = (t - t0)/1000, w = W(), h = H();
  // sky
  const g = sc.createLinearGradient(0,0,0,h);
  g.addColorStop(0,'#0a0628'); g.addColorStop(.35,'#1d0f55'); g.addColorStop(.6,'#4a1d78'); g.addColorStop(.8,'#9a3a7a'); g.addColorStop(1,'#ff8a5c');
  sc.fillStyle = g; sc.fillRect(0,0,w,h);
  // big moon / glow
  const mx = w*.18, my = h*.2, mr = Math.min(w,h)*.07;
  const mg = sc.createRadialGradient(mx,my,mr*.2,mx,my,mr*4); mg.addColorStop(0,'rgba(200,230,255,.35)'); mg.addColorStop(1,'rgba(200,230,255,0)');
  sc.fillStyle = mg; sc.fillRect(0,0,w,h*.7);
  sc.fillStyle = '#e8f2ff'; sc.beginPath(); sc.arc(mx,my,mr,0,7); sc.fill();
  sc.fillStyle = 'rgba(160,180,230,.35)'; sc.beginPath(); sc.arc(mx-mr*.3,my-mr*.15,mr*.22,0,7); sc.arc(mx+mr*.35,my+mr*.3,mr*.15,0,7); sc.fill();
  // stars
  for(const s of stars){
    const a = .35 + .65*Math.abs(Math.sin(tt*s.s*.6 + s.p));
    sc.fillStyle = `rgba(255,255,255,${a})`; sc.fillRect(s.x, s.y, s.r, s.r);
  }
  // shooting star
  if(!shooting && Math.random() < .006) shooting = {x:Math.random()*w*.8+w*.1, y:Math.random()*h*.25, vx:-(8+Math.random()*6), vy:3+Math.random()*2, life:1};
  if(shooting){
    const s = shooting; s.x += s.vx; s.y += s.vy; s.life -= .03;
    const gr = sc.createLinearGradient(s.x,s.y,s.x - s.vx*10, s.y - s.vy*10);
    gr.addColorStop(0,`rgba(255,255,255,${s.life})`); gr.addColorStop(1,'rgba(255,255,255,0)');
    sc.strokeStyle = gr; sc.lineWidth = 2; sc.beginPath(); sc.moveTo(s.x,s.y); sc.lineTo(s.x - s.vx*10, s.y - s.vy*10); sc.stroke();
    if(s.life <= 0) shooting = null;
  }
  // motes / fireflies
  mc.clearRect(0,0,w,h);
  for(let i=0;i<flies.length;i++){
    const f = flies[i];
    f.y += f.vy; f.x += Math.sin(tt + f.ph)*.35;
    if(f.y < -10) flies[i] = newFly(false);
    const a = .3 + .7*Math.abs(Math.sin(tt*1.5 + f.ph));
    const rg = mc.createRadialGradient(f.x,f.y,0,f.x,f.y,f.r*5);
    rg.addColorStop(0,`rgba(${f.c},${a})`); rg.addColorStop(1,`rgba(${f.c},0)`);
    mc.fillStyle = rg; mc.beginPath(); mc.arc(f.x,f.y,f.r*5,0,7); mc.fill();
  }
}
// parallax
addEventListener('mousemove', e => {
  const dx = (e.clientX / W() - .5), dy = (e.clientY / H() - .5);
  land.style.transform = `translate(${-dx*14}px, ${-dy*8}px) scale(1.03)`;
});
let rz; addEventListener('resize', ()=>{ clearTimeout(rz); rz = setTimeout(()=>{ setupBg(); }, 120); });

/* =========================================================
   CONTROLS
   ========================================================= */
function toast(t){ const el = $('toast'); el.textContent = t; el.classList.add('show'); clearTimeout(toast._t); toast._t = setTimeout(()=>el.classList.remove('show'), 1800); }
function openSettings(){
  if(!shown) return;
  $('fGoal').value = shown.goal; $('fCount').value = shown.count;
  $('confirm').classList.remove('show'); $('resetBtn').style.display = '';
  document.body.classList.add('settings');
}
function closeSettings(){ document.body.classList.remove('settings'); }
$('stage').addEventListener('click', ()=>act('add'));
$('undoBtn').addEventListener('click', ()=>act('undo'));
$('setBtn').addEventListener('click', openSettings);
$('closeSet').addEventListener('click', closeSettings);
$('drawerBg').addEventListener('click', closeSettings);
$('compactBtn').addEventListener('click', toggleCompact);
document.querySelectorAll('.stepper button').forEach(b => b.addEventListener('click', () => {
  const inp = $(b.dataset.t); const min = +inp.min;
  inp.value = Math.max(min, (parseInt(inp.value,10)||0) + (+b.dataset.d));
}));
$('applyBtn').addEventListener('click', async () => {
  const g = parseInt($('fGoal').value,10), c = parseInt($('fCount').value,10);
  if(!(g >= 1)) { toast('Objectif invalide'); return; }
  if(!(c >= 0)) { toast('Nombre de coffres invalide'); return; }
  if(g !== shown.goal) await act('goal', g);
  if(c !== shown.count) await act('count', c);
  closeSettings(); toast('Réglages appliqués');
});
$('resetBtn').addEventListener('click', () => { $('confirm').classList.add('show'); $('resetBtn').style.display = 'none'; });
$('cNo').addEventListener('click', () => { $('confirm').classList.remove('show'); $('resetBtn').style.display = ''; });
$('cYes').addEventListener('click', async () => { await act('reset'); closeSettings(); toast('Nouvelle session'); });

function toggleCompact(){
  document.body.classList.toggle('compact');
  try{ localStorage.setItem('chest-tracker-compact', document.body.classList.contains('compact') ? '1':'0'); }catch(e){}
}
try{ if(localStorage.getItem('chest-tracker-compact')==='1') document.body.classList.add('compact'); }catch(e){}

document.querySelectorAll('.keybtn').forEach(b => b.addEventListener('click', () => {
  if(!remote){ toast('Lance le tracker via le .bat pour les touches en jeu'); return; }
  document.querySelectorAll('.keybtn').forEach(x=>x.classList.remove('wait'));
  capturing = b.dataset.k; b.classList.add('wait'); b.querySelector('b').textContent = '...';
  $('keyNote').textContent = 'Appuie sur la nouvelle touche (Échap pour annuler).';
}));
function keyName(e){
  if(/^F\d+$/.test(e.key)) return e.key;
  if(e.code.startsWith('Numpad')) return 'Num ' + e.code.slice(6);
  if(e.key.length === 1) return e.key.toUpperCase();
  const map = {ArrowUp:'↑',ArrowDown:'↓',ArrowLeft:'←',ArrowRight:'→',Insert:'Inser',Delete:'Suppr',Home:'Début',End:'Fin',PageUp:'Pg↑',PageDown:'Pg↓',Pause:'Pause',ScrollLock:'Arrêt défil',Tab:'Tab'};
  return map[e.key] || e.key;
}
addEventListener('keydown', e => {
  if(capturing){
    e.preventDefault(); e.stopPropagation();
    const k = capturing; capturing = null;
    document.querySelectorAll('.keybtn').forEach(x=>x.classList.remove('wait'));
    $('keyNote').textContent = 'Clique sur une touche puis appuie sur la nouvelle touche.';
    if(e.key === 'Escape'){ setPill(remote, 'Connecté', hotkeys); return; }
    const vk = e.keyCode, name = keyName(e);
    if(!vk || ['Shift','Control','Alt','Meta'].includes(e.key)){ toast('Choisis une touche simple'); setPill(remote,'Connecté',hotkeys); return; }
    const other = k === 'add' ? shown.keyUndo : shown.keyAdd;
    if(vk === other){ toast('Touche déjà utilisée'); setPill(remote,'Connecté',hotkeys); return; }
    api(`/api/keys?${k}=${vk}&${k}Name=${encodeURIComponent(name)}`).then(s => {
      onState(s); toast(s.hotkeys ? `Touche ${name} enregistrée` : `Windows refuse ${name} : essaie une autre touche`);
    }).catch(()=>toast('Serveur injoignable'));
    return;
  }
  if(e.target.tagName === 'INPUT'){ if(e.key === 'Enter') $('applyBtn').click(); if(e.key==='Escape') closeSettings(); return; }
  if(document.body.classList.contains('settings')){ if(e.key === 'Escape') closeSettings(); return; }
  const k = e.key.toLowerCase();
  if(e.repeat) return;
  if(k===' ' || k==='enter' || k==='+'){ e.preventDefault(); act('add'); }
  else if(k==='z' || k==='backspace' || k==='-'){ e.preventDefault(); act('undo'); }
  else if(k==='s'){ e.preventDefault(); openSettings(); }
  else if(k==='c'){ toggleCompact(); }
});

setupBg(); makeClouds(); initFlies(); requestAnimationFrame(bgLoop);
boot();
})();
</script>
</body>
</html>
