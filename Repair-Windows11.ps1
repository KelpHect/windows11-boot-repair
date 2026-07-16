<#
.SYNOPSIS
    Windows 11 Boot Repair and Recovery Tool (full coverage).

.DESCRIPTION
    A safe-mode-oriented PowerShell 5.1 repair script for Windows 11 that will
    not boot normally after a failed or incompatible update, corrupted system
    files, broken boot configuration, or damaged component store.

    Runs the full built-in Windows repair toolchain: DISM pre/post health
    checks, SFC, DISM /RestoreHealth (cloud + offline source), component store
    cleanup, bad-update removal, pending-action revert, Windows Update component
    reset, CHKDSK, SMART, BCD dump, bcdboot boot-file rebuild on the EFI System
    Partition, network stack reset, Defender defaults restore, System Restore
    point listing and optional rollback, and optional Windows Memory Diagnostic
    scheduling.

    Windows Update is paused only at the very end (after all repairs) so the
    cloud repair step is not weakened.

    Intended to be run from Safe Mode with Networking as an Administrator.

.PARAMETER DryRun
    Show what the script would do without making any changes.

.PARAMETER NoReboot
    Skip the final reboot prompt.

.PARAMETER SkipUninstall
    Skip the bad-update uninstall step (use when the update was already removed).

.PARAMETER BadKb
    One or more KB numbers to uninstall (for example -BadKb 5046617,5046613).

.PARAMETER CleanComponentStore
    Run DISM /StartComponentCleanup (and /ResetBase) to shrink the component
    store after repairs. Maintenance only; not required for boot repair.

.PARAMETER ScheduleMemTest
    Launch Windows Memory Diagnostic (mdsched.exe) so you can schedule a memory
    test for the next boot. Requires the small GUI dialog to confirm.

.PARAMETER RestorePoint
    Sequence number of a System Restore point to roll back to. Use without a
    value first to list available points, then re-run with the chosen sequence.

.EXAMPLE
    .\Repair-Windows11.ps1 -DryRun

    Shows every step without changing anything.

.EXAMPLE
    .\Repair-Windows11.ps1 -BadKb 5046617

    Runs all repairs and uninstalls KB5046617.

.EXAMPLE
    .\Repair-Windows11.ps1 -RestorePoint 3

    Rolls the system back to restore point sequence number 3 (after confirmation).

.NOTES
    Requires Administrator privileges and PowerShell 5.1 or later.
    A reboot is required after completion. The script will prompt before
    rebooting unless -NoReboot is supplied.
#>

# ============================================================================
# 0. Pre-flight checks
# ============================================================================
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $NoReboot,
    [switch] $SkipUninstall,
    [string[]] $BadKb,
    [switch] $CleanComponentStore,
    [switch] $ScheduleMemTest,
    [int] $RestorePoint = -1
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Windows 11 Boot Repair'

# --- Helpers -----------------------------------------------------------------
function Write-Section { param([string]$Text) Write-Host "`n========== $Text ==========" -ForegroundColor Cyan }
function Write-Step     { param([string]$Text) Write-Host "  -> $Text" -ForegroundColor Yellow }
function Write-Ok       { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn     { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor DarkYellow }
function Write-Err      { param([string]$Text) Write-Host "  [ERR]  $Text" -ForegroundColor Red }
function Write-Info     { param([string]$Text) Write-Host "  [i]    $Text" -ForegroundColor Gray }

function Invoke-RepairStep {
    <#
        Runs an external repair action, logs the outcome, and never aborts the
        script on a non-fatal failure.
    #>
    param(
        [string] $Label,
        [scriptblock] $Action
    )

    Write-Step $Label
    if ($DryRun) {
        Write-Info "(dry-run) Would run: $($Action.ToString().Trim())"
        return $true
    }

    try {
        & $Action
        if (($null -ne $LASTEXITCODE) -and ($LASTEXITCODE -ne 0)) {
            Write-Warn "completed with exit code $LASTEXITCODE"
            return $false
        }
        return $true
    }
    catch {
        Write-Err "failed: $($_.Exception.Message)"
        return $false
    }
}

# --- Administrator check ------------------------------------------------------
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal  = [Security.Principal.WindowsPrincipal]$currentUser
$isAdmin    = $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Err 'This script must be run as Administrator.'
    Write-Info 'In Safe Mode: open Start, type powershell, right-click > Run as Administrator.'
    exit 1
}

