<#
.SYNOPSIS
    Intune Remediations remediation script for user-scoped Win32 software.

.DESCRIPTION
    Runs as SYSTEM, loads each local user's NTUSER.DAT temporarily, and executes the
    registered per-user uninstall command for matching software. Test with the detection
    script and an explicit target before uploading to Intune.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep this identical to the value in Intune-UserSoftware-Detection.ps1.
$TargetName = '*'
$LogPath = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\UserSoftwareRemediation.log'

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogPath -Value "$timestamp $Message"
    Write-Output $Message
}

function Get-RegistryPropertyValue {
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

function Get-UserProfiles {
    Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
        -not $_.Special -and
        $_.LocalPath -and
        (Test-Path -LiteralPath $_.LocalPath -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath (Join-Path $_.LocalPath 'NTUSER.DAT') -ErrorAction SilentlyContinue)
    }
}

function Get-UserUninstallEntries {
    param([Parameter(Mandatory)] $Profile)

    $sid = [string] $Profile.SID
    $hiveName = "IntuneUser_$($sid -replace '[^A-Za-z0-9]', '_')"
    $hivePath = "Registry::HKEY_USERS\$hiveName"
    $loadedByScript = $false

    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        & reg.exe load "HKU\$hiveName" (Join-Path $Profile.LocalPath 'NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not load profile hive for $($Profile.LocalPath)."
            return
        }
        $loadedByScript = $true
    }
    else {
        $hiveName = $sid
        $hivePath = "Registry::HKEY_USERS\$sid"
    }

    try {
        foreach ($relativePath in @(
            'Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
            $uninstallPath = Join-Path $hivePath $relativePath
            if (-not (Test-Path -LiteralPath $uninstallPath)) {
                continue
            }

            Get-ChildItem -LiteralPath $uninstallPath -ErrorAction SilentlyContinue | ForEach-Object {
                $entry = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $displayName = Get-RegistryPropertyValue -Object $entry -Name 'DisplayName'
                if (-not $displayName -or $displayName -notlike $TargetName) {
                    return
                }

                $command = Get-RegistryPropertyValue -Object $entry -Name 'QuietUninstallString'
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $command = Get-RegistryPropertyValue -Object $entry -Name 'UninstallString'
                }

                [PSCustomObject]@{
                    DisplayName = [string] $displayName
                    Version     = [string] (Get-RegistryPropertyValue -Object $entry -Name 'DisplayVersion')
                    User        = [string] $Profile.LocalPath
                    UserSid     = $sid
                    Command     = [string] $command
                }
            }
        }
    }
    finally {
        if ($loadedByScript) {
            & reg.exe unload "HKU\$hiveName" | Out-Null
        }
    }
}

function Invoke-Uninstall {
    param([Parameter(Mandatory)] $Software)

    if ([string]::IsNullOrWhiteSpace($Software.Command)) {
        Write-Log "No uninstall command registered for $($Software.DisplayName) [$($Software.User)]."
        return $false
    }

    Write-Log "Uninstalling $($Software.DisplayName) $($Software.Version) for $($Software.User). Command: $($Software.Command)"
    $command = $Software.Command.Trim()

    if ($command -match '^\s*"(?<exe>[^"]+)"\s*(?<args>.*)$') {
        $executable = $Matches.exe
        $arguments = $Matches.args
    }
    elseif ($command -match '^\s*(?<exe>\S+)\s*(?<args>.*)$') {
        $executable = $Matches.exe
        $arguments = $Matches.args
    }
    else {
        Write-Log "Could not parse uninstall command for $($Software.DisplayName)."
        return $false
    }

    if ($executable -match '(?i)(^|\\)msiexec(?:\.exe)?$') {
        if ($arguments -match '(?i)(^|\s)/I(?=\s|\{|$)') {
            $arguments = $arguments -replace '(?i)(^|\s)/I(?=\s|\{|$)', '$1/X'
        }
        if ($arguments -notmatch '(?i)(^|\s)/q') {
            $arguments = "$arguments /qn /norestart"
        }
        $executable = 'msiexec.exe'
    }

    $process = Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
    Write-Log "Uninstaller exit code for $($Software.DisplayName): $($process.ExitCode)"
    return ($process.ExitCode -eq 0)
}

New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
$matches = @(Get-UserProfiles | ForEach-Object { Get-UserUninstallEntries -Profile $_ })
$success = $true
foreach ($software in $matches) {
    # if (-not (Invoke-Uninstall -Software $software)) {
    #     $success = $false
    # }
    write-output $matches
}

if ($matches.Count -eq 0) {
    Write-Log "No matching software found for '$TargetName'."
}

if ($success) { exit 0 }
exit 1
