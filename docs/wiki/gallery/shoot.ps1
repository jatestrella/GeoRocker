# Run the gallery server + a client, capture ONLY the Luanti client window (PrintWindow) on each [SHOT] line.
param([string]$Root, [string]$Sp, [string]$Out)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $Out | Out-Null
$log = "$Sp\g.log"
Remove-Item $log -ErrorAction SilentlyContinue
$srv = Start-Process -FilePath "$Root\bin\luanti.exe" -ArgumentList @("--server","--world","`"$Sp\gw`"","--gameid","georocker","--logfile","`"$log`"","--port","30131","--config","`"$Sp\gallery_server.conf`"") -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 8
$cli = Start-Process -FilePath "$Root\bin\luanti.exe" -ArgumentList @("--address","127.0.0.1","--port","30131","--name","wikibot","--password","wiki","--go","--config","`"$Sp\gallery_client.conf`"") -PassThru
$seen = 0
$deadline = (Get-Date).AddMinutes(12)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 400
  if (-not (Test-Path $log)) { continue }
  $lines = @(Select-String -Path $log -Pattern "\[SHOT\] (\S+)|\[SHOTS DONE\]")
  while ($seen -lt $lines.Count) {
    $m = $lines[$seen]; $seen++
    if ($m.Line -match "\[SHOTS DONE\]") { $deadline = Get-Date; break }
    $id = $m.Matches[0].Groups[1].Value
    $cli.Refresh()
    $h = $cli.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { "no window for $id"; continue }
    $r = New-Object W+RECT
    [W]::GetClientRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    if ($w -le 0) { continue }
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    [W]::PrintWindow($h, $dc, 3) | Out-Null
    $g.ReleaseHdc($dc); $g.Dispose()
    $bmp.Save("$Out\$id.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "shot $id"
  }
}
if (-not $cli.HasExited) { Stop-Process -Id $cli.Id -Force }
if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force }
"done"

