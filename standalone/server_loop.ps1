# GeoRocker class server loop.
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
# Every round:
#   1. back up the world folder to backups\auto_<world>\<date-time> (delete backups older than KeepDays);
#      skipped when the newest backup is less than MinHours old
#   2. update the game code: fast-forward games\georocker to origin/<Branch>
#      (only when the working copy is on <Branch> and has no local changes)
#   3. run the dedicated server until it exits (daily restart at rockmech_daily_restart, a crash, or /shutdown)
#   4. start again after 5 s
# If the server exits within 60 s three times in a row (a crash on load, broken update, port in use...),
# wait 5, 10, 20, 40, then 60 min between tries instead of 5 s. It never gives up: every try updates the
# code first, so a fix pushed to <Branch> brings the server back without anyone at this PC.
# Ctrl+C in this window stops the server (it saves first) and the loop.
# The game folder is games\georocker (gameid georocker); older installs use games\mining_sim.

param(
	[string]$World = "class_coal",
	[string]$Branch = "release",     # the class server follows release; develop on main and merge when ready
	[int]$KeepDays = 7,
	[int]$MinHours = 6,             # skip the backup when the newest one is younger than this (many restarts while developing)
	[int]$Port = 30000
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # git log messages are UTF-8 (Chinese)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root "bin\luanti.exe"
$worldDir = Join-Path $root "worlds\$World"
$backupDir = Join-Path $root "backups\auto_$World"
$gameId = "georocker"
if (-not (Test-Path (Join-Path $root "games\georocker")) -and (Test-Path (Join-Path $root "games\mining_sim"))) { $gameId = "mining_sim" }
$repo = Join-Path $root "games\$gameId"
$host.UI.RawUI.WindowTitle = "GeoRocker class server ($World, port $Port)"

function Say($msg) { Write-Host ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $msg) -ForegroundColor Cyan }

if (-not (Test-Path $worldDir)) { Say "World not found: $worldDir"; Read-Host "Press Enter to exit"; exit 1 }

# Guard: only one server per world / port. A second copy of this window would fight the first one
# over the port and the world database (port in use, "database is locked").
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
	Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'server_loop\.ps1' })
$running = @(Get-CimInstance Win32_Process -Filter "Name='luanti.exe'" -ErrorAction SilentlyContinue |
	Where-Object { $_.CommandLine -match '--server' -and ($_.CommandLine -match [regex]::Escape($worldDir) -or $_.CommandLine -match "--port\s+$Port\b") })
$portUsed = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
if ($others.Count -gt 0 -or $running.Count -gt 0 -or $portUsed.Count -gt 0) {
	Say "The class server is already running (another server window, or a server on port $Port)."
	Say "Do not start it twice. Use the window that is already open."
	Read-Host "Press Enter to close this window"
	exit 1
}

$fails = 0
while ($true) {
	# 1. backup (at most one every MinHours)
	New-Item -ItemType Directory -Force $backupDir | Out-Null
	$newest = Get-ChildItem $backupDir -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
	if ($newest -and $newest.CreationTime -gt (Get-Date).AddHours(-$MinHours)) {
		Say ("Skip backup: newest backup " + $newest.Name + " is less than $MinHours h old")
	} else {
		$dest = Join-Path $backupDir (Get-Date -Format "yyyyMMdd-HHmmss")
		Say "Backing up world to $dest"
		robocopy $worldDir $dest /E /NFL /NDL /NJH /NJS /NP | Out-Null
	}
	Get-ChildItem $backupDir -Directory |
		Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$KeepDays) } |
		ForEach-Object { Say ("Deleting old backup " + $_.Name); Remove-Item $_.FullName -Recurse -Force }

	# 2. update code
	if (Get-Command git -ErrorAction SilentlyContinue) {
		Push-Location $repo
		$cur = (git rev-parse --abbrev-ref HEAD)
		$dirty = (git status --porcelain)
		$remote = (git remote)
		if ($cur -ne $Branch) { Say "Skip update: code is on branch '$cur', not '$Branch'" }
		elseif (-not $remote) { Say "Skip update: no git remote" }
		elseif ($dirty) { Say "Skip update: there are local changes in games\$gameId" }
		else {
			git fetch origin $Branch 2>&1 | ForEach-Object { Write-Host $_ }
			git merge --ff-only "origin/$Branch" 2>&1 | ForEach-Object { Write-Host $_ }
		}
		Say ("Code version: " + (git log -1 --format="%h %s"))
		Pop-Location
	} else {
		Say "Skip update: git not found"
	}

	# 3. run
	Say "Starting server (world $World, port $Port)"
	$t0 = Get-Date
	# Start-Process -Wait: luanti.exe is a GUI-subsystem program, so "& luanti.exe" would not wait for it to exit
	Start-Process -FilePath $exe -ArgumentList @("--server", "--world", "`"$worldDir`"", "--gameid", $gameId, "--port", "$Port") -NoNewWindow -Wait
	$secs = [int]((Get-Date) - $t0).TotalSeconds

	# 4. crash guard: quick exits in a row -> wait longer each time, but keep trying (code is updated before every try)
	if ($secs -lt 60) { $fails++ } else { $fails = 0 }
	if ($fails -ge 3) {
		$mins = [int][math]::Min(60, 5 * [math]::Pow(2, $fails - 3))
		Say "The server stopped within 60 s $fails times in a row (check debug.txt). Trying again in $mins min, after updating the code."
		Start-Sleep -Seconds ($mins * 60)
		continue
	}
	Say "Server exited after $secs s. Restarting in 5 s (close this window to stop)."
	Start-Sleep -Seconds 5
}
