<#
.SYNOPSIS
    Intune Remediations detection script for user-scoped Win32 software.

.DESCRIPTION
    Runs correctly as SYSTEM. It loads each local user's NTUSER.DAT temporarily and
    checks both 32-bit and 64-bit per-user uninstall registry locations.

    Intune Remediations interpretation:
      Exit 1 = matching software found; run remediation.
      Exit 0 = no matching software found.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Change this value before uploading to Intune. Wildcards are supported.
$TargetName = '*'

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
                if ($displayName -and $displayName -like $TargetName) {
                    [PSCustomObject]@{
                        DisplayName           = [string] $displayName
                        Version               = [string] (Get-RegistryPropertyValue -Object $entry -Name 'DisplayVersion')
                        User                  = [string] $Profile.LocalPath
                        UserSid               = $sid
                        UninstallString       = [string] (Get-RegistryPropertyValue -Object $entry -Name 'UninstallString')
                        QuietUninstallString  = [string] (Get-RegistryPropertyValue -Object $entry -Name 'QuietUninstallString')
                        RegistryPath          = $_.PSPath
                    }
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

$matches = @(Get-UserProfiles | ForEach-Object { Get-UserUninstallEntries -Profile $_ })
if ($matches.Count -gt 0) {
    $matches | ForEach-Object {
        Write-Output "Detected: $($_.DisplayName) $($_.Version) for $($_.User)"
    }
    exit 1
}

exit 0
