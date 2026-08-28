<h1 style="color:#1f4e79;">User Software Detection Report</h1>

| Field | Value |
|---|---|
| Report type | Static findings report |
| Source script | `Intune-UserSoftware-Detection.ps1` |
| Intended use | Microsoft Intune Remediations detection |
| Analysis date | 2026-08-28 |
| Endpoint execution | Not performed; no live detection results are included |
| Overall status | **Review required before upload** |

## Summary

The script runs in the SYSTEM context and inspects each non-special local Windows user profile. It temporarily loads `NTUSER.DAT` when the user's registry hive is not already mounted, then searches both standard per-user and 32-bit per-user uninstall registry locations.

The current configuration uses `$TargetName = '*'`, so every uninstall entry with a non-empty `DisplayName` is treated as a match. In Intune Remediations this means the script returns exit code `1` when any per-user software entry is found, which would trigger remediation for the device.

| Metric | Finding |
|---|---:|
| Target name | `*` |
| Registry locations checked | 2 |
| Profile types included | Non-special local profiles with `NTUSER.DAT` |
| Match condition | Non-empty `DisplayName` matching `$TargetName` |
| Match output | Display name, version, user path, SID, uninstall commands, registry path |
| Exit code when matches exist | `1` |
| Exit code when no matches exist | `0` |
| Live endpoint results | Not available |

**Default table ordering:** Severity descending, then finding ID ascending. Use the alternate table below for finding-ID ascending order. In a plain Markdown viewer, use the viewer's text search to filter by ID, severity, area, or keyword.

## Findings

| ID | Severity | Area | Finding | Impact |
|---|---|---|---|---|
| DET-001 | Critical | Target selection | `$TargetName` is set to `*`. Every qualifying per-user uninstall entry is detected. | A paired remediation script could attempt to uninstall all discovered user-scoped software. |
| DET-002 | High | Intune behavior | Any match produces exit code `1`, regardless of software count or whether a particular application is intended for removal. | Remediation is triggered whenever any matching entry exists. |
| DET-003 | Medium | Error handling | Registry enumeration and property reads use `SilentlyContinue`. Access or read failures can be invisible. | The result may report no match even when a profile or registry key could not be inspected. |
| DET-004 | Medium | Duplicate reporting | The script checks separate 64-bit and 32-bit uninstall paths but does not de-duplicate entries. | The same product may be reported more than once if registered in both locations. |
| DET-005 | Low | Output format | Output is human-readable text only: `Detected: <name> <version> for <user>`. | Downstream reporting cannot reliably consume stable fields such as SID, registry path, or version. |
| DET-006 | Low | Profile coverage | Only profiles returned by `Win32_UserProfile` with an existing local path and `NTUSER.DAT` are inspected. | Roaming, unavailable, damaged, or otherwise excluded profiles may not be assessed. |

## Findings By ID

This is the portable alternate view, sorted by finding ID ascending. It contains the same findings as the severity view above.

| ID | Severity | Area |
|---|---|---|
| DET-001 | Critical | Target selection |
| DET-002 | High | Intune behavior |
| DET-003 | Medium | Error handling |
| DET-004 | Medium | Duplicate reporting |
| DET-005 | Low | Output format |
| DET-006 | Low | Profile coverage |

## Detection Method

1. Query `Win32_UserProfile` through CIM.
2. Exclude special profiles and profiles without a valid local path or `NTUSER.DAT`.
3. Load an unmounted user hive under a temporary `HKEY_USERS` name.
4. Inspect:
   - `Software\Microsoft\Windows\CurrentVersion\Uninstall`
   - `Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`
5. Read `DisplayName` and compare it with `$TargetName` using PowerShell `-like` wildcard matching.
6. Unload hives that were loaded by the script.
7. Return exit code `1` when one or more matches exist; otherwise return `0`.

## Configuration Review

| Setting | Current value | Assessment |
|---|---|---|
| `$TargetName` | `*` | Must be replaced with the intended application name or wildcard before production use. |
| Matching property | `DisplayName` | Suitable for basic matching, but vendor naming and version suffixes can vary. |
| Hive cleanup | `finally` unloads script-loaded hives | Good cleanup behavior for the normal processing path. |
| Error preference | `$ErrorActionPreference = 'Stop'` with selected silent operations | Mixed behavior: terminating errors stop execution, while registry access failures may be hidden. |

## Recommended Actions

1. Set `$TargetName` to a specific, tested application pattern before uploading to Intune.
2. Test against devices containing the target application, no target application, multiple user profiles, and both 32-bit and 64-bit registrations.
3. Review the paired remediation script before enabling it. A wildcard detection target must not be paired with an unrestricted uninstall action.
4. Consider emitting structured output or a separate report export if results will be collected outside the Intune detection status.
5. Add visible logging or a controlled error result for profile-hive load and registry-read failures so an incomplete scan is not mistaken for a clean scan.
6. Add de-duplication based on stable identity, such as user SID plus registry key, if both uninstall views can contain the same product.

## Limitations

- This report is based on source-code inspection only.
- No endpoint registry data was queried.
- No software names, versions, users, or match counts can be confirmed from the script alone.
- Markdown tables remain portable but are not interactive in every renderer. This report provides a severity-sorted view and an ID-sorted view; use text search to filter in plain Markdown viewers.

## Conclusion

The detection mechanics are appropriate for discovering per-user uninstall registrations under SYSTEM, including 32-bit and 64-bit registry views. The current wildcard target is the controlling risk: as written, the script detects all qualifying per-user software and returns the remediation-triggering exit code whenever any such entry exists. Replace and test the target before production deployment.