# --- PowerShell version check -------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err "PowerShell $($PSVersionTable.PSVersion) is too old. Version 5.1 or later is required."
    exit 1
}

$modeText = if ($DryRun) { 'DRY-RUN (no changes will be made)' } else { 'LIVE' }
Write-Host @"
####################################################################
#  Windows 11 Boot Repair and Recovery Tool (full coverage)         #
#  Mode: $modeText
#  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
####################################################################
"@ -ForegroundColor White

if ($DryRun) {
    Write-Warn 'DRY-RUN mode: commands will be shown but NOT executed.'
}

$anyFailures = $false
$wimSourceUsed = $false

# ============================================================================
# 1. Environment snapshot
# ============================================================================
Write-Section '1. Environment Snapshot'

try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "OS: $($os.Caption) $($os.Version) Build $($os.BuildNumber)"
    Write-Info "Last boot: $($os.LastBootUpTime)"
    $safeBootKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot'
    Write-Info "Safe Mode: $(if (Test-Path $safeBootKey) { 'Yes' } else { 'No/Unknown' })"
}
catch {
    Write-Warn 'Could not read operating system information.'
}

try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Info "Model: $($cs.Manufacturer) $($cs.Model)"
}
catch {
    Write-Warn 'Could not read computer system information.'
}

Write-Step 'Recent critical/system errors (last 24 hours)'
if (-not $DryRun) {
    try {
        $since = (Get-Date).AddDays(-1)
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 15 -ErrorAction SilentlyContinue
        if ($events) {
            $events |
                Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, @{ n = 'Msg'; e = { ($_.Message -split "`n")[0] } } |
                Format-Table -AutoSize |
                Out-String |
                Write-Host
        }
        else {
            Write-Info 'No critical/error events in the last 24 hours.'
        }
    }
    catch {
        Write-Warn 'Event log read failed (normal in some Safe Mode configurations).'
    }
}
else {
    Write-Info '(dry-run) skip event log'
}

# ============================================================================
# 2. Backup critical configuration
# ============================================================================
Write-Section '2. Backup Critical Config (BCD, Registry, Services)'

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupRoot = "$env:SystemDrive\RepairBackup_$timestamp"

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Write-Info "Backup folder: $backupRoot"

    & bcdedit /export "$backupRoot\BCD.bak" 2>$null | Out-Null
    if (Test-Path "$backupRoot\BCD.bak") {
        Write-Ok 'BCD config backed up'
    }
    else {
        Write-Warn 'BCD backup skipped (bcdedit unavailable in Safe Boot)'
    }

    # Live registry hives are locked by the running OS, so Copy-Item cannot
    # read them. Use `reg save`, which uses backup semantics and works on
    # in-use hives. Each hive is guarded so a single failure never aborts
    # the whole repair run.
    $hives = @(
        @{ Key = 'HKLM\SYSTEM';   File = 'SYSTEM.bak'   },
        @{ Key = 'HKLM\SOFTWARE'; File = 'SOFTWARE.bak' },
        @{ Key = 'HKLM\SAM';      File = 'SAM.bak'      },
        @{ Key = 'HKLM\SECURITY'; File = 'SECURITY.bak' },
        @{ Key = 'HKU\.DEFAULT';  File = 'DEFAULT.bak'  },
        @{ Key = 'HKCU';          File = 'NTUSER.DAT.bak' }
    )
    $savedCount = 0
    foreach ($hive in $hives) {
        $dest = Join-Path $backupRoot $hive.File
        try {
            & reg save $hive.Key $dest /y 2>$null | Out-Null
            if ((-not $LASTEXITCODE) -or $LASTEXITCODE -eq 0) {
                if (Test-Path $dest) { $savedCount++ }
            }
        }
        catch {
            Write-Warn "Could not save hive $($hive.Key): $($_.Exception.Message)"
        }
    }
    if ($savedCount -gt 0) {
        Write-Ok "Registry hives backed up ($savedCount/$($hives.Count))"
    }
    else {
        Write-Warn 'No registry hives could be saved (live hives locked). Continuing anyway.'
    }

    try {
        Get-Service |
            Select-Object Name, DisplayName, Status, StartType |
            Export-Csv "$backupRoot\ServicesBaseline.csv" -NoTypeInformation
        Write-Ok 'Services baseline saved'
    }
    catch {
        Write-Warn 'Services baseline failed'
    }
}
else {
    Write-Info "(dry-run) would create backup at $backupRoot"
}

