# Build the standalone package of this game (single player, hosting a class, joining a server).
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File games\georocker\standalone\make_package.ps1
#
# Output: <Out>\<Name>.zip (clean package to hand out) and <Out>\<Name>\ (a copy to play on this PC).
#   The package is built in a temp folder first. Updating <Out>\<Name>\ keeps the player's data:
#   worlds\ (saves), minetest.conf (settings, remembered password), and games\georocker when it is a git clone
#   (then "git pull" there updates the game).
#   - builtin\mainmenu\init.lua is replaced by standalone\mainmenu.lua (our own start screen, no Luanti menu)
#   - minetest.conf: single player defaults
#   - a "start game" .bat that starts bin\luanti.exe
#   - no worlds: the start screen lists the maps in standalone\maps and creates one world per map

param(
	[string]$Out = "",        # default: the folder that contains the Luanti root (e.g. D:\Teaching\GeoRocker)
	[string]$Name = "GeoRocker",
	[switch]$Class,           # also include the class maps (map.conf "mode = class"); the public package leaves them out
	[string]$Branch = "release"   # branch the one-click updater follows (update.txt); a dev package passes its branch
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path        # games\georocker\standalone
$game = Split-Path -Parent $here                                 # games\georocker
$root = Split-Path -Parent (Split-Path -Parent $game)            # Luanti root
if (-not $Out) { $Out = Split-Path -Parent $root }
$dest = Join-Path $Out $Name
# Safety: /MIR below would delete everything in $dest, so it must never contain (or be) the Luanti root
$rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$destFull = [System.IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
if ($rootFull.StartsWith($destFull, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "Output folder $dest contains the Luanti root $root - choose another -Out or -Name"
}
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "mm_package_stage"
$stage = Join-Path $stageRoot $Name       # the package is built here, then zipped and synced to $dest

function Say($m) { Write-Host ("[package] " + $m) -ForegroundColor Cyan }
function Copy-Tree($src, $dst, $exclude) {
	$ra = @($src, $dst, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
	if ($exclude) { $ra += "/XD"; $ra += $exclude }
	robocopy @ra | Out-Null
	if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $src" }
}

if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

Say "Copying engine"
foreach ($d in @("bin", "builtin", "client", "fonts", "textures", "locale")) {
	Copy-Tree (Join-Path $root $d) (Join-Path $stage $d) $null
}
New-Item -ItemType Directory -Force (Join-Path $stage "doc") | Out-Null
Copy-Item (Join-Path $root "doc\README.md") (Join-Path $stage "doc\README.md")

Say "Copying game"
Copy-Tree $game (Join-Path $stage "games\georocker") @(".git", "docs")
if (-not $Class) {
	# Public package: no class maps (hosting a class is a separate option, build with -Class)
	foreach ($m in Get-ChildItem (Join-Path $stage "games\georocker\standalone\maps") -Directory) {
		$conf = Join-Path $m.FullName "map.conf"
		if ((Test-Path $conf) -and (Select-String -Path $conf -Pattern "^\s*mode\s*=\s*class" -Quiet)) {
			Say ("Leaving out class map " + $m.Name)
			Remove-Item $m.FullName -Recurse -Force
		}
	}
}
New-Item -ItemType Directory -Force (Join-Path $stage "worlds") | Out-Null

Say "Replacing the main menu"
$mm = Join-Path $stage "builtin\mainmenu"
Copy-Item (Join-Path $mm "init.lua") (Join-Path $mm "init_luanti.lua")
# A small stub that loads the start screen from the game folder, so "git pull" in games\georocker updates it too
$stub = @(
	"-- Start screen of this package: loaded from the game folder (games/georocker/standalone/mainmenu.lua),",
	"-- so updating the game (git pull) also updates the start screen. Falls back to the Luanti menu if missing.",
	"local p = core.get_builtin_path() .. '..' .. DIR_DELIM .. 'games' .. DIR_DELIM .. 'georocker' .. DIR_DELIM .. 'standalone' .. DIR_DELIM .. 'mainmenu.lua'",
	"local f = io.open(p, 'r')",
	"if f then f:close(); dofile(p) else dofile(core.get_builtin_path() .. 'mainmenu' .. DIR_DELIM .. 'init_luanti.lua') end"
)
[System.IO.File]::WriteAllLines((Join-Path $mm "init.lua"), $stub)

Say "Writing minetest.conf"
$conf = @(
	"menu_last_game = georocker",
	"creative_mode = false",
	"enable_damage = true",
	"enable_server = false",
	"server_announce = false",
	"sound_volume = 0.8",
	"name = player",
	"enable_esc_dialog = false",
	"language = zh_TW"
)
# The pixel font games/georocker/fonts/Cubic_11.ttf is set by the start screen (mainmenu.lua) with an absolute path
[System.IO.File]::WriteAllLines((Join-Path $stage "minetest.conf"), $conf)

# Start file name in Chinese ("start game"), built from char codes to keep this script ASCII
$startName = [string]::new([char[]](0x958B, 0x59CB, 0x904A, 0x6232)) + ".bat"
$bat = "@echo off`r`nstart `"`" `"%~dp0bin\luanti.exe`"`r`n"
[System.IO.File]::WriteAllText((Join-Path $stage $startName), $bat, (New-Object System.Text.ASCIIEncoding))

# One-click update ("update game" .bat): runs games\georocker\standalone\update.ps1 from a temp copy
# (the game folder is replaced while it runs). update.txt tells it the branch and the installed commit.
$updName = [string]::new([char[]](0x66F4, 0x65B0, 0x904A, 0x6232)) + ".bat"
$upd = "@echo off`r`ncd /d `"%~dp0`"`r`ncopy /y `"games\georocker\standalone\update.ps1`" `"%TEMP%\georocker_update.ps1`" >nul`r`n" +
	"powershell -NoProfile -ExecutionPolicy Bypass -File `"%TEMP%\georocker_update.ps1`" -Root `"%~dp0.`"`r`npause`r`n"
[System.IO.File]::WriteAllText((Join-Path $stage $updName), $upd, (New-Object System.Text.ASCIIEncoding))
$installed = ""
try {
	if ((git -C $game rev-parse --abbrev-ref HEAD) -eq $Branch -and -not (git -C $game status --porcelain)) { $installed = (git -C $game rev-parse HEAD) }
} catch {}
$cls = "0"; if ($Class) { $cls = "1" }
[System.IO.File]::WriteAllLines((Join-Path $stage "update.txt"), @("branch = " + $Branch, "class = " + $cls, "installed = " + $installed))

$notice = @(
	"This package contains the Luanti engine 5.15.1 (https://www.luanti.org),",
	"licensed under the GNU LGPL 2.1 or later. Source code: https://github.com/luanti-org/luanti",
	"Mods taken from Minetest Game keep their own license files inside games\georocker\mods\<mod>.",
	"The start screen (builtin\mainmenu\init.lua) is replaced; the original is builtin\mainmenu\init_luanti.lua.",
	"Font: Cubic 11 by ACh-K (https://github.com/ACh-K/Cubic-11), SIL Open Font License, see games\georocker\fonts\Cubic_11_OFL.txt."
)
[System.IO.File]::WriteAllLines((Join-Path $stage "LICENSE-NOTICE.txt"), $notice)

New-Item -ItemType Directory -Force $Out | Out-Null
$zip = Join-Path $Out ($Name + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Say "Zipping to $zip"
# Files just written may still be held by the virus scanner: retry a few times
Add-Type -AssemblyName System.IO.Compression.FileSystem
for ($try = 1; $try -le 5; $try++) {
	try {
		if (Test-Path $zip) { Remove-Item $zip -Force }
		# UTF-8 names (the start .bat has a Chinese name): readable on any Windows language and on macOS
		[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true, [System.Text.Encoding]::UTF8)
		break
	} catch {
		if ($try -eq 5) { throw }
		Say "Zip failed ($($_.Exception.Message)), retrying in 3 s"
		Start-Sleep -Seconds 3
	}
}
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Say "Zip: $zip ($mb MB)"

# Update the copy on this PC, keeping saves, settings and a git clone of the game
Say "Updating $dest"
# robocopy /XD matches folder names (full paths of the destination are not honoured when purging)
$ra = @($stage, $dest, "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/XF", "minetest.conf", "/XD", "worlds", ".git")
if (Test-Path (Join-Path $dest "games\georocker\.git")) {
	Say "games\georocker is a git clone: left as it is (use git pull there)"
	$ra += "georocker"
}
robocopy @ra | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $dest" }
if (-not (Test-Path (Join-Path $dest "minetest.conf"))) { Copy-Item (Join-Path $stage "minetest.conf") (Join-Path $dest "minetest.conf") }
New-Item -ItemType Directory -Force (Join-Path $dest "worlds") | Out-Null
Remove-Item $stageRoot -Recurse -Force
Say "Done: $dest"
