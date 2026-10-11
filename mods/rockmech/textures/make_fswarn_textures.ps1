param([string]$dir)
Add-Type -AssemblyName System.Drawing
$N = 32

$script:rand = [System.Random]::new(20261011)

function New-Crack($x, $y, $ang, $len, $step) {
  $pts = New-Object System.Collections.ArrayList
  [void]$pts.Add((New-Object System.Drawing.PointF $x, $y))
  for ($i = 0; $i -lt $len; $i++) {
    $ang += ($script:rand.NextDouble() - 0.5) * 1.1
    $x += [Math]::Cos($ang) * $step; $y += [Math]::Sin($ang) * $step
    [void]$pts.Add((New-Object System.Drawing.PointF $x, $y))
  }
  return ,$pts
}
$c = $N / 2
$cracks = @()

for ($k = 0; $k -lt 5; $k++) {
  $ang = $k * 1.256 + $script:rand.NextDouble() * 0.5
  $main = New-Crack $c $c $ang 9 1.9
  $b1 = New-Crack $main[3].X $main[3].Y ($ang + 0.9) 5 1.6
  $b2 = New-Crack $main[6].X $main[6].Y ($ang - 0.9) 4 1.6
  $cracks += ,@($main, $b1, $b2)
}
for ($stage = 0; $stage -lt 5; $stage++) {
  $bmp = New-Object System.Drawing.Bitmap $N, $N
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
  $g.Clear([System.Drawing.Color]::Transparent)
  $dark = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 40, 20, 0)), 3
  $hot = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 170, 30)), 1
  $nc = $stage + 1
  $frac = 0.55 + 0.45 * ($stage / 4.0)
  foreach ($pass in @($dark, $hot)) {
    for ($k = 0; $k -lt $nc; $k++) {
      $set = $cracks[$k]
      for ($j = 0; $j -lt $set.Count; $j++) {
        if ($j -gt 0 -and $stage -lt 2) { continue } 
        $p = $set[$j]
        $m = [Math]::Max(2, [int][Math]::Round($p.Count * $frac))
        $arr = New-Object 'System.Drawing.PointF[]' $m
        for ($i = 0; $i -lt $m; $i++) { $arr[$i] = $p[$i] }
        $g.DrawLines($pass, $arr)
      }
    }
  }
  $g.Dispose()
  $bmp.Save((Join-Path $dir ("rockmech_fswarn_{0}.png" -f $stage)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
"done"