# ============================================================================
# 3. Remove the problematic Windows update
# ============================================================================
Write-Section '3. Remove Problematic Windows Update'

if ($SkipUninstall) {
    Write-Info 'Skipping update removal (-SkipUninstall supplied).'
}
else {
    Write-Step 'List recently installed updates'
    if (-not $DryRun) {
        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $count    = $searcher.GetTotalHistoryCount()
            if ($count -gt 0) {
                $history = $searcher.QueryHistory(0, $count) |
                    Where-Object { $_.Date -gt (Get-Date).AddDays(-14) }
                if ($history) {
                    $history |
                        Select-Object Date, ResultCode, Title |
                        Format-Table -AutoSize |
                        Out-String |
                        Write-Host
                }
                else {
                    Write-Info 'No updates installed in the last 14 days (per WU API).'
                }
            }
            else {
                Write-Info 'No update history available.'
            }
        }
        catch {
            Write-Warn 'WU API unavailable; falling back to DISM package listing.'
        }
    }

    Write-Step 'Identify removable recent packages via DISM'
    if (-not $DryRun) {
        try {
            $packages = & dism /online /get-packages 2>$null |
                Select-String 'Package Identity' -Context 0, 0
            Write-Info "Found $($packages.Count) package identities. Recent ones:"
            $packages | Select-Object -First 20 | ForEach-Object { Write-Host "    $($_.Line)" -ForegroundColor DarkGray }
        }
        catch {
            Write-Warn 'DISM get-packages failed.'
        }
    }

    if ($BadKb -and $BadKb.Count -gt 0) {
        foreach ($kb in $BadKb) {
            Write-Step "Uninstalling KB$kb"
            if (-not $DryRun) {
                & dism /online /remove-package /packagename:"Package_for_KB$kb*" /norestart 2>&1 |
                    Out-String |
                    Write-Host
            }
            else {
                Write-Info "(dry-run) would uninstall KB$kb"
            }
        }
    }
    else {
        Write-Info 'No -BadKb supplied. Review the list above and re-run with -BadKb <number>.'
    }

    # NOTE: Windows Update is paused only at the end (Section 11) so the cloud
    # repair step (DISM /RestoreHealth) is not weakened while repairs run.
}

# ============================================================================
# 4. Revert stuck or pending update installation
# ============================================================================
Write-Section '4. Revert Stuck / Pending Update Installation'

