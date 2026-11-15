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
