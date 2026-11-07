# Build the standalone package of this game (single player, hosting a class, joining a server).
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File games\mining_sim\standalone\make_package.ps1
#
# Output: <Out>\<Name>.zip (clean package to hand out) and <Out>\<Name>\ (a copy to play on this PC).
#   The package is built in a temp folder first. Updating <Out>\<Name>\ keeps the player's data:
#   worlds\ (saves), minetest.conf (settings, remembered password), and games\mining_sim when it is a git clone
#   (then "git pull" there updates the game).
#   - builtin\mainmenu\init.lua is replaced by standalone\mainmenu.lua (our own start screen, no Luanti menu)
#   - minetest.conf: single player defaults
#   - a "start game" .bat that starts bin\luanti.exe
#   - no worlds: the start screen lists the maps in standalone\maps and creates one world per map

param(
	[string]$Out = "D:\Teaching",
	[string]$Name = "MiningMechanics"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path        # games\mining_sim\standalone
$game = Split-Path -Parent $here                                 # games\mining_sim
$root = Split-Path -Parent (Split-Path -Parent $game)            # Luanti root
$dest = Join-Path $Out $Name
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
Copy-Tree $game (Join-Path $stage "games\mining_sim") @(".git", "docs")
New-Item -ItemType Directory -Force (Join-Path $stage "worlds") | Out-Null

Say "Replacing the main menu"
$mm = Join-Path $stage "builtin\mainmenu"
Copy-Item (Join-Path $mm "init.lua") (Join-Path $mm "init_luanti.lua")
# A small stub that loads the start screen from the game folder, so "git pull" in games\mining_sim updates it too
$stub = @(
	"-- Start screen of this package: loaded from the game folder (games/mining_sim/standalone/mainmenu.lua),",
	"-- so updating the game (git pull) also updates the start screen. Falls back to the Luanti menu if missing.",
	"local p = core.get_builtin_path() .. '..' .. DIR_DELIM .. 'games' .. DIR_DELIM .. 'mining_sim' .. DIR_DELIM .. 'standalone' .. DIR_DELIM .. 'mainmenu.lua'",
	"local f = io.open(p, 'r')",
	"if f then f:close(); dofile(p) else dofile(core.get_builtin_path() .. 'mainmenu' .. DIR_DELIM .. 'init_luanti.lua') end"
)
[System.IO.File]::WriteAllLines((Join-Path $mm "init.lua"), $stub)

Say "Writing minetest.conf"
$conf = @(
	"menu_last_game = mining_sim",
	"creative_mode = false",
	"enable_damage = true",
	"enable_server = false",
	"server_announce = false",
	"sound_volume = 0.8",
	"name = player",
	"enable_esc_dialog = false"
)
[System.IO.File]::WriteAllLines((Join-Path $stage "minetest.conf"), $conf)

# Start file name in Chinese ("start game"), built from char codes to keep this script ASCII
$startName = [string]::new([char[]](0x958B, 0x59CB, 0x904A, 0x6232)) + ".bat"
$bat = "@echo off`r`nstart `"`" `"%~dp0bin\luanti.exe`"`r`n"
[System.IO.File]::WriteAllText((Join-Path $stage $startName), $bat, (New-Object System.Text.ASCIIEncoding))

$notice = @(
	"This package contains the Luanti engine 5.15.1 (https://www.luanti.org),",
	"licensed under the GNU LGPL 2.1 or later. Source code: https://github.com/luanti-org/luanti",
	"Mods taken from Minetest Game keep their own license files inside games\mining_sim\mods\<mod>.",
	"The start screen (builtin\mainmenu\init.lua) is replaced; the original is builtin\mainmenu\init_luanti.lua."
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
		[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
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
if (Test-Path (Join-Path $dest "games\mining_sim\.git")) {
	Say "games\mining_sim is a git clone: left as it is (use git pull there)"
	$ra += "mining_sim"
}
robocopy @ra | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $dest" }
if (-not (Test-Path (Join-Path $dest "minetest.conf"))) { Copy-Item (Join-Path $stage "minetest.conf") (Join-Path $dest "minetest.conf") }
New-Item -ItemType Directory -Force (Join-Path $dest "worlds") | Out-Null
Remove-Item $stageRoot -Recurse -Force
Say "Done: $dest"
