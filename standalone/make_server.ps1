# Build a server-only GeoRocker folder (for the class server PC).
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
# Contents (about 45 MB):
#   bin\, builtin\, minetest.conf          the Luanti engine (no client cache, fonts, textures, logs, backups)
#   games\mining_sim\                      shallow git clone of the release branch (server_loop.ps1 pulls it daily)
#   worlds\<World>\                        the class world, copied from this PC
#   server_loop.ps1, start_class_server.bat, README.txt
#
# Usage (from this folder):  powershell -ExecutionPolicy Bypass -File make_server.ps1 [-Out D:\path] [-World class_coal]
# Refuses to write into an existing folder (it may hold a live world).

param(
	[string]$Out = "",
	[string]$World = "class_coal",
	[string]$Branch = "release"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$game = Split-Path -Parent $here                       # games\mining_sim
$luanti = Split-Path -Parent (Split-Path -Parent $game) # luanti root
if ($Out -eq "") { $Out = Join-Path (Split-Path -Parent $luanti) "GeoRocker_server" }

function Say($m) { Write-Host "[server] $m" -ForegroundColor Cyan }

if (Test-Path $Out) { Say "Folder already exists: $Out (delete or rename it first)"; exit 1 }
$worldSrc = Join-Path $luanti "worlds\$World"
if (-not (Test-Path $worldSrc)) { Say "World not found: $worldSrc"; exit 1 }

New-Item -ItemType Directory -Force $Out | Out-Null

Say "Copying engine (bin, builtin, minetest.conf)"
robocopy (Join-Path $luanti "bin") (Join-Path $Out "bin") /E /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy (Join-Path $luanti "builtin") (Join-Path $Out "builtin") /E /NFL /NDL /NJH /NJS /NP | Out-Null
Copy-Item (Join-Path $luanti "minetest.conf") $Out
Remove-Item (Join-Path $Out "bin\debug.txt*") -ErrorAction SilentlyContinue

Say "Copying server scripts"
Copy-Item (Join-Path $luanti "server_loop.ps1") $Out
Copy-Item (Join-Path $luanti "start_class_server.bat") $Out
Copy-Item (Join-Path $here "server_readme.txt") (Join-Path $Out "README.txt")

Say "Cloning the game ($Branch branch, latest version only)"
$url = (git -C $game remote get-url origin)
New-Item -ItemType Directory -Force (Join-Path $Out "games") | Out-Null
git clone --quiet --depth 1 --single-branch -b $Branch $url (Join-Path $Out "games\mining_sim")
if ($LASTEXITCODE -ne 0) { Say "git clone failed"; exit 1 }

Say "Copying world $World"
robocopy $worldSrc (Join-Path $Out "worlds\$World") /E /NFL /NDL /NJH /NJS /NP /XF "*.bak-*" | Out-Null

$mb = [math]::Round(((Get-ChildItem $Out -Recurse -File -Force | Measure-Object Length -Sum).Sum) / 1MB, 1)
Say "Done: $Out ($mb MB)"
