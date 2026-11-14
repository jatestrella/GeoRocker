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

if (Test-Path (Join-Path $game ".git")) { Say (T '\u904a\u6232\u8cc7\u6599\u593e\u662f git \u7248\u672c\uff0c\u8acb\u6539\u7528 git pull \u66f4\u65b0') "Yellow"; exit 1 }

# The game must not be running from this package
$running = Get-Process luanti -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) { Say (T '\u8acb\u5148\u95dc\u6389\u904a\u6232\u518d\u66f4\u65b0') "Yellow"; exit 1 }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Say (T '\u6b63\u5728\u6aa2\u67e5\u6709\u6c92\u6709\u65b0\u7248\u672c\u2026')
try {
	$info = Invoke-RestMethod -UseBasicParsing -Headers @{ "User-Agent" = "georocker-updater" } `
		-Uri ("https://api.github.com/repos/{0}/commits/{1}" -f $Repo, $set.branch)
} catch {
	Say (T '\u9023\u4e0d\u4e0a GitHub\uff0c\u8acb\u6aa2\u67e5\u7db2\u8def\u5f8c\u518d\u8a66\u4e00\u6b21') "Red"; exit 1
}
$sha = $info.sha
$when = $info.commit.committer.date
if ($sha -and $sha -eq $set.installed -and (Test-Path (Join-Path $game "game.conf"))) {
	Say ((T '\u5df2\u7d93\u662f\u6700\u65b0\u7248\u4e86') + "  (" + $sha.Substring(0, 7) + ", " + $when + ")") "Green"; exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "georocker_update"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp "game.zip"
Say ((T '\u4e0b\u8f09\u65b0\u7248\u672c\u2026') + "  (" + $sha.Substring(0, 7) + ", " + $when + ")")
try {
	$ProgressPreference = "SilentlyContinue"      # the progress bar makes Invoke-WebRequest very slow on PowerShell 5
	Invoke-WebRequest -UseBasicParsing -Uri ("https://codeload.github.com/{0}/zip/{1}" -f $Repo, $sha) -OutFile $zip
} catch {
	Say (T '\u9023\u4e0d\u4e0a GitHub\uff0c\u8acb\u6aa2\u67e5\u7db2\u8def\u5f8c\u518d\u8a66\u4e00\u6b21') "Red"; exit 1
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$x = Join-Path $tmp "x"
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
$src = Get-ChildItem $x -Directory | Select-Object -First 1
if (-not $src -or -not (Test-Path (Join-Path $src.FullName "game.conf")) -or -not (Test-Path (Join-Path $src.FullName "mods\rockmech\init.lua"))) {
	Say (T '\u4e0b\u8f09\u7684\u6a94\u6848\u4e0d\u5b8c\u6574\uff0c\u6c92\u6709\u66f4\u65b0') "Red"; exit 1
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
	Say (T '\u66f4\u65b0\u5931\u6557\uff0c\u5df2\u7d93\u63db\u56de\u539f\u672c\u7684\u7248\u672c') "Red"
	Say $_.Exception.Message "DarkGray"
	exit 1
}
$set.installed = $sha
Save-Conf
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Say (T '\u66f4\u65b0\u5b8c\u6210\uff01\u5b58\u6a94\u548c\u8a2d\u5b9a\u90fd\u6c92\u6709\u52d5\u3002') "Green"
exit 0
