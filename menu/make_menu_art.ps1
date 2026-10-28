param([string]$OutDir)
# Mining Mechanics 主選單／標題畫面的圖：背景插圖（露天礦坑）、標題 logo、遊戲圖示
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

function C([string]$hex, [int]$a = 255) {
	$h = $hex.TrimStart('#')
	return [System.Drawing.Color]::FromArgb($a, [Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16))
}
function Pts($arr) {
	$list = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
	for ($i = 0; $i -lt $arr.Count; $i += 2) { $list.Add((New-Object System.Drawing.PointF([float]$arr[$i], [float]$arr[$i+1]))) }
	return $list.ToArray()
}

# ---------------- 背景 1920×1080 ----------------
$W = 1920; $H = 1080
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
# 天空：黃昏漸層
$sky = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,-2)), (New-Object System.Drawing.Point(0,562)), (C "#141c33"), (C '#e8915a'))
$blend = New-Object System.Drawing.Drawing2D.ColorBlend(4)
$blend.Colors = @((C '#0f1630'), (C '#3a3558'), (C '#b8645a'), (C '#f2a35e'))
$blend.Positions = @([float]0, [float]0.45, [float]0.8, [float]1)
$sky.InterpolationColors = $blend
$g.FillRectangle($sky, 0, 0, $W, 560)
# 夕陽光暈
for ($r = 260; $r -ge 40; $r -= 20) {
	$a = [int](10 + (260 - $r) / 4)
	$g.FillEllipse((New-Object System.Drawing.SolidBrush((C '#ffd08a' $a))), 1380 - $r, 520 - $r, 2 * $r, 2 * $r)
}
$g.FillEllipse((New-Object System.Drawing.SolidBrush((C '#fff0c8'))), 1345, 485, 70, 70)
# 遠山（兩層）
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C '#4a3f5e'))), (Pts @(0,560, 0,430, 180,380, 340,420, 520,340, 700,400, 860,360, 1040,420, 1220,350, 1420,410, 1600,330, 1780,390, 1920,360, 1920,560)))
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C '#2f2a40'))), (Pts @(0,560, 0,470, 240,440, 420,480, 640,430, 900,490, 1150,450, 1380,495, 1660,445, 1920,480, 1920,560)))
# 地面（礦坑外的地表）
$g.FillRectangle((New-Object System.Drawing.SolidBrush((C '#5a4a3a'))), 0, 540, $W, $H - 540)
# 露天礦坑：一圈一圈的階梯（大到小、往下），岩層顏色由上而下：砂岩 → 頁岩 → 花崗岩
$strata = @('#b8935e', '#a8865a', '#8c7a66', '#6e6a70', '#5a5c66', '#4a4c58', '#8f7472', '#7a6262')
$n = $strata.Count
for ($k = 0; $k -lt $n; $k++) {
	$cx = 960; $cy = 770 + $k * 28
	$rx = 1180 - $k * 135; $ry = 235 - $k * 25
	if ($rx -lt 80) { break }
	$face = C $strata[$k]
	# 台階面（坡面，暗）
	$dark = [System.Drawing.Color]::FromArgb(255, [int]($face.R * 0.62), [int]($face.G * 0.62), [int]($face.B * 0.62))
	$g.FillEllipse((New-Object System.Drawing.SolidBrush($dark)), $cx - $rx, $cy - $ry, 2 * $rx, 2 * $ry)
	# 平台（亮）
	$g.FillEllipse((New-Object System.Drawing.SolidBrush($face)), $cx - $rx + 26, $cy - $ry + 22, 2 * $rx - 52, 2 * $ry - 30)
	# 坡面的岩層細線
	$pen = New-Object System.Drawing.Pen((C '#000000' 40), 2)
	$g.DrawEllipse($pen, $cx - $rx + 8, $cy - $ry + 8, 2 * $rx - 16, 2 * $ry - 10)
}
# 坑底的積水
$g.FillEllipse((New-Object System.Drawing.SolidBrush((C "#3b5a6e"))), 880, 985, 160, 30)
$g.FillEllipse((New-Object System.Drawing.SolidBrush((C "#f2a35e" 90))), 915, 992, 70, 8)
# 坡道（從坑口斜下來）
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C '#c9a46a' 200))), (Pts @(1560,580, 1610,588, 1330,742, 1280,734)))

