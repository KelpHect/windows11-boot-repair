# Windows 11 Boot Repair and Recovery Tool (full coverage)

A PowerShell 5.1 repair script for Windows 11 that will not boot normally after a
failed or incompatible update, corrupted system files, broken boot configuration,
or damaged component store. Designed to be run from **Safe Mode with Networking**
as an **Administrator**.

It runs the full built-in Windows repair toolchain: DISM pre/post health checks,
SFC, DISM `/RestoreHealth` (cloud via Windows Update, plus optional offline
`install.wim` source), component store cleanup, bad-update removal, pending-action
revert, Windows Update component reset, CHKDSK, SMART, BCD dump, `bcdboot`
boot-file rebuild on the auto-detected EFI System Partition, network stack
reset, Defender defaults restore, System Restore point listing and optional
rollback, and optional Windows Memory Diagnostic scheduling.

Windows Update is paused **only at the end** (after all repairs) so the cloud
repair step is not weakened.

## Features / phases

1. **Environment snapshot** — OS build, last boot time, recent critical events.
2. **Backup** — BCD, registry hives (via `reg save`, which works on locked live
   hives), and services baseline saved to `C:\RepairBackup_<timestamp>` before any
   change is made.
3. **Remove problematic update** — lists recently installed KBs and optionally
   uninstalls a specific KB via DISM. Windows Update is **not** paused here.
4. **Revert pending installation** — `dism /revertpendingactions` plus a full reset
   of the Windows Update components (`SoftwareDistribution`, `catroot2`, and the
   related services).
5. **System file and component store repair** — `sfc /scannow` and
   `dism /online /cleanup-image /restorehealth` (cloud via Windows Update), plus
   optional `install.wim` source. (The informational `/ScanHealth` and `/GetHealth`
   switches were removed — they return exit code 87 on some Windows 11 builds and
   repair nothing.)
6. **Disk and file system integrity** — schedules `chkdsk C: /f /r /x` for the
   next boot and reports SMART health for each physical disk.
7. **Boot configuration (BCD)** — dumps the current store, restores common boot
   defaults, **detects the EFI System Partition** and rebuilds UEFI boot files
   with `bcdboot C:\Windows /s <ESP>: /f UEFI` (assigns a temporary drive letter
   and removes it afterwards), and prints the exact `bootrec` commands to run
   from WinRE if needed.
8. **Network stack repair** — `netsh winsock reset`, `netsh int ip reset`,
   `netsh int ipv6 reset`, and `ipconfig /flushdns` (applies on reboot).
9. **Component store cleanup (optional)** — `-CleanComponentStore` runs
   `DISM /StartComponentCleanup` and `/ResetBase` to shrink the component store.
10. **Startup services, drivers, and Defender defaults** — lists Automatic
    services that are not running and re-enables Windows Defender services that
    may have been disabled.
11. **System Restore points** — lists available restore points and optionally
    rolls back with `-RestorePoint <SequenceNumber>` (with confirmation, triggers
    a reboot).
12. **Clean stuck update temp** — removes `pending.xml` and clears the Windows
    Update download cache.
13. **Pause Windows Update** — now that all repairs are done, disables
    auto-update via policy so the bad update is not re-delivered.
14. **Memory diagnostic (optional)** — `-ScheduleMemTest` launches `mdsched.exe`
    so you can schedule a memory test for the next boot.
15. **Summary and next steps** — a clear follow-up checklist.
16. **Reboot** — prompts before rebooting (skipped with `-NoReboot` or `-DryRun`).

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

To uninstall a specific KB as part of the repair:

```powershell
.\Repair-Windows11.ps1 -BadKb 5046617
```

To roll back to a known System Restore point (first run without `-RestorePoint` to
list available points, then re-run with the chosen sequence number):

```powershell
.\Repair-Windows11.ps1 -RestorePoint 3
```

Full coverage run (shrink the component store and schedule a memory test too):

```powershell
.\Repair-Windows11.ps1 -CleanComponentStore -ScheduleMemTest
```

## Parameters

| Parameter               | Type     | Description                                                                 |
| ----------------------- | -------- | --------------------------------------------------------------------------- |
| `-DryRun`               | switch   | Show what the script would do without making any changes.                   |
| `-NoReboot`             | switch   | Skip the final reboot prompt.                                              |
| `-SkipUninstall`        | switch   | Skip the bad-update uninstall step (use when it was already removed).       |
| `-BadKb`                | string[] | One or more KB numbers to uninstall (for example `-BadKb 5046617,5046613`). |
| `-CleanComponentStore`  | switch   | Run `DISM /StartComponentCleanup` (and `/ResetBase`) after repairs.         |
| `-ScheduleMemTest`      | switch   | Launch Windows Memory Diagnostic to schedule a memory test for next boot.  |
| `-RestorePoint`         | int      | Sequence number of a System Restore point to roll back to (with confirmation). |

## What Windows repair tools it covers

| Windows tool | In script | Where |
| --- | --- | --- |
| `sfc /scannow` | yes | Phase 5 |
| `DISM /RestoreHealth` (cloud via Windows Update) | yes | Phase 5 |
| `DISM /RestoreHealth` with offline `install.wim` | yes (if `D:\sources\install.wim` exists) | Phase 5 |
| `DISM /StartComponentCleanup` + `/ResetBase` | yes (`-CleanComponentStore`) | Phase 9 |
| `DISM /revertpendingactions` | yes | Phase 4 |
| `DISM /remove-package` (uninstall KB) | yes | Phase 3 |
| `chkdsk C: /f /r /x` | yes (scheduled for next boot) | Phase 6 |
| SMART / physical disk health | yes | Phase 6 |
| `bcdedit` dump + boot defaults | yes | Phase 7 |
| `bcdboot` (rebuild UEFI boot files on auto-detected ESP) | yes | Phase 7 |
| `netsh winsock reset` / `int ip reset` / `int ipv6 reset` | yes | Phase 8 |
| `ipconfig /flushdns` | yes | Phase 8 |
| Windows Update component reset | yes | Phase 4 |
| Defender service re-enable | yes | Phase 10 |
| System Restore point list + rollback | yes (`-RestorePoint`) | Phase 11 |
| Windows Memory Diagnostic | yes (`-ScheduleMemTest`) | Phase 14 |
| `bootrec /rebuildbcd` | no — WinRE only; the script prints the exact commands | Phase 7 note |

## Safety

- The script makes a timestamped backup under `C:\RepairBackup_<timestamp>` before
  changing anything. Registry hives use `reg save` (backup semantics, works on
  locked live hives).
- Every step is wrapped so a single non-fatal failure never aborts the whole run.
- `-DryRun` lets you preview every action first.
- Windows Update is paused only at the end (Phase 13), after all repairs, so the
  cloud repair step is not weakened. The script prints the command to re-enable
  it once the system boots stably.

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

This tool modifies system files, boot configuration, the registry, the network
stack, and Windows Update state. Always run `-DryRun` first, review the output,
and ensure you have a backup. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).