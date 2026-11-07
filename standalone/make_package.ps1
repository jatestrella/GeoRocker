# Build the standalone (single player) package of this game.
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File games\mining_sim\standalone\make_package.ps1
#
# Output: <Out>\<Name>\ (a run-in-place copy of Luanti with only this game) and <Out>\<Name>.zip
#   - builtin\mainmenu\init.lua is replaced by standalone\mainmenu.lua (our own start screen, no Luanti menu)
#   - minetest.conf: single player defaults
#   - a "start game" .bat that starts bin\luanti.exe
#   - no worlds: "New game" in the start screen creates one (settings from standalone\rockmech.conf)

param(
	[string]$Out = "D:\Teaching\dist",
	[string]$Name = "MiningMechanics"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path        # games\mining_sim\standalone
$game = Split-Path -Parent $here                                 # games\mining_sim
$root = Split-Path -Parent (Split-Path -Parent $game)            # Luanti root
$dest = Join-Path $Out $Name

function Say($m) { Write-Host ("[package] " + $m) -ForegroundColor Cyan }
function Copy-Tree($src, $dst, $exclude) {
	$ra = @($src, $dst, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
	if ($exclude) { $ra += "/XD"; $ra += $exclude }
	robocopy @ra | Out-Null
	if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $src" }
}

if (Test-Path $dest) { Say "Removing old $dest"; Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null

Say "Copying engine"
foreach ($d in @("bin", "builtin", "client", "fonts", "textures", "locale")) {
	Copy-Tree (Join-Path $root $d) (Join-Path $dest $d) $null
}
New-Item -ItemType Directory -Force (Join-Path $dest "doc") | Out-Null
Copy-Item (Join-Path $root "doc\README.md") (Join-Path $dest "doc\README.md")

Say "Copying game"
Copy-Tree $game (Join-Path $dest "games\mining_sim") @(".git", "docs")
New-Item -ItemType Directory -Force (Join-Path $dest "worlds") | Out-Null

Say "Replacing the main menu"
$mm = Join-Path $dest "builtin\mainmenu"
Copy-Item (Join-Path $mm "init.lua") (Join-Path $mm "init_luanti.lua")
Copy-Item (Join-Path $here "mainmenu.lua") (Join-Path $mm "init.lua") -Force

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
[System.IO.File]::WriteAllLines((Join-Path $dest "minetest.conf"), $conf)

# Start file name in Chinese ("start game"), built from char codes to keep this script ASCII
$startName = [string]::new([char[]](0x958B, 0x59CB, 0x904A, 0x6232)) + ".bat"
$bat = "@echo off`r`nstart `"`" `"%~dp0bin\luanti.exe`"`r`n"
[System.IO.File]::WriteAllText((Join-Path $dest $startName), $bat, (New-Object System.Text.ASCIIEncoding))

$notice = @(
	"This package contains the Luanti engine 5.15.1 (https://www.luanti.org),",
	"licensed under the GNU LGPL 2.1 or later. Source code: https://github.com/luanti-org/luanti",
	"Mods taken from Minetest Game keep their own license files inside games\mining_sim\mods\<mod>.",
	"The start screen (builtin\mainmenu\init.lua) is replaced; the original is builtin\mainmenu\init_luanti.lua."
)
[System.IO.File]::WriteAllLines((Join-Path $dest "LICENSE-NOTICE.txt"), $notice)

$zip = Join-Path $Out ($Name + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Say "Zipping to $zip"
# Files just written may still be held by the virus scanner: retry a few times
Add-Type -AssemblyName System.IO.Compression.FileSystem
for ($try = 1; $try -le 5; $try++) {
	try {
		if (Test-Path $zip) { Remove-Item $zip -Force }
		[System.IO.Compression.ZipFile]::CreateFromDirectory($dest, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
		break
	} catch {
		if ($try -eq 5) { throw }
		Say "Zip failed ($($_.Exception.Message)), retrying in 3 s"
		Start-Sleep -Seconds 3
	}
}
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Say "Done: $zip ($mb MB)"
