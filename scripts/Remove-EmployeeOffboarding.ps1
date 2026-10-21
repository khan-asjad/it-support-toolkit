<#
.SYNOPSIS
    Offboards a departing employee securely.

.DESCRIPTION
    Follows a standard offboarding checklist:
      1. Disables the account (never deletes it right away - keeps it for audit/recovery)
      2. Resets the password to a random value so old credentials stop working
      3. Records and removes all group memberships (saved to a CSV for reference)
      4. Moves the account to the Disabled Users OU
      5. Stamps the description with the date and the ticket number
      6. Logs every step

    Supports -WhatIf so you can preview the changes.

.PARAMETER Username
    SamAccountName of the departing employee.

.PARAMETER TicketNumber
    Help desk ticket that authorized the offboarding (kept for the audit trail).

.EXAMPLE
    .\Remove-EmployeeOffboarding.ps1 -Username jdoe -TicketNumber INC-1042 -WhatIf

.NOTES
    Requires the ActiveDirectory module (RSAT).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$TicketNumber
)

Import-Module ActiveDirectory -ErrorAction Stop

# ---------- Configuration ----------
$DisabledOU   = "OU=Disabled Users,$((Get-ADDomain).DistinguishedName)"   # detected automatically
$LogFile      = Join-Path $PSScriptRoot '..\logs\offboarding.log'
$ArchiveDir   = Join-Path $PSScriptRoot '..\logs\group-archive'
$KeepGroups   = @('Domain Users')   # primary group cannot be removed
# -----------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $TicketNumber, $Message
    $dir = Split-Path $LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
    Add-Content -Path $LogFile -Value $line -WhatIf:$false
    Write-Host $line
}

$user = Get-ADUser -Identity $Username -Properties MemberOf, Description -ErrorAction SilentlyContinue
if (-not $user) {
    Write-Log "User '$Username' not found. Nothing changed." 'ERROR'
    exit 1
}

# 1. Disable
if ($PSCmdlet.ShouldProcess($Username, 'Disable account')) {
    Disable-ADAccount -Identity $user
    Write-Log "Disabled $Username"
}

# 2. Scramble password
if ($PSCmdlet.ShouldProcess($Username, 'Reset password to random value')) {
    $random = -join ((33..126) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString $random -AsPlainText -Force)
    Write-Log "Password scrambled for $Username"
}

# 3. Archive and remove group memberships
$groups = $user.MemberOf | ForEach-Object { Get-ADGroup $_ } | Where-Object { $KeepGroups -notcontains $_.Name }
if ($groups) {
    if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force -WhatIf:$false | Out-Null }
    $archive = Join-Path $ArchiveDir ("{0}_{1}.csv" -f $Username, (Get-Date -Format 'yyyyMMdd'))
    $groups | Select-Object Name, DistinguishedName | Export-Csv $archive -NoTypeInformation -WhatIf:$false
    Write-Log "Saved $(@($groups).Count) group membership(s) to $archive"

    foreach ($g in $groups) {
        if ($PSCmdlet.ShouldProcess($g.Name, "Remove $Username")) {
            Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
            Write-Log "Removed $Username from $($g.Name)"
        }
    }
}

# 4. Stamp description
$stamp = "Disabled $(Get-Date -Format 'yyyy-MM-dd') per $TicketNumber"
if ($PSCmdlet.ShouldProcess($Username, "Set description '$stamp'")) {
    Set-ADUser -Identity $user -Description $stamp
}

# 5. Move to Disabled Users OU
if ($PSCmdlet.ShouldProcess($Username, "Move to $DisabledOU")) {
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU
    Write-Log "Moved $Username to $DisabledOU"
}

Write-Log "Offboarding complete for $Username"