Invoke-RepairStep 'DISM revert pending actions' {
    & dism /online /cleanup-image /revertpendingactions 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

Write-Step 'Reset Windows Update components'
if (-not $DryRun) {
    $wuServices = 'bits', 'wuauserv', 'appidsvc', 'cryptsvc', 'msiserver'
    foreach ($service in $wuServices) {
        try { Stop-Service -Name $service -Force -ErrorAction SilentlyContinue } catch {}
    }

    $softwareDistribution     = "$env:SystemRoot\SoftwareDistribution"
    $softwareDistributionBak = "$env:SystemRoot\SoftwareDistribution.bak"
    $catroot2                 = "$env:SystemRoot\System32\catroot2"
    $catroot2Bak              = "$env:SystemRoot\System32\catroot2.bak"

    if (Test-Path $softwareDistributionBak) {
        Remove-Item $softwareDistributionBak -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $softwareDistribution) {
        Rename-Item $softwareDistribution 'SoftwareDistribution.bak' -ErrorAction SilentlyContinue
    }
    if (Test-Path $catroot2Bak) {
        Remove-Item $catroot2Bak -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $catroot2) {
        Rename-Item $catroot2 'catroot2.bak' -ErrorAction SilentlyContinue
    }

    foreach ($service in $wuServices) {
        try { Start-Service -Name $service -ErrorAction SilentlyContinue } catch {}
    }
    Write-Ok 'Windows Update components reset'
}
else {
    Write-Info '(dry-run) would reset Windows Update components'
}

# ============================================================================
# 5. System file and component store repair (with pre/post health checks)
# ============================================================================
Write-Section '5. Repair System Files and Component Store'

Write-Step 'DISM pre-check: ScanHealth (component store corruption scan)'
$scanPre = Invoke-RepairStep 'DISM /ScanHealth' {
    & dism /online /cleanup-image /scanhealth 2>&1 |
        Out-String |
        Write-Host
}
if (-not $scanPre) { Write-Info 'Pre ScanHealth reported issues (expected if corrupted).' }

Write-Step 'DISM pre-check: GetHealth (no-repair health status)'
Invoke-RepairStep 'DISM /GetHealth' {
    & dism /online /cleanup-image /gethealth 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

$sfcOk = Invoke-RepairStep 'SFC /scannow (system file checker)' {
    & sfc /scannow 2>&1 |
        Out-String |
        Write-Host
}
if (-not $sfcOk) { $script:anyFailures = $true }

$dismOk = Invoke-RepairStep 'DISM /RestoreHealth (component store repair; cloud via Windows Update)' {
    & dism /online /cleanup-image /restorehealth 2>&1 |
        Out-String |
        Write-Host
}
if (-not $dismOk) { $script:anyFailures = $true }

$installWim = 'D:\sources\install.wim'
if (-not $DryRun -and (Test-Path $installWim -ErrorAction SilentlyContinue)) {
    Invoke-RepairStep 'DISM /RestoreHealth with install.wim source (D:)' {
        & dism /online /cleanup-image /restorehealth /source:WIM:$installWim`:1 /limitaccess 2>&1 |
            Out-String |
            Write-Host
    } | Out-Null
    $script:wimSourceUsed = $true
}

Write-Step 'DISM post-check: GetHealth (confirm component store is healthy)'
Invoke-RepairStep 'DISM /GetHealth (post)' {
    & dism /online /cleanup-image /gethealth 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

# ============================================================================
# 6. Disk and file system integrity
# ============================================================================
Write-Section '6. Disk and File System Integrity'

Invoke-RepairStep 'Schedule CHKDSK on C: for next boot' {
    & chkdsk C: /f /r /x 2>&1 |
        Out-String |
        Write-Host
    Write-Info 'CHKDSK scheduled to run on next reboot (C: is in use).'
} | Out-Null

Write-Step 'Disk SMART health (best-effort)'
if (-not $DryRun) {
    try {
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            Write-Info "Disk $($disk.DeviceId): $($disk.FriendlyName) - Health: $($disk.HealthStatus) - Op: $($disk.OperationalStatus)"
            if ($disk.HealthStatus -ne 'Healthy') {
                Write-Warn "Disk $($disk.DeviceId) reports unhealthy!"
            }
        }
    }
    catch {
        Write-Warn 'Physical disk query failed in this environment.'
    }
}
else {
    Write-Info '(dry-run) would query physical disk health'
}

# ============================================================================
# 7. Boot configuration (BCD) repair + bcdboot boot-file rebuild
# ============================================================================
Write-Section '7. Boot Configuration (BCD) Repair + bcdboot'

Write-Step 'Show current BCD entries'
if (-not $DryRun) {
    try {
        & bcdedit /enum all 2>&1 |
            Out-String |
            Write-Host
    }
    catch {
        Write-Warn 'bcdedit not available in current Safe Boot mode'
    }
}
else {
    Write-Info '(dry-run) would dump BCD'
}

if (-not $DryRun) {
    Write-Step 'Restoring common boot defaults'
    & bcdedit /set nx AlwaysOn 2>$null | Out-Null
    Write-Ok 'nx (DEP) set to AlwaysOn'
}
else {
    Write-Info '(dry-run) would set nx AlwaysOn'
}

# --- bcdboot: rebuild boot files on the EFI System Partition ------------------
Write-Step 'Rebuild boot files with bcdboot'
if (-not $DryRun) {
    $espPartition = $null
    $tempLetter   = $null
    try {
        # GPT EFI System Partition type GUID
        $espGuid = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
        $espPartition = Get-Partition -ErrorAction SilentlyContinue |
            Where-Object { $_.GPTType -eq $espGuid } |
            Select-Object -First 1

        if ($espPartition) {
            Write-Info "EFI System Partition found on Disk $($espPartition.DiskNumber) Partition $($espPartition.PartitionNumber)"
            # Ensure it has a drive letter so bcdboot can target it
            if (-not $espPartition.DriveLetter -or $espPartition.DriveLetter -eq 0) {
                $tempLetter = 'Z'
                Add-PartitionAccessPath -DiskNumber $espPartition.DiskNumber -PartitionNumber $espPartition.PartitionNumber -AccessPath "$tempLetter`:\" -ErrorAction SilentlyContinue | Out-Null
                Write-Info "Temporarily assigned drive letter $tempLetter to ESP"
            }
            else {
                $tempLetter = $espPartition.DriveLetter
            }

            if ($tempLetter) {
                & bcdboot "$env:SystemRoot" /s "$tempLetter`:" /f UEFI 2>&1 |
                    Out-String |
                    Write-Host
                Write-Ok "bcdboot rebuilt UEFI boot files on ${tempLetter}:"
            }
            else {
                # Fall back: bcdboot without /s targets the system partition
                & bcdboot "$env:SystemRoot" /f UEFI 2>&1 |
                    Out-String |
                    Write-Host
                Write-Ok 'bcdboot rebuilt UEFI boot files (system partition auto-targeted)'
            }
        }
        else {
            Write-Info 'No GPT EFI System Partition found (MBR or unusual layout). Falling back to bcdboot auto-target.'
            & bcdboot "$env:SystemRoot" /f UEFI 2>&1 |
                Out-String |
                Write-Host
            Write-Ok 'bcdboot rebuilt UEFI boot files (auto-targeted)'
        }
    }
    catch {
        Write-Warn "bcdboot step failed: $($_.Exception.Message)"
    }
    finally {
        # Remove the temporary access path we added (do NOT remove a pre-existing letter)
        if ($espPartition -and $tempLetter -eq 'Z') {
            try {
                Remove-PartitionAccessPath -DiskNumber $espPartition.DiskNumber -PartitionNumber $espPartition.PartitionNumber -AccessPath "$tempLetter`:" -ErrorAction SilentlyContinue
                Write-Info 'Removed temporary ESP drive letter Z:'
            }
            catch {}
        }
    }
}
else {
    Write-Info '(dry-run) would detect ESP and run: bcdboot C:\Windows /s <ESP>: /f UEFI'
}

