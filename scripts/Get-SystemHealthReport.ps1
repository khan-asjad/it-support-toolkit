<#
.SYNOPSIS
    Generates an HTML health report for one or more Windows computers.

.DESCRIPTION
    Collects the information a technician checks first when a user says
    "my computer is slow": OS and uptime, CPU and memory load, disk space,
    stopped automatic services, recent critical/error events, and pending
    reboot status. Flags problems in red/amber and saves a readable HTML report.

    Works on the local machine with no extra modules. For remote computers,
    WinRM must be enabled (Enable-PSRemoting).

.PARAMETER ComputerName
    One or more computer names. Defaults to the local computer.

.PARAMETER OutputPath
    Folder for the HTML report. Defaults to the reports folder.

.EXAMPLE
    .\Get-SystemHealthReport.ps1

.EXAMPLE
    .\Get-SystemHealthReport.ps1 -ComputerName WS01, WS02, WS03
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\reports')
)

# Thresholds - tweak to taste
$DiskWarnPct = 20   # amber below this % free
$DiskCritPct = 10   # red below this % free
$MemWarnPct  = 85   # amber above this % used
$UptimeWarnDays = 14

$collect = {
    param($DiskWarnPct, $DiskCritPct)

    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $cpu  = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $memUsedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)

    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $freePct = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        [PSCustomObject]@{
            Drive   = $_.DeviceID
            SizeGB  = [math]::Round($_.Size / 1GB, 1)
            FreeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
            FreePct = $freePct
        }
    }

    $stopped = Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
        Where-Object { $_.Name -notmatch 'gupdate|sppsvc|RemoteRegistry|edgeupdate|MapsBroker' } |
        Select-Object Name, DisplayName

    $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 10 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, @{ n = 'Message'; e = { ($_.Message -split "`n")[0] } }

    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    [PSCustomObject]@{
        Computer      = $env:COMPUTERNAME
        OS            = $os.Caption
        Build         = $os.BuildNumber
        Manufacturer  = $cs.Manufacturer
        Model         = $cs.Model
        UptimeDays    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        CpuPct        = $cpu
        MemUsedPct    = $memUsedPct
        TotalMemGB    = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Disks         = $disks
        StoppedAuto   = $stopped
        RecentErrors  = $events
        PendingReboot = $pendingReboot
    }
}

function ConvertTo-Badge([string]$Text, [string]$Level) {
    "<span class='badge $Level'>$([System.Net.WebUtility]::HtmlEncode($Text))</span>"
}

$sections = foreach ($computer in $ComputerName) {
    Write-Host "Checking $computer..."
    try {
        $data = if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost') {
            & $collect $DiskWarnPct $DiskCritPct
        }
        else {
            Invoke-Command -ComputerName $computer -ScriptBlock $collect -ArgumentList $DiskWarnPct, $DiskCritPct -ErrorAction Stop
        }
    }
    catch {
        "<section><h2>$computer</h2><p>$(ConvertTo-Badge 'UNREACHABLE' 'crit') $([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</p></section>"
        continue
    }

    $issues = 0
    $memBadge = if ($data.MemUsedPct -ge $MemWarnPct) { $issues++; ConvertTo-Badge "$($data.MemUsedPct)%" 'warn' } else { ConvertTo-Badge "$($data.MemUsedPct)%" 'ok' }
    $upBadge  = if ($data.UptimeDays -ge $UptimeWarnDays) { $issues++; ConvertTo-Badge "$($data.UptimeDays) days" 'warn' } else { ConvertTo-Badge "$($data.UptimeDays) days" 'ok' }
    $rbBadge  = if ($data.PendingReboot) { $issues++; ConvertTo-Badge 'Yes' 'warn' } else { ConvertTo-Badge 'No' 'ok' }

    $diskRows = ($data.Disks | ForEach-Object {
        $lvl = if ($_.FreePct -lt $DiskCritPct) { $issues++; 'crit' } elseif ($_.FreePct -lt $DiskWarnPct) { $issues++; 'warn' } else { 'ok' }
        "<tr><td>$($_.Drive)</td><td>$($_.SizeGB) GB</td><td>$($_.FreeGB) GB</td><td>$(ConvertTo-Badge "$($_.FreePct)%" $lvl)</td></tr>"
    }) -join ''

    $svcRows = if ($data.StoppedAuto) {
        $issues++
        ($data.StoppedAuto | ForEach-Object { "<tr><td>$($_.Name)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.DisplayName))</td></tr>" }) -join ''
    } else { "<tr><td colspan='2'>All automatic services are running.</td></tr>" }

    $evtRows = if ($data.RecentErrors) {
        ($data.RecentErrors | ForEach-Object { "<tr><td>$($_.TimeCreated)</td><td>$($_.Id)</td><td>$($_.ProviderName)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Message))</td></tr>" }) -join ''
    } else { "<tr><td colspan='4'>No critical or error events in the last 24 hours.</td></tr>" }

    $summary = if ($issues -eq 0) { ConvertTo-Badge 'Healthy' 'ok' } else { ConvertTo-Badge "$issues item(s) need attention" 'warn' }

@"
<section>
  <h2>$($data.Computer) $summary</h2>
  <table class='kv'>
    <tr><th>OS</th><td>$($data.OS) (build $($data.Build))</td></tr>
    <tr><th>Hardware</th><td>$($data.Manufacturer) $($data.Model), $($data.TotalMemGB) GB RAM</td></tr>
    <tr><th>Uptime</th><td>$upBadge</td></tr>
    <tr><th>CPU load</th><td>$($data.CpuPct)%</td></tr>
    <tr><th>Memory used</th><td>$memBadge</td></tr>
    <tr><th>Pending reboot</th><td>$rbBadge</td></tr>
  </table>
  <h3>Disks</h3>
  <table><tr><th>Drive</th><th>Size</th><th>Free</th><th>Free %</th></tr>$diskRows</table>
  <h3>Automatic services not running</h3>
  <table><tr><th>Name</th><th>Display name</th></tr>$svcRows</table>
  <h3>System errors (last 24 hours)</h3>
  <table><tr><th>Time</th><th>Event ID</th><th>Source</th><th>Message</th></tr>$evtRows</table>
</section>
"@
}

$html = @"
<!doctype html>
<html lang='en'><head><meta charset='utf-8'><title>System Health Report</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1f2937;background:#f8fafc}
 h1{margin-bottom:4px} .sub{color:#64748b;margin-top:0}
 section{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:20px;margin:20px 0}
 table{border-collapse:collapse;width:100%;margin-bottom:12px} th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #e2e8f0;font-size:14px}
 th{background:#f1f5f9} table.kv th{width:180px}
 .badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600}
 .ok{background:#dcfce7;color:#166534} .warn{background:#fef3c7;color:#92400e} .crit{background:#fee2e2;color:#991b1b}
</style></head><body>
<h1>System Health Report</h1>
<p class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $env:USERNAME</p>
$($sections -join "`n")
</body></html>
"@

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$file = Join-Path $OutputPath ("HealthReport_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
$html | Out-File -FilePath $file -Encoding utf8
Write-Host "Report saved to $file" -ForegroundColor Green
if ($ComputerName.Count -eq 1 -and $IsWindows -ne $false) { Start-Process $file }
