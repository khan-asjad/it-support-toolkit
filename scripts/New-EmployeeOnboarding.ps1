<#
.SYNOPSIS
    Onboards a new employee in Active Directory.

.DESCRIPTION
    Creates an AD user account with a standard naming convention, places it in the
    correct department OU, adds department security groups, creates a home folder
    with the right permissions, and writes a log entry for the audit trail.

    Supports -WhatIf so you can preview every change before it happens.

.PARAMETER FirstName
    Employee's first name.

.PARAMETER LastName
    Employee's last name.

.PARAMETER Department
    Department name. Must match a key in the $DepartmentMap below.

.PARAMETER Title
    Job title shown in the directory.

.PARAMETER Manager
    SamAccountName of the employee's manager (optional).

.PARAMETER CsvPath
    Path to a CSV of new hires (columns: FirstName,LastName,Department,Title,Manager).
    Use this instead of the single-user parameters for bulk onboarding.

.EXAMPLE
    .\New-EmployeeOnboarding.ps1 -FirstName Jane -LastName Doe -Department IT -Title "Help Desk Technician" -WhatIf

.EXAMPLE
    .\New-EmployeeOnboarding.ps1 -CsvPath ..\samples\new-hires.csv

.NOTES
    Requires the ActiveDirectory module (RSAT) and rights to create users.
    Built for a home lab domain: lab.local
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$FirstName,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$LastName,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Department,
    [Parameter(ParameterSetName = 'Single')][string]$Title = '',
    [Parameter(ParameterSetName = 'Single')][string]$Manager = '',
    [Parameter(Mandatory, ParameterSetName = 'Bulk')][string]$CsvPath
)

# ---------- Configuration (edit for your environment) ----------
$Domain        = 'lab.local'
$BaseOU        = 'OU=Employees,DC=lab,DC=local'
$HomeShareRoot = '\\FS01\Home$'
$LogFile       = Join-Path $PSScriptRoot '..\logs\onboarding.log'

# Department -> security groups every new hire in that department receives
$DepartmentMap = @{
    'IT'         = @('GG-IT-Staff', 'GG-VPN-Users', 'GG-All-Staff')
    'HR'         = @('GG-HR-Staff', 'GG-All-Staff')
    'Finance'    = @('GG-Finance-Staff', 'GG-All-Staff')
    'Operations' = @('GG-Ops-Staff', 'GG-All-Staff')
}
# ---------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $dir = Split-Path $LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function New-TempPassword {
    # 16 characters, guaranteed upper, lower, digit and symbol
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnpqrstuvwxyz'
    $digits = '23456789'
    $symbol = '!@#$%^&*?'
    $all    = $upper + $lower + $digits + $symbol
    $chars  = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Get-UniqueSamAccountName {
    param([string]$First, [string]$Last)
    # Convention: first initial + last name, lowercase, max 20 chars (jdoe, jdoe2, jdoe3...)
    $base = ($First.Substring(0, 1) + $Last) -replace '[^a-zA-Z]', ''
    $base = $base.ToLower()
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }
    $candidate = $base
    $n = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $candidate = "$base$n"
        $n++
    }
    $candidate
}

function Invoke-Onboarding {
    param($Hire)

    if (-not $DepartmentMap.ContainsKey($Hire.Department)) {
        Write-Log "Unknown department '$($Hire.Department)' for $($Hire.FirstName) $($Hire.LastName). Skipped." 'ERROR'
        return
    }

    $sam      = Get-UniqueSamAccountName -First $Hire.FirstName -Last $Hire.LastName
    $upn      = "$sam@$Domain"
    $ou       = "OU=$($Hire.Department),$BaseOU"
    $display  = "$($Hire.FirstName) $($Hire.LastName)"
    $password = New-TempPassword
    $homePath = Join-Path $HomeShareRoot $sam

    $userParams = @{
        Name                  = $display
        GivenName             = $Hire.FirstName
        Surname               = $Hire.LastName
        DisplayName           = $display
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        Path                  = $ou
        Department            = $Hire.Department
        Title                 = $Hire.Title
        AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
        HomeDrive             = 'H:'
        HomeDirectory         = $homePath
    }
    if ($Hire.Manager) {
        $mgr = Get-ADUser -Filter "SamAccountName -eq '$($Hire.Manager)'" -ErrorAction SilentlyContinue
        if ($mgr) { $userParams.Manager = $mgr.DistinguishedName }
        else { Write-Log "Manager '$($Hire.Manager)' not found; continuing without manager." 'WARN' }
    }

    if ($PSCmdlet.ShouldProcess($upn, 'Create AD user')) {
        try {
            New-ADUser @userParams -ErrorAction Stop
            Write-Log "Created user $upn in $ou"
        }
        catch {
            Write-Log "Failed to create $upn : $($_.Exception.Message)" 'ERROR'
            return
        }
    }

    foreach ($group in $DepartmentMap[$Hire.Department]) {
        if ($PSCmdlet.ShouldProcess($group, "Add $sam")) {
            try {
                Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
                Write-Log "Added $sam to $group"
            }
            catch { Write-Log "Could not add $sam to $group : $($_.Exception.Message)" 'WARN' }
        }
    }

    if ($PSCmdlet.ShouldProcess($homePath, 'Create home folder and grant Modify')) {
        try {
            New-Item -ItemType Directory -Path $homePath -Force -ErrorAction Stop | Out-Null
            $acl  = Get-Acl $homePath
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$($Domain.Split('.')[0])\$sam", 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -Path $homePath -AclObject $acl
            Write-Log "Created home folder $homePath"
        }
        catch { Write-Log "Home folder issue for $sam : $($_.Exception.Message)" 'WARN' }
    }

    # Return a summary object (temp password is shown once and never logged)
    [PSCustomObject]@{
        Name         = $display
        Username     = $sam
        Email        = $upn
        Department   = $Hire.Department
        TempPassword = $password
    }
}

# ---------- Main ----------
$hires = if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
    Import-Csv $CsvPath
}
else {
    [PSCustomObject]@{ FirstName = $FirstName; LastName = $LastName; Department = $Department; Title = $Title; Manager = $Manager }
}

$results = foreach ($hire in $hires) { Invoke-Onboarding -Hire $hire }
$results | Format-Table -AutoSize
Write-Log "Onboarding run finished. $(@($results).Count) account(s) processed."