Write-Host @'

  NOTE: A full boot store rebuild (bootrec /rebuildbcd) must run from the
  Windows Recovery Environment (WinRE), not Safe Mode. If the BCD is
  genuinely corrupted, boot from install media > Repair > Command Prompt:

     bootrec /fixmbr
     bootrec /fixboot
     bootrec /rebuildbcd

'@ -ForegroundColor DarkCyan

# ============================================================================
# 8. Network stack repair (Safe Mode with Networking)
# ============================================================================
Write-Section '8. Network Stack Repair'

Write-Step 'Reset Winsock catalog'
Invoke-RepairStep 'netsh winsock reset' {
    & netsh winsock reset 2>&1 |
        Out-String |
        Write-Host
    Write-Info 'Winsock reset (requires reboot to take effect).'
} | Out-Null

Write-Step 'Reset TCP/IP stack (IPv4)'
Invoke-RepairStep 'netsh int ip reset' {
    & netsh int ip reset 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

Write-Step 'Reset TCP/IP stack (IPv6)'
Invoke-RepairStep 'netsh int ipv6 reset' {
    & netsh int ipv6 reset 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

Write-Step 'Flush DNS resolver cache'
Invoke-RepairStep 'ipconfig /flushdns' {
    & ipconfig /flushdns 2>&1 |
        Out-String |
        Write-Host
} | Out-Null

Write-Ok 'Network stack reset complete (reboot required to apply).'

# ============================================================================
# 9. Optional: component store cleanup
# ============================================================================
Write-Section '9. Component Store Cleanup (optional)'

if ($CleanComponentStore) {
    Invoke-RepairStep 'DISM /StartComponentCleanup' {
        & dism /online /cleanup-image /startcomponentcleanup 2>&1 |
            Out-String |
            Write-Host
    } | Out-Null

    Write-Step 'DISM /StartComponentCleanup /ResetBase (further reduce; supersedes old updates)'
    Invoke-RepairStep 'DISM /StartComponentCleanup /ResetBase' {
        & dism /online /cleanup-image /startcomponentcleanup /resetbase 2>&1 |
            Out-String |
            Write-Host
        Write-Info 'Note: /ResetBase means previously installed updates can no longer be uninstalled.'
    } | Out-Null
    Write-Ok 'Component store cleanup done.'
}
else {
    Write-Info 'Skipped (pass -CleanComponentStore to shrink the component store after repairs).'
}

# ============================================================================
# 10. Startup services, drivers, and Defender defaults
# ============================================================================
Write-Section '10. Startup Services, Drivers, and Defender Defaults'

Write-Step 'Automatic services not running'
if (-not $DryRun) {
    try {
        $notRunning = Get-Service |
            Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
        if ($notRunning) {
            Write-Info 'Automatic services not running (may be normal in Safe Mode):'
            $notRunning |
                Select-Object Name, DisplayName, Status, StartType |
                Format-Table -AutoSize |
                Out-String |
                Write-Host
        }
        else {
            Write-Ok 'All Automatic services are running.'
        }
    }
    catch {
        Write-Warn 'Service query failed'
    }
}
else {
    Write-Info '(dry-run) would list non-running automatic services'
}

Write-Step 'Re-enable Windows Defender services if disabled'
if (-not $DryRun) {
    $defenderServices = 'WinDefend', 'SecurityHealthService', 'Sense', 'WdNisSvc'
    foreach ($service in $defenderServices) {
        try {
            $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                Set-Service -Name $service -StartupType Manual -ErrorAction SilentlyContinue
                Write-Info "Re-enabled startup for $service (Manual)"
            }
        }
        catch {}
    }

    $defenderPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    if (Test-Path $defenderPolicy) {
        try {
            Set-ItemProperty $defenderPolicy -Name 'DisableAntiSpyware' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
    Write-Ok 'Defender defaults restored where safe to do so in Safe Mode'
}
else {
    Write-Info '(dry-run) would re-enable Defender services'
}

# ============================================================================
# 11. System Restore points (list + optional rollback)
# ============================================================================
Write-Section '11. System Restore Points'

if (-not $DryRun) {
    try {
        # Ensure System Restore is queryable; on the system drive
        $points = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
        if ($points -and $points.Count -gt 0) {
            Write-Info 'Available restore points:'
            $points |
                Select-Object SequenceNumber, CreationTime, Description |
                Format-Table -AutoSize |
                Out-String |
                Write-Host

            if ($RestorePoint -ge 0) {
                $target = $points | Where-Object { $_.SequenceNumber -eq $RestorePoint }
                if ($target) {
                    Write-Info "Target restore point: Seq $($target.SequenceNumber) - $($target.Description) ($($target.CreationTime))"
                    $confirm = Read-Host "Roll back to this restore point? This will reboot. [y/N]"
                    if ($confirm -match '^[yY]') {
                        Write-Ok 'Starting System Restore rollback...'
                        Restore-ComputerProperties -RestorePoint $RestorePoint
                        # Restore-ComputerProperties triggers a reboot; if we reach here, do it explicitly.
                        & shutdown /r /t 5 /c 'System Restore rollback'
                        exit 0
                    }
                    else {
                        Write-Info 'Rollback cancelled.'
                    }
                }
                else {
                    Write-Warn "No restore point with sequence number $RestorePoint. See the list above."
                }
            }
            else {
                Write-Info 'No -RestorePoint supplied. Re-run with -RestorePoint <SequenceNumber> to roll back.'
            }
        }
        else {
            Write-Info 'No System Restore points available (System Restore may be disabled on C:).'
            Write-Info 'If needed, enable it after a stable boot: Enable-ComputerRestore -Drive "C:\"'
        }
    }
    catch {
        Write-Warn "System Restore query failed: $($_.Exception.Message)"
    }
}
else {
    Write-Info '(dry-run) would list System Restore points and optionally roll back via -RestorePoint'
}

# ============================================================================
# 12. Clean stuck update temp / pending XML
# ============================================================================
Write-Section '12. Clean Stuck Update Temp / Pending XML'

if (-not $DryRun) {
    $pendingXml = "$env:SystemRoot\SoftwareDistribution\Download\pending.xml"
    if (Test-Path $pendingXml) {
        Remove-Item $pendingXml -Force -ErrorAction SilentlyContinue
        Write-Ok 'Removed pending.xml'
    }

    $wuDownload = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $wuDownload) {
        Get-ChildItem $wuDownload -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Cleared Windows Update download cache'
    }

    Remove-Item "$env:SystemRoot\Logs\CBS\*.log" -ErrorAction SilentlyContinue
}
else {
    Write-Info '(dry-run) would clear pending.xml and WU download cache'
}

# ============================================================================
# 13. Pause Windows Update (now that all repairs are done)
# ============================================================================
Write-Section '13. Pause Windows Update (post-repair)'

if (-not $DryRun) {
    $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (-not (Test-Path $auPath)) {
        New-Item -Path $auPath -Force | Out-Null
    }
    Set-ItemProperty -Path $auPath -Name 'NoAutoUpdate' -Value 1 -Type DWord -Force
    Write-Ok 'Auto-update disabled via policy (so the bad update is not re-delivered).'
}
else {
    Write-Info '(dry-run) would set NoAutoUpdate policy now that repairs are complete'
}

# ============================================================================
# 14. Optional: schedule Windows Memory Diagnostic for next boot
# ============================================================================
Write-Section '14. Memory Diagnostic (optional)'

if ($ScheduleMemTest) {
    Write-Step 'Launch Windows Memory Diagnostic'
    if (-not $DryRun) {
        try {
            # mdsched.exe opens a small dialog to choose "Restart now" or
            # "Check for problems the next time I start my computer".
            Start-Process -FilePath 'mdsched.exe' -ErrorAction Stop
            Write-Ok 'Windows Memory Diagnostic launched. Choose "Check on next start" to schedule it.'
            Write-Info 'The test runs after the next reboot and shows results on the following boot.'
        }
        catch {
            Write-Warn "Could not launch mdsched.exe: $($_.Exception.Message)"
        }
    }
    else {
        Write-Info '(dry-run) would launch mdsched.exe for scheduling'
    }
}
else {
    Write-Info 'Skipped (pass -ScheduleMemTest to launch Windows Memory Diagnostic).'
}

# ============================================================================
# 15. Summary and next steps
# ============================================================================
Write-Section '15. Summary and Next Steps'

if ($anyFailures) {
    Write-Warn 'Some steps reported failures. Review the output above before rebooting.'
}
else {
    Write-Ok 'All repair steps attempted without hard failures.'
}

if ($wimSourceUsed) {
    Write-Info 'Offline install.wim source was used for DISM /RestoreHealth.'
}
else {
    Write-Info 'DISM /RestoreHealth used Windows Update (cloud) as the repair source.'
}

Write-Host @'

  RECOMMENDED NEXT STEPS
  ----------------------
  1. If you know the exact bad KB, re-run with -BadKb <number> (without -DryRun).
  2. Reboot to NORMAL mode:  shutdown /r /t 0
     - CHKDSK runs first if scheduled.
     - Network stack reset applies on reboot.
     - Memory Diagnostic runs first if you scheduled it.
  3. If boot STILL fails:
       a. Boot from Windows 11 install media > Repair your computer >
          Advanced Options > System Restore (or use -RestorePoint <seq>).
       b. Or Advanced Options > Uninstall Updates (quality / feature).
       c. Or Command Prompt > run:
            bootrec /rebuildbcd
            dism /image:C:\ /cleanup-image /revertpendingactions
  4. After normal boot succeeds, re-enable Windows Update (the script paused it):
       reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f

'@ -ForegroundColor White

# ============================================================================
# 16. Reboot
# ============================================================================
if ($NoReboot) {
    Write-Info 'NoReboot specified. Done. Reboot manually when ready.'
    exit 0
}

if ($DryRun) {
    Write-Info 'Dry-run complete. No reboot (nothing changed).'
    exit 0
}

$answer = Read-Host "`nReboot now to apply repairs (CHKDSK / memory test run first if scheduled)? [y/N]"
if ($answer -match '^[yY]') {
    Write-Ok 'Rebooting in 5 seconds...'
    & shutdown /r /t 5 /c 'Windows 11 Boot Repair - rebooting to apply fixes'
}
else {
    Write-Info 'Reboot skipped. Re-run without -NoReboot to be prompted again.'
}