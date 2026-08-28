<#
.SYNOPSIS
    Enumerates software installed in user profiles and optionally uninstalls selected entries.

.DESCRIPTION
    Reads per-user uninstall entries from loaded user registry hives. It can also enumerate
    AppX packages for the current user. Inventory is read-only unless -Uninstall is supplied.
    User registry hives that are not loaded are skipped.

.EXAMPLE
    .\UserSoftwareInventory.ps1 | Format-Table User,DisplayName,Version,Scope

.EXAMPLE
    .\UserSoftwareInventory.ps1 -Name '*Teams*' -Uninstall -WhatIf

.EXAMPLE
    .\UserSoftwareInventory.ps1 -Name 'Example App' -Uninstall

.EXAMPLE
    .\UserSoftwareInventory.ps1 -IncludeAppx | Where-Object PackageType -eq 'AppX'

.EXAMPLE
    .\UserSoftwareInventory.ps1 -InstallPwshIfMissing
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [string] $Name = '*',

    [string] $UserSid,

    [switch] $IncludeAppx,

    [switch] $InstallPwshIfMissing,

    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Pwsh {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        return
    }

    if (-not $InstallPwshIfMissing) {
        Write-Warning 'PowerShell 7 (pwsh) was not detected. Rerun with -InstallPwshIfMissing to install it.'
        return
    }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'PowerShell 7 is not installed and winget.exe is unavailable. Install PowerShell 7 manually or install App Installer first.'
    }

    if ($PSCmdlet.ShouldProcess('PowerShell 7', 'Install with winget')) {
        $install = Start-Process -FilePath 'winget.exe' -ArgumentList @(
            'install',
            '--id', 'Microsoft.PowerShell',
            '--exact',
            '--source', 'winget',
            '--accept-source-agreements',
            '--accept-package-agreements',
            '--silent'
        ) -Wait -PassThru

        if ($install.ExitCode -ne 0) {
            throw "winget failed to install PowerShell 7 with exit code $($install.ExitCode)."
        }

        if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
            Write-Warning 'PowerShell 7 was installed, but pwsh.exe is not yet available in this process. Start a new PowerShell session and rerun the script.'
        }
    }
}

function Get-UserNameForSid {
    param([Parameter(Mandatory)][string] $Sid)

    try {
        return ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate(
            [System.Security.Principal.NTAccount]
        ).Value
    }
    catch {
        return $Sid
    }
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-LoadedUserHive {
    $excludedSids = @(
        'S-1-5-18',
        'S-1-5-19',
        'S-1-5-20',
        'S-1-5-80'
    )

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $currentIdentity.User.Value
    [PSCustomObject]@{
        Sid      = $currentSid
        User     = Get-UserNameForSid -Sid $currentSid
        HivePath = 'Registry::HKEY_CURRENT_USER'
    }

    @(Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue) | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -match '^S-1-5-21(-\d+){3}$' -and $sid -notin $excludedSids -and $sid -ne $currentSid) {
            if ([string]::IsNullOrWhiteSpace($UserSid) -or $sid -eq $UserSid) {
                [PSCustomObject]@{
                    Sid      = $sid
                    User     = Get-UserNameForSid -Sid $sid
                    HivePath = $_.PSPath
                }
            }
        }
    }
}

function Get-RegistrySoftware {
    param([Parameter(Mandatory)] $Hive)

    $uninstallPath = Join-Path $Hive.HivePath 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not (Test-Path -LiteralPath $uninstallPath)) {
        return
    }

    Get-ChildItem -LiteralPath $uninstallPath | ForEach-Object {
        $entry = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        $displayName = Get-OptionalPropertyValue -Object $entry -Name 'DisplayName'
        if ($null -ne $displayName -and $displayName -like $Name) {
            [PSCustomObject]@{
                DisplayName          = [string] $displayName
                Version              = [string] (Get-OptionalPropertyValue -Object $entry -Name 'DisplayVersion')
                Publisher            = [string] (Get-OptionalPropertyValue -Object $entry -Name 'Publisher')
                InstallDate          = [string] (Get-OptionalPropertyValue -Object $entry -Name 'InstallDate')
                User                 = $Hive.User
                UserSid              = $Hive.Sid
                Scope                = 'User'
                PackageType          = 'Win32'
                RegistryKey          = $_.PSChildName
                UninstallString     = [string] (Get-OptionalPropertyValue -Object $entry -Name 'UninstallString')
                QuietUninstallString = [string] (Get-OptionalPropertyValue -Object $entry -Name 'QuietUninstallString')
                InstallLocation      = [string] (Get-OptionalPropertyValue -Object $entry -Name 'InstallLocation')
            }
        }
    }
}

