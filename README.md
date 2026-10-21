# IT Support Automation Toolkit (PowerShell)

PowerShell scripts that automate the most repetitive help desk and desktop support tasks: onboarding new hires, offboarding departing employees, bulk password resets, and workstation health checks.

Designed for an Active Directory home lab (`meridian.local`, Windows Server 2022 domain controller + domain-joined clients).
<!-- After you run these in your lab, change the line above to "Built and tested in my AD home lab" and add screenshots below. -->


## Why I built this

In my current role I manage devices for close to 100 employees and train staff on them. The same tasks come up again and again, and doing them by hand is slow and easy to get wrong. These scripts turn a 15-minute manual checklist into a single command, with logging so every change is auditable.

## What's included

| Script | What it does | Est. time saved |
|---|---|---|
| `New-EmployeeOnboarding.ps1` | Creates the AD account with a naming convention, puts it in the right OU, adds department groups, creates a home folder with correct permissions. Single user or bulk from CSV. | ~15 min → 10 sec per hire |
| `Remove-EmployeeOffboarding.ps1` | Disables the account, scrambles the password, archives and removes group memberships, moves it to Disabled Users, stamps the ticket number. | ~10 min → 5 sec |
| `Reset-BulkPasswords.ps1` | Resets passwords for a list of users, unlocks locked accounts, forces change at next logon, saves results. | Mass lockout handled in seconds |
| `Get-SystemHealthReport.ps1` | Checks uptime, CPU, memory, disk space, stopped services, recent system errors and pending reboots. Produces a color-coded HTML report for one or many PCs. | First-pass "my PC is slow" triage |

## Safe by design

- **`-WhatIf` support** on every script that changes AD, so you can preview changes before they happen.
- **Disable, never delete** on offboarding. Accounts stay recoverable and group memberships are archived to CSV.
- **Audit logging** of every action to `logs/`, tagged with the ticket number for offboarding.
- **Temporary passwords are never written to the log.** They are shown once (onboarding) or saved to a results file marked sensitive (bulk reset).
- **Unique usernames.** If `jdoe` exists, the next hire becomes `jdoe2`.

## Usage

Requirements: Windows PowerShell 5.1 or PowerShell 7, and the ActiveDirectory module (RSAT) for the AD scripts.

```powershell
# Preview onboarding without changing anything
.\scripts\New-EmployeeOnboarding.ps1 -FirstName Jane -LastName Doe -Department IT -Title "Help Desk Technician" -WhatIf

# Bulk onboard from a CSV
.\scripts\New-EmployeeOnboarding.ps1 -CsvPath .\samples\new-hires.csv

# Offboard with a ticket reference
.\scripts\Remove-EmployeeOffboarding.ps1 -Username jdoe -TicketNumber INC-1042

# Reset passwords for a list of users
.\scripts\Reset-BulkPasswords.ps1 -CsvPath .\samples\password-resets.csv

# Health report for this PC, or several
.\scripts\Get-SystemHealthReport.ps1
.\scripts\Get-SystemHealthReport.ps1 -ComputerName WS01, WS02
```

The scripts detect the domain automatically. They expect an `Employees` OU with department sub-OUs, a `Disabled Users` OU, the `GG-*` security groups, and a hidden `Home$` share on the domain controller. Edit the department-to-group map at the top of the onboarding script to match your organization.

## Screenshots

<!-- Add after running in your lab -->
- `screenshots/onboarding-whatif.png`: WhatIf preview of an onboarding run
- `screenshots/onboarding-result.png`: new user in Active Directory Users and Computers
- `screenshots/health-report.png`: the HTML health report

## Skills demonstrated

Active Directory administration · PowerShell scripting · user lifecycle management · NTFS permissions · security best practices (least privilege, audit trails) · Windows troubleshooting · documentation

## Author

Asjad Khan, M.S. Computer Science · M.S. Cybersecurity candidate, Eastern Michigan University
