# Windows 11 Boot Repair and Recovery Tool

A PowerShell 5.1 repair script for Windows 11 that will not boot normally after a
failed or incompatible update, corrupted system files, broken boot configuration,
or damaged component store. Designed to be run from **Safe Mode with Networking**
as an **Administrator**.

## Features

The script runs through a safe, ordered repair workflow:

1. **Environment snapshot** — OS build, last boot time, recent critical events.
2. **Backup** — BCD, registry hives, and services baseline saved to
   `C:\RepairBackup_<timestamp>` before any change is made.
3. **Remove problematic update** — lists recently installed KBs and optionally
   uninstalls a specific KB via DISM, then pauses Windows Update so the bad update
   is not re-delivered.
4. **Revert pending installation** — `dism /revertpendingactions` plus a full reset
   of the Windows Update components (`SoftwareDistribution`, `catroot2`, and the
   related services).
5. **System file and component store repair** — `sfc /scannow` and
   `dism /online /cleanup-image /restorehealth`, with optional `install.wim` source.
6. **Disk and file system integrity** — schedules `chkdsk C: /f /r /x` for the next
   boot and reports SMART health for each physical disk.
7. **Boot configuration (BCD)** — dumps the current store, restores common boot
   defaults, and prints the exact `bootrec` commands to run from WinRE if needed.
8. **Startup services and driver sanity** — lists Automatic services that are not
   running and points to recovery options if the boot still fails.
9. **Restore update and Defender defaults** — re-enables Windows Defender services
   that may have been disabled.
10. **Clean stuck update temp** — removes `pending.xml` and clears the Windows
    Update download cache.
11. **Summary and next steps** — a clear follow-up checklist.
12. **Reboot** — prompts before rebooting (skipped with `-NoReboot` or `-DryRun`).

## Requirements

- Windows 11
- PowerShell 5.1 or later (built into Windows 11)
- Administrator privileges
- Recommended: Safe Mode with Networking

## Getting started

### 1. Boot into Safe Mode with Networking

Advanced Startup → Troubleshoot → Advanced Options → Startup Settings →
Restart → press **5** (Enable Safe Mode with Networking).

### 2. Open PowerShell as Administrator

Open the Start menu, type `powershell`, right-click **Windows PowerShell**, and
choose **Run as Administrator**.

### 3. Allow scripts for this session

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

### 4. Run the script

First do a dry run to see what the script will do, without changing anything:

```powershell
.\Repair-Windows11.ps1 -DryRun
```

Then run it for real. The first live run lists your recently installed KBs so you
can identify the bad one:

```powershell
.\Repair-Windows11.ps1
```

To uninstall a specific KB as part of the repair, pass it on the command line:

```powershell
.\Repair-Windows11.ps1 -BadKb 5046617
```

To uninstall more than one KB:

```powershell
.\Repair-Windows11.ps1 -BadKb 5046617,5046613
```

## Parameters

| Parameter        | Type     | Description                                                                 |
| ---------------- | -------- | --------------------------------------------------------------------------- |
| `-DryRun`        | switch   | Show what the script would do without making any changes.                   |
| `-NoReboot`      | switch   | Skip the final reboot prompt.                                              |
| `-SkipUninstall` | switch   | Skip the bad-update uninstall step (use when it was already removed).       |
| `-BadKb`         | string[] | One or more KB numbers to uninstall (for example `-BadKb 5046617,5046613`). |

## Safety

- The script makes a timestamped backup under `C:\RepairBackup_<timestamp>` before
  changing anything.
- Every step is wrapped so a single non-fatal failure never aborts the whole run.
- `-DryRun` lets you preview every action first.
- Windows Update is paused via policy during the repair so the bad update is not
  re-delivered. The script prints the command to re-enable it once the system
  boots stably.

## If the boot still fails

If the system still will not boot after running this script, use the Windows
Recovery Environment (boot from install media → Repair your computer → Advanced
Options):

- **System Restore** — roll back to a restore point before the failed update.
- **Uninstall Updates** — remove the latest quality or feature update.
- **Command Prompt** — rebuild the boot store:

  ```cmd
  bootrec /fixmbr
  bootrec /fixboot
  bootrec /rebuildbcd
  dism /image:C:\ /cleanup-image /revertpendingactions
  ```

## Linting

This repository includes a [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
settings file (`PSScriptAnalyzer.psd1`). Two rules are intentionally excluded and
documented there:

- `PSAvoidUsingWriteHost` — the script is an interactive, colour-coded console tool.
- `PSAvoidUsingEmptyCatchBlock` — best-effort cleanup steps intentionally swallow
  non-fatal errors so a single failed step never aborts the whole repair run.

Run the linter:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path .\Repair-Windows11.ps1 -Settings .\PSScriptAnalyzer.psd1
```

## Disclaimer

This tool modifies system files, boot configuration, the registry, and Windows
Update state. Always run `-DryRun` first, review the output, and ensure you have
a backup. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).