function Truck($g, [float]$x, [float]$y, [float]$s) {
	$yel = New-Object System.Drawing.SolidBrush((C '#e0a020'))
	$dk = New-Object System.Drawing.SolidBrush((C '#1c1a18'))
	# 車斗（往後翹）
	$g.FillPolygon($yel, (Pts @(($x), ($y - 18*$s), ($x + 46*$s), ($y - 22*$s), ($x + 46*$s), ($y - 6*$s), ($x + 4*$s), ($y - 2*$s))))
	# 遮罩、駕駛室
	$g.FillRectangle($yel, $x + 44*$s, $y - 22*$s, 14*$s, 3*$s)
	$g.FillRectangle($yel, $x + 48*$s, $y - 16*$s, 9*$s, 10*$s)
	$g.FillRectangle((New-Object System.Drawing.SolidBrush((C '#9fd0ff'))), $x + 51*$s, $y - 14*$s, 5*$s, 4*$s)
	# 輪胎
	$g.FillEllipse($dk, $x + 6*$s, $y - 8*$s, 14*$s, 14*$s)
	$g.FillEllipse($dk, $x + 42*$s, $y - 8*$s, 14*$s, 14*$s)
}
function Excavator($g, [float]$x, [float]$y, [float]$s, [bool]$flip) {
	$yel = New-Object System.Drawing.SolidBrush((C '#e8b020'))
	$dk = New-Object System.Drawing.SolidBrush((C '#1c1a18'))
	$d = if ($flip) { -1 } else { 1 }
	# 履帶
	$g.FillRectangle($dk, $x - 22*$s, $y - 7*$s, 44*$s, 8*$s)
	# 上部（駕駛艙＋配重）
	$g.FillRectangle($yel, $x - 18*$s, $y - 22*$s, 30*$s, 15*$s)
	$g.FillRectangle((New-Object System.Drawing.SolidBrush((C '#9fd0ff'))), $x + ($d*2 - 2)*$s, $y - 20*$s, 7*$s, 6*$s)
	# 動臂、斗桿、挖斗
	$pen = New-Object System.Drawing.Pen((C '#e8b020'), [float](5*$s))
	$bx = $x + $d * 8*$s; $by = $y - 18*$s
	$ex = $x + $d * 34*$s; $ey = $y - 44*$s
	$tx = $x + $d * 52*$s; $ty = $y - 8*$s
	$g.DrawLine($pen, $bx, $by, $ex, $ey)
	$pen2 = New-Object System.Drawing.Pen((C '#e8b020'), [float](4*$s))
	$g.DrawLine($pen2, $ex, $ey, $tx, $ty)
	$g.FillPolygon($dk, (Pts @(($tx - 5*$s), ($ty - 2*$s), ($tx + $d*6*$s), ($ty - 4*$s), ($tx + $d*8*$s), ($ty + 5*$s), ($tx - 2*$s), ($ty + 6*$s))))
}
# 車隊：坡道上的礦卡、台階上的挖土機與礦卡
Truck $g 1400 690 1.5
Truck $g 600 838 1.2
Excavator $g 720 840 1.25 $true
Truck $g 1130 925 0.9
Excavator $g 1020 928 0.95 $false
# 粉塵
for ($i = 0; $i -lt 40; $i++) {
	$rx = Get-Random -Minimum 600 -Maximum 1400; $ry = Get-Random -Minimum 760 -Maximum 960
	$rr = Get-Random -Minimum 20 -Maximum 70
	$g.FillEllipse((New-Object System.Drawing.SolidBrush((C '#e8c8a0' 10))), $rx - $rr, $ry - $rr, 2*$rr, $rr)
}
# 下方暗角（讓選單文字看得清楚）
$vig = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,698)), (New-Object System.Drawing.Point(0,1082)), (C "#000000" 0), (C '#000000' 190))
$g.FillRectangle($vig, 0, 700, $W, 380)
$vig2 = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,-2)), (New-Object System.Drawing.Point(0,262)), (C "#000000" 120), (C '#000000' 0))
$g.FillRectangle($vig2, 0, 0, $W, 260)
$g.Dispose()
$bmp.Save((Join-Path $OutDir 'background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# ---------------- 標題 logo 1400×320（透明） ----------------
$LW = 1400; $LH = 290
$bmp = New-Object System.Drawing.Bitmap($LW, $LH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
$fam = New-Object System.Drawing.FontFamily('Bahnschrift SemiBold Condensed')
$sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.FillMode = "Winding"
$path.AddString('MINING MECHANICS', $fam, 0, 170, (New-Object System.Drawing.RectangleF(0, 10, $LW, 200)), $sf)
# 陰影
$m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate(8, 10)
$shadow = $path.Clone(); $shadow.Transform($m)
$g.FillPath((New-Object System.Drawing.SolidBrush((C '#000000' 150))), $shadow)
# 外框 + 金色漸層
$outline = New-Object System.Drawing.Pen((C "#20140a"), 14); $outline.LineJoin = "Round"
$g.DrawPath($outline, $path)
$gold = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,40)), (New-Object System.Drawing.Point(0,200)), (C '#ffe9a0'), (C '#c47a10'))
$g.FillPath($gold, $path)
# 副標與線條
$g.FillRectangle((New-Object System.Drawing.SolidBrush((C "#e0a020"))), 250, 205, 900, 4)
$sub = New-Object System.Drawing.Font('Bahnschrift SemiBold SemiConden', 34)
$g.DrawString('ROCK MECHANICS  ·  DRILL & BLAST  ·  HAULAGE', $sub, (New-Object System.Drawing.SolidBrush((C '#000000' 160))), (New-Object System.Drawing.RectangleF(3, 219, $LW, 60)), $sf)
$g.DrawString('ROCK MECHANICS  ·  DRILL & BLAST  ·  HAULAGE', $sub, (New-Object System.Drawing.SolidBrush((C '#f4e6c8'))), (New-Object System.Drawing.RectangleF(0, 216, $LW, 60)), $sf)
$g.Dispose()
$bmp.Save((Join-Path $OutDir 'header.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# ---------------- 遊戲圖示 128×128 ----------------
$bmp = New-Object System.Drawing.Bitmap(128, 128)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$rect = New-Object System.Drawing.Rectangle(4, 4, 120, 120)
$rp = New-Object System.Drawing.Drawing2D.GraphicsPath
$rr = 22
$rp.AddArc(4, 4, $rr, $rr, 180, 90); $rp.AddArc(124 - $rr, 4, $rr, $rr, 270, 90)
$rp.AddArc(124 - $rr, 124 - $rr, $rr, $rr, 0, 90); $rp.AddArc(4, 124 - $rr, $rr, $rr, 90, 90); $rp.CloseFigure()
$ib = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,4)), (New-Object System.Drawing.Point(0,124)), (C '#2a2a48'), (C '#e8915a'))
$g.FillPath($ib, $rp)
$g.SetClip($rp)
$cols = @('#b8935e', '#8c7a66', '#5a5c66', '#4a4c58')
for ($k = 0; $k -lt 4; $k++) {
	$c0 = C $cols[$k]
	$g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, [int]($c0.R*0.62), [int]($c0.G*0.62), [int]($c0.B*0.62)))), 64 - (90 - $k*20), 78 + $k*8 - (26 - $k*5), 2*(90 - $k*20), 2*(26 - $k*5) + 20)
	$g.FillEllipse((New-Object System.Drawing.SolidBrush($c0)), 64 - (90 - $k*20) + 6, 78 + $k*8 - (26 - $k*5) + 5, 2*(90 - $k*20) - 12, 2*(26 - $k*5) + 12)
}
Excavator $g 64 84 1.0 $false
$g.ResetClip()
$g.DrawPath((New-Object System.Drawing.Pen((C '#e0a020'), 4)), $rp)
$g.Dispose()
$bmp.Save((Join-Path $OutDir 'icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"done"
