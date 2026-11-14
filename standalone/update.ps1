# One-click update of the game folder (games\georocker) of a standalone package.
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI. Chinese messages are \u escapes.
#
# Started by the update .bat in the package root (written by make_package.ps1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File games\georocker\standalone\update.ps1 -Root <package root>
#
# Reads <Root>\update.txt (branch = release, class = 0, installed = <commit sha>), asks GitHub for the newest commit
# of that branch, and if it is new downloads only the game (a few MB), never the engine.
# Keeps worlds\ (saves) and minetest.conf (settings). The old game folder is kept as games\georocker_backup.
# Lives inside the game folder, so the updater updates itself too.

param([string]$Root = "")

$ErrorActionPreference = "Stop"
$Repo = "jatestrella/GeoRocker"
function T($s) { [regex]::Unescape($s) }
function Say($m, $c = "Cyan") { Write-Host $m -ForegroundColor $c }

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))) }
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
$game = Join-Path $Root "games\georocker"
$backup = Join-Path $Root "games\georocker_backup"
$conf = Join-Path $Root "update.txt"

# Settings: branch, class maps, installed commit
$set = @{ branch = "release"; class = "0"; installed = "" }
if (Test-Path $conf) {
	foreach ($l in Get-Content $conf) {
		if ($l -match '^\s*([a-z]+)\s*=\s*(.*?)\s*$') { $set[$matches[1]] = $matches[2] }
	}
}
function Save-Conf {
	$lines = @("branch = " + $set.branch, "class = " + $set.class, "installed = " + $set.installed)
	[System.IO.File]::WriteAllLines($conf, $lines)
}

if (Test-Path (Join-Path $game ".git")) { Say (T '遊戲資料夾是 git 版本，請改用 git pull 更新') "Yellow"; exit 1 }

# The game must not be running from this package
$running = Get-Process luanti -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) { Say (T '請先關掉遊戲再更新') "Yellow"; exit 1 }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Say (T '正在檢查有沒有新版本…')
try {
	$info = Invoke-RestMethod -UseBasicParsing -Headers @{ "User-Agent" = "georocker-updater" } `
		-Uri ("https://api.github.com/repos/{0}/commits/{1}" -f $Repo, $set.branch)
} catch {
	Say (T '連不上 GitHub，請檢查網路後再試一次') "Red"; exit 1
}
$sha = $info.sha
$when = $info.commit.committer.date
if ($sha -and $sha -eq $set.installed -and (Test-Path (Join-Path $game "game.conf"))) {
	Say ((T '已經是最新版了') + "  (" + $sha.Substring(0, 7) + ", " + $when + ")") "Green"; exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "georocker_update"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp "game.zip"
Say ((T '下載新版本…') + "  (" + $sha.Substring(0, 7) + ", " + $when + ")")
try {
	$ProgressPreference = "SilentlyContinue"      # the progress bar makes Invoke-WebRequest very slow on PowerShell 5
	Invoke-WebRequest -UseBasicParsing -Uri ("https://codeload.github.com/{0}/zip/{1}" -f $Repo, $sha) -OutFile $zip
} catch {
	Say (T '連不上 GitHub，請檢查網路後再試一次') "Red"; exit 1
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$x = Join-Path $tmp "x"
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
$src = Get-ChildItem $x -Directory | Select-Object -First 1
if (-not $src -or -not (Test-Path (Join-Path $src.FullName "game.conf")) -or -not (Test-Path (Join-Path $src.FullName "mods\rockmech\init.lua"))) {
	Say (T '下載的檔案不完整，沒有更新') "Red"; exit 1
}
$src = $src.FullName
# Same contents as make_package.ps1: no docs, no class maps unless the package was built with -Class
$docs = Join-Path $src "docs"
if (Test-Path $docs) { Remove-Item $docs -Recurse -Force }
if ($set.class -ne "1") {
	$maps = Join-Path $src "standalone\maps"
	if (Test-Path $maps) {
		foreach ($m in Get-ChildItem $maps -Directory) {
			$mc = Join-Path $m.FullName "map.conf"
			if ((Test-Path $mc) -and (Select-String -Path $mc -Pattern "^\s*mode\s*=\s*class" -Quiet)) { Remove-Item $m.FullName -Recurse -Force }
		}
	}
}

# Swap: current game -> backup, new game in place; on any error put the old one back
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
$moved = $false
try {
	if (Test-Path $game) { Move-Item $game $backup; $moved = $true }
	Move-Item $src $game
} catch {
	if ($moved -and -not (Test-Path $game)) { Move-Item $backup $game }
	Say (T '更新失敗，已經換回原本的版本') "Red"
	Say $_.Exception.Message "DarkGray"
	exit 1
}
$set.installed = $sha
Save-Conf
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Say (T '更新完成！存檔和設定都沒有動。') "Green"
exit 0