function Get-AppxSoftware {
    if (-not $IncludeAppx) {
        return
    }

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        Write-Warning 'Get-AppxPackage is unavailable in this PowerShell session.'
        return
    }

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not [string]::IsNullOrWhiteSpace($UserSid) -and $UserSid -ne $currentSid) {
        return
    }

    Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like $Name -or $_.PackageFullName -like $Name) {
            [PSCustomObject]@{
                DisplayName          = $_.Name
                Version              = [string] $_.Version
                Publisher            = [string] $_.Publisher
                InstallDate          = $null
                User                 = Get-UserNameForSid -Sid $currentSid
                UserSid              = $currentSid
                Scope                = 'User'
                PackageType          = 'AppX'
                RegistryKey          = $null
                UninstallString      = $null
                QuietUninstallString = $null
                InstallLocation      = [string] $_.InstallLocation
                PackageFullName     = $_.PackageFullName
            }
        }
    }
}

function Invoke-SoftwareUninstall {
    param([Parameter(Mandatory)] $Software)

    if ($Software.PackageType -eq 'AppX') {
        if ($Software.UserSid -ne [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            Write-Warning "Skipping AppX package '$($Software.DisplayName)': it belongs to another user."
            return
        }

        Remove-AppxPackage -Package $Software.PackageFullName -ErrorAction Stop
        return
    }

    $command = $Software.QuietUninstallString
    if ([string]::IsNullOrWhiteSpace($command)) {
        $command = $Software.UninstallString
    }
    if ([string]::IsNullOrWhiteSpace($command)) {
        Write-Warning "Skipping '$($Software.DisplayName)': no uninstall command was registered."
        return
    }

    $trimmedCommand = $command.Trim()
    if ($trimmedCommand -match '^\s*msiexec(?:\.exe)?\s+(?<arguments>.*)$') {
        $arguments = $Matches.arguments
        if ($arguments -notmatch '(?i)(^|\s)/q') {
            $arguments = "$arguments /qn /norestart"
        }
        Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
        return
    }

    $executable = $null
    $arguments = $null
    if ($trimmedCommand -match '^\s*"(?<exe>[^"]+)"\s*(?<args>.*)$') {
        $executable = $Matches.exe
        $arguments = $Matches.args
    }
    elseif ($trimmedCommand -match '^\s*(?<exe>\S+)\s*(?<args>.*)$') {
        $executable = $Matches.exe
        $arguments = $Matches.args
    }

    if ([string]::IsNullOrWhiteSpace($executable)) {
        Write-Warning "Skipping '$($Software.DisplayName)': could not parse '$command'."
        return
    }

    Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
}

Ensure-Pwsh

$software = @(
    Get-LoadedUserHive | ForEach-Object { Get-RegistrySoftware -Hive $_ }
    Get-AppxSoftware
)

if ($Uninstall) {
    if ($Name -eq '*') {
        throw 'Specify -Name with -Uninstall to avoid removing every detected application.'
    }

    if ($software.Count -eq 0) {
        Write-Warning "No matching user software was found for '$Name'."
        return
    }

    $software | ForEach-Object {
        if ($_.PackageType -eq 'AppX') {
            $action = 'Remove AppX package'
        }
        else {
            $uninstallString = if (-not [string]::IsNullOrWhiteSpace($_.QuietUninstallString)) {
                $_.QuietUninstallString
            }
            else {
                $_.UninstallString
            }

            Write-Output "Uninstall string for '$($_.DisplayName)': $uninstallString"
            $action = "Run $uninstallString"
        }

        if ($PSCmdlet.ShouldProcess("$($_.DisplayName) [$($_.User)]", $action)) {
            Invoke-SoftwareUninstall -Software $_
        }
    }
}
else {
    $software
}
