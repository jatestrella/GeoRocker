# Memory / CPU log for the class server PC (diagnosing freezes).
# ASCII only: Windows PowerShell 5 reads .ps1 files as ANSI.
#
# Run it next to the server and leave its window open:
#   powershell -NoProfile -ExecutionPolicy Bypass -File games\<game folder>\standalone\mem_log.ps1
#
# Every 60 s it appends one line to <Luanti root>\mem_log.csv:
#   time, luanti.exe memory (MB, working set and private), system free memory (MB), memory in use (%),
#   CPU load (%), free disk space on the Luanti drive (GB)
# After a freeze, open mem_log.csv: if luanti_private_mb keeps rising and free_mb falls toward 0 before
# the last line, the game ran the PC out of memory. If the numbers stay flat, look for another cause.

param([int]$Seconds = 60)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))     # Luanti root
$csv = Join-Path $root "mem_log.csv"
if (-not (Test-Path $csv)) {
	"time,luanti_ws_mb,luanti_private_mb,free_mb,mem_used_pct,cpu_pct,disk_free_gb" | Out-File -FilePath $csv -Encoding ascii
}
$drive = (Get-Item $root).PSDrive.Name
Write-Host ("Logging every $Seconds s to " + $csv + "  (close this window to stop)")

while ($true) {
	$os = Get-CimInstance Win32_OperatingSystem
	$total = [double]$os.TotalVisibleMemorySize / 1024
	$free = [double]$os.FreePhysicalMemory / 1024
	$used = if ($total -gt 0) { 100 * ($total - $free) / $total } else { 0 }
	$ws = 0; $priv = 0
	foreach ($p in @(Get-Process -Name luanti -ErrorAction SilentlyContinue)) {
		$ws += $p.WorkingSet64 / 1MB
		$priv += $p.PrivateMemorySize64 / 1MB
	}
	$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
	$disk = (Get-PSDrive -Name $drive).Free / 1GB
	$line = "{0},{1:F0},{2:F0},{3:F0},{4:F1},{5:F0},{6:F1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $ws, $priv, $free, $used, $cpu, $disk
	$line | Out-File -FilePath $csv -Append -Encoding ascii
	Start-Sleep -Seconds $Seconds
}
