<#
.SYNOPSIS
  Blocks automatic Windows updates but keeps driver updates available on demand.

.DESCRIPTION
  -Disable      Apply policies: no automatic updates, feature-update version pinned,
                no auto-reboot, drivers still allowed through Windows Update.
  -Enable       Remove every policy this script set (back to Windows defaults).
  -CheckDrivers Search Windows Update for DRIVER updates only (add -Install to install them).

  Run from an elevated PowerShell:
    .\Manage-WindowsUpdate.ps1 -Disable
    .\Manage-WindowsUpdate.ps1 -CheckDrivers
    .\Manage-WindowsUpdate.ps1 -CheckDrivers -Install
    .\Manage-WindowsUpdate.ps1 -Enable

  Note: do NOT use Settings > "Check for updates" afterwards; it lists everything,
  not just drivers. Use -CheckDrivers instead.
#>
[CmdletBinding(DefaultParameterSetName = 'Disable')]
param(
    [Parameter(ParameterSetName = 'Disable')][switch]$Disable,
    [Parameter(ParameterSetName = 'Enable')][switch]$Enable,
    [Parameter(ParameterSetName = 'Drivers')][switch]$CheckDrivers,
    [Parameter(ParameterSetName = 'Drivers')][switch]$Install
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

$wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auKey = "$wuKey\AU"

function Set-Policy($path, $name, $value) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null
}

if ($CheckDrivers) {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2   # ssWindowsUpdate: query Microsoft directly, ignore WSUS
    Write-Host 'Searching for driver updates...'
    $found = $searcher.Search("IsInstalled=0 and Type='Driver'").Updates

    if ($found.Count -eq 0) { Write-Host 'No driver updates available.'; return }

    $found | ForEach-Object { Write-Host (" - {0}" -f $_.Title) }
    if (-not $Install) { Write-Host "`nRe-run with -Install to install them."; return }

    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $toInstall.Add($u) | Out-Null
    }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $toInstall; $dl.Download() | Out-Null
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $toInstall
    $result = $inst.Install()
    Write-Host "Install result code: $($result.ResultCode) (2 = succeeded). Reboot required: $($result.RebootRequired)"
    return
}

if ($Enable) {
    if (Test-Path $wuKey) { Remove-Item -Path $wuKey -Recurse -Force }
    Set-Service wuauserv -StartupType Manual
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue |
        Enable-ScheduledTask | Out-Null
    Write-Host 'Windows Update policies removed. Automatic updates are back to default.'
    return
}

# --- Disable (default) ---
# Drivers stay allowed through Windows Update (0 = do not exclude drivers).
Set-Policy $wuKey 'ExcludeWUDriversInQualityUpdate' 0

# No automatic updates at all; nothing downloads or installs unless asked.
Set-Policy $auKey 'NoAutoUpdate' 1
Set-Policy $auKey 'AUOptions' 1
Set-Policy $auKey 'NoAutoRebootWithLoggedOnUsers' 1

# Pin the current feature release so it never jumps to a new Windows version.
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$release = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
$product = if ([int]$cv.CurrentBuild -ge 22000) { 'Windows 11' } else { 'Windows 10' }
Set-Policy $wuKey 'TargetReleaseVersion' 1
New-ItemProperty -Path $wuKey -Name 'TargetReleaseVersionInfo' -Value $release -PropertyType String -Force | Out-Null
New-ItemProperty -Path $wuKey -Name 'ProductVersion' -Value $product -PropertyType String -Force | Out-Null

# Keep the service on demand (NOT disabled) so driver searches keep working.
Set-Service wuauserv -StartupType Manual

# Stop the background orchestrator from scanning/installing on its own.
Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'Schedule (Scan|Work|Wake)|USO_UxBroker|Reboot' } |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

Write-Host "Automatic Windows updates disabled (pinned to $product $release)."
Write-Host 'Look for drivers with:  .\Manage-WindowsUpdate.ps1 -CheckDrivers'
