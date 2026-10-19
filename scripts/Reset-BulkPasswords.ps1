<#
.SYNOPSIS
    Resets passwords for a list of users and unlocks their accounts.

.DESCRIPTION
    Reads usernames from a CSV (column: Username), generates a unique temporary
    password for each, unlocks the account if locked, and forces a password
    change at next logon. Results are written to a CSV for the technician to
    hand out securely. A common help desk task after a security incident or
    a mass lockout.

.PARAMETER CsvPath
    CSV with a 'Username' column.

.PARAMETER OutputPath
    Where to save the results CSV. Defaults to the logs folder.

.EXAMPLE
    .\Reset-BulkPasswords.ps1 -CsvPath ..\samples\password-resets.csv -WhatIf

.NOTES
    Treat the output file as sensitive. Delete it once passwords are delivered.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot ("..\logs\password-resets_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm')))
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }

function New-TempPassword {
    $set = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%?'
    do {
        $pw = -join (1..14 | ForEach-Object { $set[(Get-Random -Maximum $set.Length)] })
    } until ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '\d' -and $pw -match '[!@#$%?]')
    $pw
}

$results = foreach ($row in Import-Csv $CsvPath) {
    $name = $row.Username.Trim()
    $user = Get-ADUser -Filter "SamAccountName -eq '$name'" -Properties LockedOut -ErrorAction SilentlyContinue

    if (-not $user) {
        [PSCustomObject]@{ Username = $name; Status = 'NOT FOUND'; WasLocked = ''; TempPassword = '' }
        continue
    }

    $pw = New-TempPassword
    if ($PSCmdlet.ShouldProcess($name, 'Reset password, unlock, require change at logon')) {
        try {
            Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString $pw -AsPlainText -Force) -ErrorAction Stop
            if ($user.LockedOut) { Unlock-ADAccount -Identity $user }
            Set-ADUser -Identity $user -ChangePasswordAtLogon $true
            [PSCustomObject]@{ Username = $name; Status = 'RESET'; WasLocked = $user.LockedOut; TempPassword = $pw }
        }
        catch {
            [PSCustomObject]@{ Username = $name; Status = "ERROR: $($_.Exception.Message)"; WasLocked = $user.LockedOut; TempPassword = '' }
        }
    }
    else {
        [PSCustomObject]@{ Username = $name; Status = 'WHATIF'; WasLocked = $user.LockedOut; TempPassword = '' }
    }
}

$dir = Split-Path $OutputPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$results | Export-Csv $OutputPath -NoTypeInformation
$results | Select-Object Username, Status, WasLocked | Format-Table -AutoSize
Write-Host "`nResults saved to $OutputPath (contains passwords - handle securely)." -ForegroundColor Yellow
