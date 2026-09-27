<#
.SYNOPSIS
    Audits and repairs Windows Update policy configuration on Windows 10 / 11 and
    returns Windows Update to "policy not configured" (clean OEM/default) behaviour.

.DESCRIPTION
    Interactive console tool. Nothing is changed until you pick a repair option and
    confirm it. Every change is logged and every affected registry key is exported
    first.

    Design rule: Windows Update policies are "Not configured" when their policy
    registry values are ABSENT. The script therefore restores defaults by deleting
    individual, documented policy values. It never writes a guessed "default" value
    (for example it never writes NoAutoUpdate = 0) and never deletes whole registry
    trees.

    Sources used for policy locations and names (checked 2026-09):
      - Policy CSP - Update (ADMX mappings)
        https://learn.microsoft.com/windows/client-management/mdm/policy-csp-update
      - Manage additional Windows Update settings
        https://learn.microsoft.com/windows/deployment/update/waas-wu-settings
      - Manage device restarts after updates
        https://learn.microsoft.com/windows/deployment/update/waas-restart
      - ADMX_ICM Policy CSP (DisableWindowsUpdateAccess, DontSearchWindowsUpdate)
        https://learn.microsoft.com/windows/client-management/mdm/policy-csp-admx-icm
      - Delivery Optimization reference
        https://learn.microsoft.com/windows/deployment/do/waas-delivery-optimization-reference
    A few legacy values (Windows 10 1511-era deferrals, DisableOSUpgrade, Explorer
    NoWindowsUpdate) are kept in the catalog only so they can be detected and removed;
    they are never created.

.NOTES
    Version: 1.2.0 (the version is also part of the file name).

    Run from an elevated console:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-WindowsUpdatePolicies-v1.2.0.ps1

    Logs, audit reports and backups are written to:
        %ProgramData%\WindowsUpdatePolicyRepair\<yyyyMMdd-HHmmss>\

    Restoring a backup: menu option 8 returns every managed setting to exactly the
    state saved in a backup's snapshot.json (option 7 makes a backup on demand; one is
    also made automatically before every change). The .reg files remain available for
    a manual restore.
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

#region ---------------------------------------------------------------- Constants

$script:ToolName    = 'Windows Update Policy Repair'
$script:ToolVersion = '1.2.0'
$script:LogFile     = $null
$script:SessionDir  = $null
$script:BaseDir     = $null
$script:OSInfo      = $null
$script:Summary     = $null
$script:ReportLines = $null
$script:PolicyCatalog = $null
$script:CatalogIndex  = $null

# Registry locations (relative to their hive). Each is referenced by a comment where it
# is read or changed explaining why it matters to Windows Update.
$script:Paths = [pscustomobject]@{
    # Group Policy / registry policy home for Windows Update (WindowsUpdate.admx).
    WU                   = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    # "Configure Automatic Updates" and related AU policies.
    AU                   = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    # Delivery Optimization policies (download transport used by Windows Update).
    DO                   = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    # "Turn off Windows Update device driver searching" (ADMX_ICM).
    DriverSearch         = 'SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
    # Legacy "Remove links and access to Windows Update" (machine and user).
    ExplorerPol          = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    # User-scope "Remove access to use all Windows Update features".
    UserWU               = 'Software\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate'
    # Legacy Internet Communication Management location of DisableWindowsUpdateAccess.
    ICM                  = 'SYSTEM\Internet Communication Management\Internet Communication'
    # Settings-app pause state (not a policy - written when a user clicks "Pause").
    UXSettings           = 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    # Windows Update's internal copy of the evaluated pause state.
    UpdatePolicySettings = 'SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'
    # Policies delivered by MDM (Intune etc.) or provisioning packages.
    MdmUpdate            = 'SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    MdmDO                = 'SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization'
    # Per-enrollment MDM policy stores. PolicyManager rebuilds "current" from these, so
    # a value removed only from "current" comes back.
    MdmProviders         = 'SOFTWARE\Microsoft\PolicyManager\providers'
    # Windows Update's cached copy of Group Policy. A stale cache keeps "managed by your
    # organisation" showing after the policies themselves are gone; it is rebuilt from
    # current policy at the next refresh.
    GPCache              = 'SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache'
    # The policy state Windows Update actually evaluated (read-only, shown for diagnosis).
    PolicyState          = 'SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState'
    # A "Debugger" value here stops the named program from ever running (blocker technique).
    IFEO                 = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    Enrollments          = 'SOFTWARE\Microsoft\Enrollments'
    GpoList              = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List'
    RebootRequired       = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    CbsRebootPending     = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    WinHttp              = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
}

$script:Areas = [pscustomobject]@{
    Access   = 'Access restrictions'
    AU       = 'Automatic Updates configuration'
    Feature  = 'Feature update deferral'
    Quality  = 'Quality update deferral'
    Pause    = 'Pause policies'
    Target   = 'Target release version'
    WUfB     = 'Windows Update for Business (other)'
    WSUS     = 'Intranet update service (WSUS / ConfigMgr)'
    Driver   = 'Driver updates'
    Restart  = 'Restart, deadline, active hours and notifications'
    Legacy   = 'Legacy / deprecated policies'
    Unknown  = 'Unrecognized values in Windows Update policy keys'
    User     = 'User-level Windows Update policies'
    DO       = 'Delivery Optimization policies'
    LocalGpo = 'Local Group Policy (Registry.pol)'
    Mdm      = 'MDM / Intune policies (PolicyManager)'
    Cache    = 'Cached Group Policy (Windows Update GPCache)'
    Effective = 'Effective policy state (as Windows Update sees it, read-only)'
    Ifeo     = 'Blocked update programs (Image File Execution Options)'
    Firewall = 'Firewall rules'
    UxPause  = 'Pause state (Settings app)'
    Services = 'Services'
    Tasks    = 'Scheduled tasks'
    Hosts    = 'Hosts file'
    Network  = 'Network (WinHTTP proxy)'
    Errors   = 'Read errors'
}

# Windows Update endpoints (from "Windows Update endpoints" documentation). A hosts-file
# entry for any of these (or a sub-domain) prevents Windows Update from connecting.
$script:WUHostSuffixes = @(
    'windowsupdate.com', 'windowsupdate.microsoft.com', 'update.microsoft.com',
    'delivery.mp.microsoft.com', 'dsp.mp.microsoft.com', 'emdl.ws.microsoft.com'
)

# Windows Update programs that blocker tools disable via an IFEO "Debugger" value or a
# firewall rule. None of them has a Debugger value on a clean install.
$script:WUExecutables = @(
    'usoclient.exe', 'mousocoreworker.exe', 'waasmedicagent.exe', 'sihclient.exe', 'wuauclt.exe',
    'musnotification.exe', 'musnotificationux.exe', 'tiworker.exe', 'trustedinstaller.exe'
)

# Scheduled tasks that start Windows Update scans. Both are enabled on a clean install;
# update-blocking tools commonly disable them.
$script:TaskDefs = @(
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\';       Name = 'Scheduled Start' }
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\';  Name = 'Schedule Scan' }
)

# Well-known Windows Update client error codes, used to explain a failed test scan.
$script:WUErrorHints = @{
    '0x8024002E' = 'Windows Update access is disabled by policy.'
    '0x8024500C' = 'Connection to Windows Update is not allowed by policy.'
    '0x80240438' = 'Windows Update endpoint unreachable (policy, firewall, hosts file or proxy).'
    '0x8024402C' = 'Update server name could not be resolved (proxy, DNS or WSUS address).'
    '0x80244022' = 'Update server returned HTTP 503 (service unavailable).'
    '0x80072EE2' = 'Connection to the update server timed out.'
    '0x80072EFD' = 'Could not connect to the update server.'
}

#endregion

#region ---------------------------------------------------------------- Logging and console helpers

function Write-Log {
    <# Writes a timestamped line to the session log and (unless -NoConsole) to the console. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'CHANGE', 'DEBUG')][string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $line = '{0} [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Host ('  [log write failed: {0}]' -f $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    if ($NoConsole -or $Level -eq 'DEBUG') { return }
    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'CHANGE'  { 'Cyan' }
        default   { 'Gray' }
    }
    $prefix = switch ($Level) {
        'WARN'    { '[!] ' }
        'ERROR'   { '[x] ' }
        'SUCCESS' { '[+] ' }
        'CHANGE'  { '[~] ' }
        default   { '    ' }
    }
    Write-Host ('  {0}{1}' -f $prefix, $Message) -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('-' * 72) -ForegroundColor DarkCyan
    Write-Host (' {0}' -f $Title) -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkCyan
    Write-Log -Message "=== $Title ===" -NoConsole
}

function Out-Report {
    <# Prints an audit line and keeps a copy for the saved audit report. #>
    param([AllowEmptyString()][string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($null -ne $script:ReportLines) { $script:ReportLines.Add($Text) }
}

function Read-YesNo {
    param([string]$Prompt, [ValidateSet('Y', 'N')][string]$Default = 'N')
    $suffix = if ($Default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host ('{0} {1}' -f $Prompt, $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
        }
        Write-Host '  Please answer Y or N.' -ForegroundColor Yellow
    }
}

function New-OperationSummary {
    param([string]$Title)
    $script:Summary = [pscustomobject]@{
        Title            = $Title
        PoliciesRemoved  = 0
        PoliciesReset    = 0
        ServicesRepaired = 0
        Restored         = 0
        ComponentsReset  = 'No'
        BackupDir        = $null
        Cancelled        = $false
        Failures         = New-Object System.Collections.Generic.List[object]
        Warnings         = New-Object System.Collections.Generic.List[string]
        ScanResult       = $null
    }
}

function Add-Failure {
    <# Records something that could not be changed; shown in the end-of-operation summary. #>
    param([string]$Target, [string]$Reason)
    if ($script:Summary) {
        # The same item can be reported by several steps of option 6; list it once.
        if (@($script:Summary.Failures | Where-Object { $_.Target -eq $Target -and $_.Reason -eq $Reason }).Count -gt 0) { return }
        $script:Summary.Failures.Add([pscustomobject]@{ Target = $Target; Reason = $Reason })
    }
    Write-Log -Message ('Could not modify {0} - {1}' -f $Target, $Reason) -Level ERROR
}

function Add-SummaryWarning {
    param([string]$Message)
    if ($script:Summary) { $script:Summary.Warnings.Add($Message) }
    Write-Log -Message $Message -Level WARN
}

#endregion

#region ---------------------------------------------------------------- Generic value helpers

function Format-RegValue {
    param($Value)
    if ($null -eq $Value) { return '(not set)' }
    if ($Value -is [byte[]]) {
        if ($Value.Length -eq 0) { return '(empty binary)' }
        $hex = ($Value | Select-Object -First 24 | ForEach-Object { $_.ToString('X2') }) -join ' '
        if ($Value.Length -gt 24) { $hex += ' ...' }
        return $hex
    }
    if ($Value -is [string[]]) { return ($Value -join '; ') }
    if ($Value -is [string] -and $Value.Length -eq 0) { return '(empty string)' }
    return [string]$Value
}

function ConvertTo-IntOrNull {
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = 0L
    if ([long]::TryParse(([string]$Value).Trim(), [ref]$n)) { return $n }
    return $null
}

function ConvertTo-DateOrNull {
    param($Value)
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    $d = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'
    if ([datetime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
    return $null
}

function Test-PauseActive {
    <# A policy pause start date is active for at most 35 days (documented maximum). #>
    param($Value, [int]$MaxDays = 35)
    $start = ConvertTo-DateOrNull $Value
    if ($null -eq $start) { return $false }
    return ($start.AddDays($MaxDays) -gt (Get-Date).ToUniversalTime())
}

#endregion

#region ---------------------------------------------------------------- Registry helpers

function Open-RegistryKey {
    <# Opens 'HKLM\...' or 'HKU\<sid>\...' in the native (64-bit) view. Returns $null if absent. #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Writable)
    $parts = $Path -split '\\', 2
    $base = switch ($parts[0].ToUpperInvariant()) {
        'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKU'  { [Microsoft.Win32.Registry]::Users }
        default { throw "Unsupported registry hive '$($parts[0])'." }
    }
    if ($parts.Count -lt 2 -or -not $parts[1]) { return $base }
    return $base.OpenSubKey($parts[1], [bool]$Writable)
}

function Test-RegistryKeyExists {
    param([string]$Path)
    try {
        $k = Open-RegistryKey -Path $Path
        if ($k) { $k.Close(); return $true }
    }
    catch {
        Write-Log -Message ('Cannot open {0}: {1}' -f $Path, $_.Exception.Message) -Level WARN -NoConsole
        return $true   # exists but unreadable - let the caller's export report the error
    }
    return $false
}

function Get-RegistryValueSet {
    <# Returns every value of a key as objects (Path, Name, Value, Kind). Throws on access errors. #>
    param([Parameter(Mandatory)][string]$Path)
    $key = Open-RegistryKey -Path $Path
    if ($null -eq $key) { return }
    try {
        foreach ($name in $key.GetValueNames()) {
            [pscustomobject]@{
                Path  = $Path
                Name  = $name
                Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Kind  = $key.GetValueKind($name)
            }
        }
    }
    finally { $key.Close() }
}

function Get-FailureReason {
    param($ErrorRecord, [bool]$OrgManaged = $false)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $denied = ($ex -is [System.UnauthorizedAccessException]) -or ($ex -is [System.Security.SecurityException]) -or
              ($ex.Message -match 'denied|0x80070005')
    if ($denied -and $OrgManaged) { return 'Managed by organization / Access denied' }
    if ($denied) { return 'Access denied' }
    return $ex.Message
}

function Remove-RegistryPolicyValue {
    <#
        Deletes ONE registry value. Deleting a policy value is how Windows represents
        "Not configured"; no replacement value is ever written.
        -Counter decides which summary counter is incremented (Removed | Reset | None).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Reason = '',
        [ValidateSet('Removed', 'Reset', 'Restored', 'None')][string]$Counter = 'Removed',
        [bool]$OrgManaged = $false
    )
    $key = $null
    try {
        $key = Open-RegistryKey -Path $Path -Writable
        if ($null -eq $key) {
            Write-Log -Message ('Already absent: {0}\{1}' -f $Path, $Name) -Level DEBUG
            return
        }
        if (-not ($key.GetValueNames() -contains $Name)) {
            Write-Log -Message ('Already absent: {0}\{1}' -f $Path, $Name) -Level DEBUG
            return
        }
        $old = Format-RegValue ($key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
        $key.DeleteValue($Name, $true)
        Write-Log -Message ('Removed {0}\{1} (was: {2}) {3}' -f $Path, $Name, $old, $Reason) -Level CHANGE
        switch ($Counter) {
            'Removed' { $script:Summary.PoliciesRemoved++ }
            'Reset'   { $script:Summary.PoliciesReset++ }
            'Restored' { $script:Summary.Restored++ }
        }
    }
    catch {
        Add-Failure -Target ('{0}\{1}' -f $Path, $Name) -Reason (Get-FailureReason $_ $OrgManaged)
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Remove-EmptyRegistryKey {
    <# Deletes a policy key only if it has no values and no sub-keys left (never recursive). #>
    param([string]$Path)
    try {
        $k = Open-RegistryKey -Path $Path
        if ($null -eq $k) { return }
        $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
        $k.Close()
        if (-not $empty) { return }
        $idx = $Path.LastIndexOf('\')
        $parent = Open-RegistryKey -Path $Path.Substring(0, $idx) -Writable
        if ($null -eq $parent) { return }
        try { $parent.DeleteSubKey($Path.Substring($idx + 1), $false) } finally { $parent.Close() }
        Write-Log -Message ('Removed empty policy key {0}' -f $Path) -Level CHANGE
    }
    catch {
        Add-Failure -Target $Path -Reason (Get-FailureReason $_)
    }
}

function Get-LoadedUserSids {
    <# User policies live in each user's hive; only hives currently loaded (signed-in users) are reachable. #>
    try {
        Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
            ForEach-Object { $_.PSChildName }
    }
    catch {
        Write-Log -Message ('Could not enumerate loaded user hives: {0}' -f $_.Exception.Message) -Level WARN
    }
}

#endregion

#region ---------------------------------------------------------------- Policy catalog

function Initialize-PolicyCatalog {
    <#
        Documented Windows Update policy values. Tier:
          Standard - core Windows Update policies (options 3 and 5)
          Extended - related locations handled only by option 5 (unless blocking)
        Eval returns Block | Restrict | Custom for the value that is present.
    #>
    $p = $script:Paths
    $a = $script:Areas
    $ev = @{
        Block     = { param($v) if ([string]$v -eq '1') { 'Block' } else { 'Custom' } }
        Restrict  = { param($v) if ([string]$v -eq '1') { 'Restrict' } else { 'Custom' } }
        Days      = { param($v) if ((ConvertTo-IntOrNull $v) -gt 0) { 'Restrict' } else { 'Custom' } }
        Pause     = { param($v) if (Test-PauseActive -Value $v) { 'Block' } else { 'Custom' } }
        Always    = { param($v) 'Restrict' }
        Custom    = { param($v) 'Custom' }
        AUOptions = { param($v) switch ([string]$v) { '1' { 'Block' } '2' { 'Restrict' } default { 'Custom' } } }
        DOMode    = { param($v) if ([string]$v -eq '100') { 'Restrict' } else { 'Custom' } }
        DOPct     = { param($v) $n = ConvertTo-IntOrNull $v; if ($null -ne $n -and $n -gt 0 -and $n -lt 100) { 'Restrict' } else { 'Custom' } }
    }

    $rows = @(
        # ---- Access restrictions (HKLM\...\WindowsUpdate)
        @('Machine', $p.WU, 'DisableWindowsUpdateAccess', $a.Access, 'Standard', 'Block', 'Turn off access to all Windows Update features (blocks scanning and automatic updates).'),
        @('Machine', $p.WU, 'SetDisableUXWUAccess', $a.Access, 'Standard', 'Block', 'Remove access to use all Windows Update features (hides "Check for updates").'),
        @('Machine', $p.WU, 'SetDisablePauseUXAccess', $a.Access, 'Standard', 'Custom', 'Remove access to "Pause updates".'),
        @('Machine', $p.WU, 'ElevateNonAdmins', $a.Access, 'Standard', 'Custom', 'Allow non-administrators to receive update notifications (legacy).'),

        # ---- WSUS / intranet update service
        @('Machine', $p.WU, 'WUServer', $a.WSUS, 'Standard', 'Custom', 'Intranet update service used for detection.'),
        @('Machine', $p.WU, 'WUStatusServer', $a.WSUS, 'Standard', 'Custom', 'Intranet statistics (reporting) server.'),
        @('Machine', $p.WU, 'UpdateServiceUrlAlternate', $a.WSUS, 'Standard', 'Custom', 'Alternate download server.'),
        @('Machine', $p.WU, 'FillEmptyContentUrls', $a.WSUS, 'Standard', 'Custom', 'Download files with no URL in metadata from the alternate server.'),
        @('Machine', $p.WU, 'DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection', $a.WSUS, 'Standard', 'Custom', 'Do not enforce TLS certificate pinning for intranet detection.'),
        @('Machine', $p.WU, 'SetProxyBehaviorForUpdateDetection', $a.WSUS, 'Standard', 'Custom', 'Proxy behaviour for intranet update detection.'),
        @('Machine', $p.WU, 'DoNotConnectToWindowsUpdateInternetLocations', $a.WSUS, 'Standard', 'Always', 'Do not connect to any Windows Update Internet locations.'),
        @('Machine', $p.WU, 'TargetGroupEnabled', $a.WSUS, 'Standard', 'Custom', 'Enable client-side targeting.'),
        @('Machine', $p.WU, 'TargetGroup', $a.WSUS, 'Standard', 'Custom', 'Client-side targeting group name.'),
        @('Machine', $p.WU, 'AcceptTrustedPublisherCerts', $a.WSUS, 'Standard', 'Custom', 'Allow signed updates from an intranet Microsoft update service location.'),
        @('Machine', $p.WU, 'DisableDualScan', $a.WSUS, 'Standard', 'Custom', 'Do not allow update deferral policies to cause scans against Windows Update.'),
        @('Machine', $p.WU, 'SetPolicyDrivenUpdateSourceForFeatureUpdates', $a.WSUS, 'Standard', 'Custom', 'Feature update source (1 = intranet server, 0 = Windows Update).'),
        @('Machine', $p.WU, 'SetPolicyDrivenUpdateSourceForQualityUpdates', $a.WSUS, 'Standard', 'Custom', 'Quality update source (1 = intranet server, 0 = Windows Update).'),
        @('Machine', $p.WU, 'SetPolicyDrivenUpdateSourceForDriverUpdates', $a.WSUS, 'Standard', 'Custom', 'Driver update source (1 = intranet server, 0 = Windows Update).'),
        @('Machine', $p.WU, 'SetPolicyDrivenUpdateSourceForOtherUpdates', $a.WSUS, 'Standard', 'Custom', 'Other update source (1 = intranet server, 0 = Windows Update).'),

        # ---- Windows Update for Business: feature / quality deferral
        @('Machine', $p.WU, 'DeferFeatureUpdates', $a.Feature, 'Standard', 'Restrict', 'Feature update deferral enabled.'),
        @('Machine', $p.WU, 'DeferFeatureUpdatesPeriodInDays', $a.Feature, 'Standard', 'Days', 'Days to defer feature updates.'),
        @('Machine', $p.WU, 'BranchReadinessLevel', $a.Feature, 'Standard', 'Custom', 'Channel / branch readiness level for feature updates.'),
        @('Machine', $p.WU, 'DeferQualityUpdates', $a.Quality, 'Standard', 'Restrict', 'Quality update deferral enabled.'),
        @('Machine', $p.WU, 'DeferQualityUpdatesPeriodInDays', $a.Quality, 'Standard', 'Days', 'Days to defer quality (monthly) updates.'),

        # ---- Pause policies
        @('Machine', $p.WU, 'PauseFeatureUpdatesStartTime', $a.Pause, 'Standard', 'Pause', 'Feature updates paused by policy from this date (35 days).'),
        @('Machine', $p.WU, 'PauseQualityUpdatesStartTime', $a.Pause, 'Standard', 'Pause', 'Quality updates paused by policy from this date (35 days).'),
        @('Machine', $p.WU, 'PauseFeatureUpdates', $a.Pause, 'Standard', 'Block', 'Pause feature updates.'),
        @('Machine', $p.WU, 'PauseQualityUpdates', $a.Pause, 'Standard', 'Block', 'Pause quality updates.'),
        @('Machine', $p.WU, 'SetMaxPauseDays', $a.Pause, 'Standard', 'Custom', 'Maximum number of days a user can pause updates.'),

        # ---- Target release version
        @('Machine', $p.WU, 'TargetReleaseVersion', $a.Target, 'Standard', 'Restrict', 'Pin the device to a specific feature update version.'),
        @('Machine', $p.WU, 'TargetReleaseVersionInfo', $a.Target, 'Standard', 'Always', 'Pinned feature update version (e.g. 23H2).'),
        @('Machine', $p.WU, 'ProductVersion', $a.Target, 'Standard', 'Always', 'Pinned product (e.g. "Windows 10" blocks the move to Windows 11).'),

        # ---- Other Windows Update for Business
        @('Machine', $p.WU, 'ManagePreviewBuilds', $a.WUfB, 'Standard', 'Custom', 'Manage preview (Insider) builds.'),
        @('Machine', $p.WU, 'ManagePreviewBuildsPolicyValue', $a.WUfB, 'Standard', 'Custom', 'Preview build policy value.'),
        @('Machine', $p.WU, 'DisableWUfBSafeguards', $a.WUfB, 'Standard', 'Custom', 'Disable safeguard holds for feature updates.'),
        @('Machine', $p.WU, 'AllowTemporaryEnterpriseFeatureControl', $a.WUfB, 'Standard', 'Custom', 'Enable features introduced via servicing that are off by default.'),
        @('Machine', $p.WU, 'SetAllowOptionalContent', $a.WUfB, 'Standard', 'Custom', 'Enable optional updates.'),
        @('Machine', $p.WU, 'AllowOptionalContent', $a.WUfB, 'Standard', 'Custom', 'Optional updates behaviour.'),
        @('Machine', $p.WU, 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork', $a.WUfB, 'Standard', 'Custom', 'Allow updates to download over metered connections.'),

        # ---- Drivers
        @('Machine', $p.WU, 'ExcludeWUDriversInQualityUpdate', $a.Driver, 'Standard', 'Restrict', 'Do not include drivers with Windows Updates.'),
        @('Machine', $p.DriverSearch, 'DontSearchWindowsUpdate', $a.Driver, 'Extended', 'Restrict', 'Turn off Windows Update device driver searching.'),

        # ---- Restart, deadlines, active hours, notifications
        @('Machine', $p.WU, 'SetComplianceDeadline', $a.Restart, 'Standard', 'Custom', 'Specify deadlines for automatic updates and restarts.'),
        @('Machine', $p.WU, 'ConfigureDeadlineForQualityUpdates', $a.Restart, 'Standard', 'Custom', 'Quality update deadline (days).'),
        @('Machine', $p.WU, 'ConfigureDeadlineForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Feature update deadline (days).'),
        @('Machine', $p.WU, 'ConfigureDeadlineGracePeriod', $a.Restart, 'Standard', 'Custom', 'Deadline grace period.'),
        @('Machine', $p.WU, 'ConfigureDeadlineGracePeriodForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Feature update deadline grace period.'),
        @('Machine', $p.WU, 'ConfigureDeadlineNoAutoReboot', $a.Restart, 'Standard', 'Custom', "Don't auto-restart until end of grace period."),
        @('Machine', $p.WU, 'ConfigureDeadlineNoAutoRebootForFeatureUpdates', $a.Restart, 'Standard', 'Custom', "Don't auto-restart until end of grace period (feature)."),
        @('Machine', $p.WU, 'ConfigureDeadlineNoAutoRebootForQualityUpdates', $a.Restart, 'Standard', 'Custom', "Don't auto-restart until end of grace period (quality)."),
        @('Machine', $p.WU, 'SetActiveHours', $a.Restart, 'Standard', 'Custom', 'Turn off auto-restart during active hours.'),
        @('Machine', $p.WU, 'ActiveHoursStart', $a.Restart, 'Standard', 'Custom', 'Active hours start.'),
        @('Machine', $p.WU, 'ActiveHoursEnd', $a.Restart, 'Standard', 'Custom', 'Active hours end.'),
        @('Machine', $p.WU, 'SetActiveHoursMaxRange', $a.Restart, 'Standard', 'Custom', 'Specify active hours range for auto-restarts.'),
        @('Machine', $p.WU, 'ActiveHoursMaxRange', $a.Restart, 'Standard', 'Custom', 'Maximum active hours range.'),
        @('Machine', $p.WU, 'SetAutoRestartNotificationConfig', $a.Restart, 'Standard', 'Custom', 'Configure auto-restart reminder notifications.'),
        @('Machine', $p.WU, 'AutoRestartNotificationSchedule', $a.Restart, 'Standard', 'Custom', 'Auto-restart reminder period.'),
        @('Machine', $p.WU, 'SetAutoRestartRequiredNotificationDismissal', $a.Restart, 'Standard', 'Custom', 'Configure auto-restart required notification.'),
        @('Machine', $p.WU, 'AutoRestartRequiredNotificationDismissal', $a.Restart, 'Standard', 'Custom', 'Auto-restart notification dismissal method.'),
        @('Machine', $p.WU, 'SetAutoRestartNotificationDisable', $a.Restart, 'Standard', 'Custom', 'Turn off auto-restart notifications.'),
        @('Machine', $p.WU, 'SetRestartWarningSchd', $a.Restart, 'Standard', 'Custom', 'Configure auto-restart warning schedule.'),
        @('Machine', $p.WU, 'ScheduleRestartWarning', $a.Restart, 'Standard', 'Custom', 'Restart warning (hours).'),
        @('Machine', $p.WU, 'ScheduleImminentRestartWarning', $a.Restart, 'Standard', 'Custom', 'Imminent restart warning (minutes).'),
        @('Machine', $p.WU, 'SetUpdateNotificationLevel', $a.Restart, 'Standard', 'Custom', 'Display options for update notifications.'),
        @('Machine', $p.WU, 'UpdateNotificationLevel', $a.Restart, 'Standard', 'Custom', 'Update notification level.'),
        @('Machine', $p.WU, 'NoUpdateNotificationsDuringActiveHours', $a.Restart, 'Standard', 'Custom', 'Apply notification level only during active hours.'),
        @('Machine', $p.WU, 'SetEDURestart', $a.Restart, 'Standard', 'Custom', 'Update power policy for cart restarts (education).'),
        @('Machine', $p.WU, 'AUPowerManagement', $a.Restart, 'Standard', 'Custom', 'Enable Windows Update Power Management to wake the system.'),
        @('Machine', $p.WU, 'SetAutoRestartDeadline', $a.Restart, 'Standard', 'Custom', 'Specify deadline before auto-restart (legacy).'),
        @('Machine', $p.WU, 'AutoRestartDeadlinePeriodInDays', $a.Restart, 'Standard', 'Custom', 'Auto-restart deadline for quality updates (legacy).'),
        @('Machine', $p.WU, 'AutoRestartDeadlinePeriodInDaysForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Auto-restart deadline for feature updates (legacy).'),
        @('Machine', $p.WU, 'SetEngagedRestartTransitionSchedule', $a.Restart, 'Standard', 'Custom', 'Specify engaged restart transition and notification schedule (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartTransitionSchedule', $a.Restart, 'Standard', 'Custom', 'Engaged restart transition (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartSnoozeSchedule', $a.Restart, 'Standard', 'Custom', 'Engaged restart snooze (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartDeadline', $a.Restart, 'Standard', 'Custom', 'Engaged restart deadline (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartTransitionScheduleForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Engaged restart transition, feature updates (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartSnoozeScheduleForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Engaged restart snooze, feature updates (legacy).'),
        @('Machine', $p.WU, 'EngagedRestartDeadlineForFeatureUpdates', $a.Restart, 'Standard', 'Custom', 'Engaged restart deadline, feature updates (legacy).'),

        # ---- Legacy blocking values (detected and removed, never created)
        @('Machine', $p.WU, 'DisableOSUpgrade', $a.Legacy, 'Standard', 'Restrict', 'Turn off the upgrade to the latest version of Windows through Windows Update (legacy).'),
        @('Machine', $p.WU, 'DeferUpgrade', $a.Legacy, 'Standard', 'Restrict', 'Defer upgrades and updates (Windows 10 1511, superseded).'),
        @('Machine', $p.WU, 'DeferUpgradePeriod', $a.Legacy, 'Standard', 'Days', 'Months to defer upgrades (superseded).'),
        @('Machine', $p.WU, 'DeferUpdatePeriod', $a.Legacy, 'Standard', 'Days', 'Weeks to defer updates (superseded).'),
        @('Machine', $p.WU, 'PauseDeferrals', $a.Legacy, 'Standard', 'Block', 'Pause upgrades and updates (superseded).'),
        @('Machine', $p.ExplorerPol, 'NoWindowsUpdate', $a.Legacy, 'Extended', 'Block', 'Remove links and access to Windows Update (legacy, machine).'),
        @('Machine', $p.ICM, 'DisableWindowsUpdateAccess', $a.Legacy, 'Extended', 'Block', 'Turn off access to all Windows Update features (legacy location).'),

        # ---- Automatic Updates (HKLM\...\WindowsUpdate\AU)
        @('Machine', $p.AU, 'NoAutoUpdate', $a.AU, 'Standard', 'Block', 'Configure Automatic Updates: 1 = automatic updates disabled.'),
        @('Machine', $p.AU, 'AUOptions', $a.AU, 'Standard', 'AUOptions', 'Automatic update behaviour (2 = notify before download, 3 = auto download, 4 = scheduled install, 7 = notify install).'),
        @('Machine', $p.AU, 'ScheduledInstallDay', $a.AU, 'Standard', 'Custom', 'Scheduled install day.'),
        @('Machine', $p.AU, 'ScheduledInstallTime', $a.AU, 'Standard', 'Custom', 'Scheduled install time.'),
        @('Machine', $p.AU, 'ScheduledInstallEveryWeek', $a.AU, 'Standard', 'Custom', 'Scheduled install every week.'),
        @('Machine', $p.AU, 'ScheduledInstallFirstWeek', $a.AU, 'Standard', 'Custom', 'Scheduled install first week.'),
        @('Machine', $p.AU, 'ScheduledInstallSecondWeek', $a.AU, 'Standard', 'Custom', 'Scheduled install second week.'),
        @('Machine', $p.AU, 'ScheduledInstallThirdWeek', $a.AU, 'Standard', 'Custom', 'Scheduled install third week.'),
        @('Machine', $p.AU, 'ScheduledInstallFourthWeek', $a.AU, 'Standard', 'Custom', 'Scheduled install fourth week.'),
        @('Machine', $p.AU, 'AllowMUUpdateService', $a.AU, 'Standard', 'Custom', 'Install updates for other Microsoft products (Microsoft Update).'),
        @('Machine', $p.AU, 'AutoInstallMinorUpdates', $a.AU, 'Standard', 'Custom', 'Allow automatic updates immediate installation.'),
        @('Machine', $p.AU, 'UseWUServer', $a.WSUS, 'Standard', 'Custom', 'Use the intranet update server defined in WUServer.'),
        @('Machine', $p.AU, 'DetectionFrequencyEnabled', $a.AU, 'Standard', 'Custom', 'Automatic Updates detection frequency enabled.'),
        @('Machine', $p.AU, 'DetectionFrequency', $a.AU, 'Standard', 'Custom', 'Detection frequency (hours).'),
        @('Machine', $p.AU, 'NoAutoRebootWithLoggedOnUsers', $a.Restart, 'Standard', 'Custom', 'No auto-restart with logged on users.'),
        @('Machine', $p.AU, 'RebootRelaunchTimeoutEnabled', $a.Restart, 'Standard', 'Custom', 'Re-prompt for restart with scheduled installations.'),
        @('Machine', $p.AU, 'RebootRelaunchTimeout', $a.Restart, 'Standard', 'Custom', 'Re-prompt interval (minutes).'),
        @('Machine', $p.AU, 'RebootWarningTimeoutEnabled', $a.Restart, 'Standard', 'Custom', 'Delay restart for scheduled installations.'),
        @('Machine', $p.AU, 'RebootWarningTimeout', $a.Restart, 'Standard', 'Custom', 'Restart delay (minutes).'),
        @('Machine', $p.AU, 'RescheduleWaitTimeEnabled', $a.AU, 'Standard', 'Custom', 'Reschedule automatic updates scheduled installations.'),
        @('Machine', $p.AU, 'RescheduleWaitTime', $a.AU, 'Standard', 'Custom', 'Reschedule wait time (minutes).'),
        @('Machine', $p.AU, 'NoAUShutdownOption', $a.AU, 'Standard', 'Custom', 'Do not display "Install Updates and Shut Down".'),
        @('Machine', $p.AU, 'NoAUAsDefaultShutdownOption', $a.AU, 'Standard', 'Custom', 'Do not adjust default shutdown option.'),
        @('Machine', $p.AU, 'IncludeRecommendedUpdates', $a.AU, 'Standard', 'Custom', 'Turn on recommended updates via Automatic Updates.'),
        @('Machine', $p.AU, 'EnableFeaturedSoftware', $a.AU, 'Standard', 'Custom', 'Turn on Software Notifications (legacy).'),
        @('Machine', $p.AU, 'AlwaysAutoRebootAtScheduledTime', $a.Restart, 'Standard', 'Custom', 'Always automatically restart at the scheduled time.'),
        @('Machine', $p.AU, 'AlwaysAutoRebootAtScheduledTimeMinutes', $a.Restart, 'Standard', 'Custom', 'Restart timer (minutes).'),
        @('Machine', $p.AU, 'AutomaticMaintenanceEnabled', $a.AU, 'Standard', 'Custom', 'Install during automatic maintenance.'),
        @('Machine', $p.AU, 'UseUpdateClassPolicySource', $a.WSUS, 'Standard', 'Custom', 'Use per-class update source policies.'),

        # ---- User-level policies (each loaded HKU hive)
        @('User', $p.UserWU, 'DisableWindowsUpdateAccess', $a.User, 'Extended', 'Block', 'Remove access to use all Windows Update features (user).'),
        @('User', $p.ExplorerPol, 'NoWindowsUpdate', $a.User, 'Extended', 'Block', 'Remove links and access to Windows Update (user).'),

        # ---- Delivery Optimization values that directly affect Windows Update downloads.
        # Peer-caching settings (group IDs, cache size, upload limits) are NOT listed and never touched.
        @('Machine', $p.DO, 'DODownloadMode', $a.DO, 'Extended', 'DOMode', 'Download mode (100 = Bypass, deprecated; 99 = Simple; 0-3 = peering modes).'),
        @('Machine', $p.DO, 'DOMaxDownloadBandwidth', $a.DO, 'Extended', 'Days', 'Maximum download bandwidth KB/s (deprecated).'),
        @('Machine', $p.DO, 'DOPercentageMaxDownloadBandwidth', $a.DO, 'Extended', 'DOPct', 'Maximum download bandwidth percentage (deprecated).'),
        @('Machine', $p.DO, 'DOMaxBackgroundDownloadBandwidth', $a.DO, 'Extended', 'Days', 'Maximum background download bandwidth (KB/s).'),
        @('Machine', $p.DO, 'DOMaxForegroundDownloadBandwidth', $a.DO, 'Extended', 'Days', 'Maximum foreground download bandwidth (KB/s).'),
        @('Machine', $p.DO, 'DOPercentageMaxBackgroundBandwidth', $a.DO, 'Extended', 'DOPct', 'Maximum background download bandwidth (percentage).'),
        @('Machine', $p.DO, 'DOPercentageMaxForegroundBandwidth', $a.DO, 'Extended', 'DOPct', 'Maximum foreground download bandwidth (percentage).'),
        @('Machine', $p.DO, 'DOSetHoursToLimitBackgroundDownloadBandwidth', $a.DO, 'Extended', 'Always', 'Business hours to limit background download bandwidth.'),
        @('Machine', $p.DO, 'DOSetHoursToLimitForegroundDownloadBandwidth', $a.DO, 'Extended', 'Always', 'Business hours to limit foreground download bandwidth.'),
        @('Machine', $p.DO, 'DOCacheHost', $a.DO, 'Extended', 'Custom', 'Connected / Microsoft cache server host names.'),
        @('Machine', $p.DO, 'DOCacheHostSource', $a.DO, 'Extended', 'Custom', 'Cache server host name source.'),
        @('Machine', $p.DO, 'DODelayBackgroundDownloadFromHttp', $a.DO, 'Extended', 'Custom', 'Delay background HTTP download (seconds).'),
        @('Machine', $p.DO, 'DODelayForegroundDownloadFromHttp', $a.DO, 'Extended', 'Custom', 'Delay foreground HTTP download (seconds).'),
        @('Machine', $p.DO, 'DODelayCacheServerFallbackBackground', $a.DO, 'Extended', 'Custom', 'Delay background cache-server fallback.'),
        @('Machine', $p.DO, 'DODelayCacheServerFallbackForeground', $a.DO, 'Extended', 'Custom', 'Delay foreground cache-server fallback.'),
        @('Machine', $p.DO, 'DODisallowCacheServerDownloadsOnVPN', $a.DO, 'Extended', 'Custom', 'Disallow cache server downloads on VPN.'),
        @('Machine', $p.DO, 'DOMinBackgroundQos', $a.DO, 'Extended', 'Custom', 'Minimum background QoS (KB/s).')
    )

    $script:PolicyCatalog = New-Object System.Collections.Generic.List[object]
    $script:CatalogIndex  = @{}
    foreach ($r in $rows) {
        $def = [pscustomobject]@{
            Scope = $r[0]; Key = $r[1]; Name = $r[2]; Area = $r[3]; Tier = $r[4]; Eval = $ev[$r[5]]; Desc = $r[6]
        }
        $script:PolicyCatalog.Add($def)
        $script:CatalogIndex[('{0}|{1}|{2}' -f $def.Scope, $def.Key, $def.Name).ToLowerInvariant()] = $def
    }
}

function Find-PolicyDef {
    param([string]$Scope, [string]$Key, [string]$Name)
    $id = ('{0}|{1}|{2}' -f $Scope, $Key.TrimEnd('\'), $Name).ToLowerInvariant()
    return $script:CatalogIndex[$id]
}

function Test-IsSweepKey {
    <# Keys that contain ONLY Windows Update policy - option 5 may remove unrecognised values here. #>
    param([string]$Scope, [string]$Key)
    $k = $Key.TrimEnd('\')
    if ($Scope -eq 'Machine') {
        return ($k -ieq $script:Paths.WU -or $k -ieq $script:Paths.AU -or $k -ilike ($script:Paths.WU + '\*'))
    }
    return ($k -ieq $script:Paths.UserWU)
}

#endregion

#region ---------------------------------------------------------------- Local Group Policy (Registry.pol)

# Registry.pol format: 'PReg' + version 1, then entries of the form
#   [key\0;value\0;type(DWORD);size(DWORD);data]   (all delimiters are UTF-16LE)
# gpedit.msc stores Local Group Policy here. If a Windows Update policy is only deleted
# from the registry, the next Group Policy refresh writes it straight back - so the
# matching Registry.pol entries must be removed too. Unrelated entries are preserved
# byte-for-byte.

function Read-PolChar {
    param([byte[]]$Bytes, [ref]$Pos, [char]$Expected)
    if ($Pos.Value + 2 -gt $Bytes.Length) { throw 'Unexpected end of Registry.pol file.' }
    $c = [BitConverter]::ToUInt16($Bytes, $Pos.Value)
    if ($c -ne [int]$Expected) { throw ("Malformed Registry.pol: expected '{0}' at offset {1}." -f $Expected, $Pos.Value) }
    $Pos.Value += 2
}

function Read-PolString {
    param([byte[]]$Bytes, [ref]$Pos)
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        if ($Pos.Value + 2 -gt $Bytes.Length) { throw 'Unexpected end of Registry.pol string.' }
        $c = [BitConverter]::ToUInt16($Bytes, $Pos.Value)
        $Pos.Value += 2
        if ($c -eq 0) { break }
        [void]$sb.Append([char]$c)
    }
    return $sb.ToString()
}

function Read-PolUInt32 {
    param([byte[]]$Bytes, [ref]$Pos)
    if ($Pos.Value + 4 -gt $Bytes.Length) { throw 'Unexpected end of Registry.pol file.' }
    $v = [BitConverter]::ToUInt32($Bytes, $Pos.Value)
    $Pos.Value += 4
    return $v
}

function Read-RegistryPolFile {
    param([Parameter(Mandatory)][string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -lt 8 -or [BitConverter]::ToUInt32($bytes, 0) -ne 0x67655250 -or [BitConverter]::ToUInt32($bytes, 4) -ne 1) {
        throw "Unrecognised Registry.pol header in '$FilePath'."
    }
    $entries = New-Object System.Collections.Generic.List[object]
    $pos = 8
    while ($pos -lt $bytes.Length) {
        $start = $pos
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected '['
        $key = Read-PolString -Bytes $bytes -Pos ([ref]$pos)
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected ';'
        $valueName = Read-PolString -Bytes $bytes -Pos ([ref]$pos)
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected ';'
        $type = Read-PolUInt32 -Bytes $bytes -Pos ([ref]$pos)
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected ';'
        $size = [int](Read-PolUInt32 -Bytes $bytes -Pos ([ref]$pos))
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected ';'
        if ($size -lt 0 -or $pos + $size -gt $bytes.Length) { throw 'Malformed Registry.pol: data size exceeds file length.' }
        $data = New-Object byte[] $size
        if ($size -gt 0) { [Array]::Copy($bytes, $pos, $data, 0, $size) }
        $pos += $size
        Read-PolChar -Bytes $bytes -Pos ([ref]$pos) -Expected ']'
        $entries.Add([pscustomobject]@{
            Key = $key; ValueName = $valueName; Type = $type; Data = $data; Start = $start; Length = ($pos - $start)
        })
    }
    return [pscustomobject]@{ Path = $FilePath; Bytes = $bytes; Entries = $entries }
}

function ConvertFrom-PolData {
    param([uint32]$Type, [byte[]]$Data)
    switch ([int]$Type) {
        1  { return [Text.Encoding]::Unicode.GetString($Data).TrimEnd([char]0) }
        2  { return [Text.Encoding]::Unicode.GetString($Data).TrimEnd([char]0) }
        7  { return (([Text.Encoding]::Unicode.GetString($Data).TrimEnd([char]0)) -split [char]0) -join '; ' }
        4  { if ($Data.Length -ge 4) { return [BitConverter]::ToUInt32($Data, 0) } }
        11 { if ($Data.Length -ge 8) { return [BitConverter]::ToUInt64($Data, 0) } }
    }
    return (Format-RegValue $Data)
}

function Get-LocalPolicyFiles {
    <# Machine, all-users and per-user/group (MLGPO) Local Group Policy files. #>
    $gp  = Join-Path $env:SystemRoot 'System32\GroupPolicy'
    $gpu = Join-Path $env:SystemRoot 'System32\GroupPolicyUsers'
    $candidates = New-Object System.Collections.Generic.List[object]
    $candidates.Add([pscustomobject]@{ Path = (Join-Path $gp 'Machine\Registry.pol'); Scope = 'Machine'; Label = 'Local GPO (Computer)' })
    $candidates.Add([pscustomobject]@{ Path = (Join-Path $gp 'User\Registry.pol');    Scope = 'User';    Label = 'Local GPO (All users)' })
    if (Test-Path -LiteralPath $gpu) {
        try {
            foreach ($d in (Get-ChildItem -LiteralPath $gpu -Directory -Force -ErrorAction Stop)) {
                $candidates.Add([pscustomobject]@{
                    Path = (Join-Path $d.FullName 'User\Registry.pol'); Scope = 'User'; Label = ('Local GPO (user/group {0})' -f $d.Name)
                })
            }
        }
        catch { Write-Log -Message ('Cannot enumerate {0}: {1}' -f $gpu, $_.Exception.Message) -Level WARN }
    }
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $parsed = $null; $err = $null
        try { $parsed = Read-RegistryPolFile -FilePath $c.Path }
        catch { $err = $_.Exception.Message; Write-Log -Message ('Cannot parse {0}: {1}' -f $c.Path, $err) -Level WARN }
        [pscustomobject]@{ Path = $c.Path; Scope = $c.Scope; Label = $c.Label; Parsed = $parsed; Error = $err }
    }
}

function Remove-RegistryPolEntries {
    <# Removes the listed (Key, ValueName) entries from one Registry.pol, keeping everything else intact. #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][object[]]$Targets)
    $pol = Read-RegistryPolFile -FilePath $FilePath
    $remove = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Targets) { [void]$remove.Add(('{0}|{1}' -f $t.PolKey, $t.ValueName)) }

    $kept = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($e in $pol.Entries) {
        if ($remove.Contains(('{0}|{1}' -f $e.Key, $e.ValueName))) { $removed.Add($e) } else { $kept.Add($e) }
    }
    if ($removed.Count -eq 0) { return 0 }

    $ms = New-Object System.IO.MemoryStream
    try {
        $ms.Write($pol.Bytes, 0, 8)
        foreach ($e in $kept) { $ms.Write($pol.Bytes, $e.Start, $e.Length) }
        $newBytes = $ms.ToArray()
    }
    finally { $ms.Dispose() }

    # Write to a temp file, validate it parses, then replace the original.
    $tmp = $FilePath + '.wurepair.tmp'
    [System.IO.File]::WriteAllBytes($tmp, $newBytes)
    try {
        $null = Read-RegistryPolFile -FilePath $tmp
        [System.IO.File]::Copy($tmp, $FilePath, $true)
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue   # temp file cleanup only
    }
    foreach ($e in $removed) {
        Write-Log -Message ('Removed Local Group Policy entry {0}\{1} from {2}' -f $e.Key, $e.ValueName, $FilePath) -Level CHANGE
    }
    return $removed.Count
}

#endregion

#region ---------------------------------------------------------------- System / management detection

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsVersionInfo {
    $cv = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $build = [int]$cv.CurrentBuild
    $ubr = if ($cv.PSObject.Properties['UBR']) { $cv.UBR } else { 0 }
    $display = if ($cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion }
               elseif ($cv.PSObject.Properties['ReleaseId']) { $cv.ReleaseId } else { 'n/a' }
    $type = if ($cv.PSObject.Properties['InstallationType']) { $cv.InstallationType } else { 'Client' }
    # ProductName still says "Windows 10" on Windows 11; the build number is authoritative.
    $name = if ($type -eq 'Server') { $cv.ProductName } elseif ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    [pscustomobject]@{
        Name             = $name
        Edition          = $cv.EditionID
        DisplayVersion   = $display
        Build            = $build
        FullBuild        = ('{0}.{1}' -f $build, $ubr)
        InstallationType = $type
        IsServer         = ($type -eq 'Server')
        IsSupported      = ($build -ge 10240)
    }
}

function Get-ManagementState {
    <# Detects domain join, Entra ID join, MDM enrollment and ConfigMgr - sources that re-apply policy. #>
    $s = [pscustomobject]@{
        DomainJoined = $false; Domain = $null; EntraJoined = $false; WorkplaceJoined = $false
        MdmEnrolled = $false; MdmProviders = @(); ActiveEnrollmentIds = @(); ConfigMgr = $false; DomainGpos = @(); IsManaged = $false
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $s.DomainJoined = [bool]$cs.PartOfDomain
        if ($cs.PartOfDomain) { $s.Domain = $cs.Domain }
    }
    catch { Write-Log -Message ('Domain membership check failed: {0}' -f $_.Exception.Message) -Level WARN }

    $dsreg = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (Test-Path -LiteralPath $dsreg) {
        try {
            $out = & $dsreg /status 2>&1
            foreach ($line in $out) {
                if ("$line" -match '^\s*AzureAdJoined\s*:\s*YES') { $s.EntraJoined = $true }
                if ("$line" -match '^\s*WorkplaceJoined\s*:\s*YES') { $s.WorkplaceJoined = $true }
            }
        }
        catch { Write-Log -Message ('dsregcmd failed: {0}' -f $_.Exception.Message) -Level WARN }
    }

    # Active MDM enrollments: HKLM\SOFTWARE\Microsoft\Enrollments\<GUID> with EnrollmentState = 1.
    try {
        $root = Open-RegistryKey -Path ('HKLM\' + $script:Paths.Enrollments)
        if ($root) {
            try {
                foreach ($sub in $root.GetSubKeyNames()) {
                    $k = $root.OpenSubKey($sub)
                    if (-not $k) { continue }
                    try {
                        $state = $k.GetValue('EnrollmentState')
                        $provider = $k.GetValue('ProviderID')
                        # Any active enrollment owns its PolicyManager provider store.
                        if ($state -eq 1) { $s.ActiveEnrollmentIds += (ConvertTo-EnrollmentId $sub) }
                        if ($state -eq 1 -and $provider) {
                            $s.MdmEnrolled = $true
                            $s.MdmProviders += [string]$provider
                        }
                    }
                    finally { $k.Close() }
                }
            }
            finally { $root.Close() }
        }
    }
    catch { Write-Log -Message ('MDM enrollment check failed: {0}' -f $_.Exception.Message) -Level WARN }

    # Configuration Manager client (normally points Windows Update at a WSUS/SUP server).
    $s.ConfigMgr = [bool](Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue)   # absence is expected on most PCs

    # Group Policy objects applied to the computer, excluding the local one.
    try {
        $gl = Open-RegistryKey -Path ('HKLM\' + $script:Paths.GpoList)
        if ($gl) {
            try {
                foreach ($sub in $gl.GetSubKeyNames()) {
                    $k = $gl.OpenSubKey($sub)
                    if (-not $k) { continue }
                    try {
                        $n = [string]$k.GetValue('DisplayName')
                        if ($n -and $n -ne 'Local Group Policy') { $s.DomainGpos += $n }
                    }
                    finally { $k.Close() }
                }
            }
            finally { $gl.Close() }
        }
    }
    catch { Write-Log -Message ('Applied GPO list unavailable: {0}' -f $_.Exception.Message) -Level WARN -NoConsole }

    $s.MdmProviders = @($s.MdmProviders | Select-Object -Unique)
    $s.IsManaged = $s.DomainJoined -or $s.EntraJoined -or $s.MdmEnrolled -or $s.ConfigMgr
    return $s
}

function ConvertTo-EnrollmentId {
    param($Value)
    return ([string]$Value).Trim().Trim('{', '}').ToUpperInvariant()
}

function Test-PendingReboot {
    $reasons = @()
    $blocks = $false
    if (Test-RegistryKeyExists ('HKLM\' + $script:Paths.RebootRequired))   { $reasons += 'Windows Update'; $blocks = $true }
    if (Test-RegistryKeyExists ('HKLM\' + $script:Paths.CbsRebootPending)) { $reasons += 'Component Based Servicing'; $blocks = $true }
    [pscustomobject]@{ Any = ($reasons.Count -gt 0); Reasons = $reasons; BlocksComponentReset = $blocks }
}

function Get-WinHttpProxy {
    <# Windows Update uses the WinHTTP proxy. Returns $null when set to direct access (default). #>
    try {
        $k = Open-RegistryKey -Path ('HKLM\' + $script:Paths.WinHttp)
        if (-not $k) { return $null }
        try { $bytes = $k.GetValue('WinHttpSettings') } finally { $k.Close() }
        if (-not ($bytes -is [byte[]]) -or $bytes.Length -lt 16) { return $null }
        $flags = [BitConverter]::ToUInt32($bytes, 8)
        if (($flags -band 2) -eq 0) { return $null }
        $len = [int][BitConverter]::ToUInt32($bytes, 12)
        if ($len -le 0 -or 16 + $len -gt $bytes.Length) { return '(proxy configured)' }
        return [Text.Encoding]::ASCII.GetString($bytes, 16, $len)
    }
    catch {
        Write-Log -Message ('WinHTTP proxy check failed: {0}' -f $_.Exception.Message) -Level WARN -NoConsole
        return $null
    }
}

function Test-WsusServer {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return 'not set' }
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or ($uri.Scheme -notin @('http', 'https'))) { return 'not a valid URL' }
    $h = $uri.Host
    if ($h -in @('localhost', '0.0.0.0', '::1', '[::1]') -or $h -like '127.*') { return 'a loopback address' }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($h, $uri.Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(3000) -and $client.Connected) { $client.EndConnect($ar); return 'Reachable' }
        return 'unreachable'
    }
    catch { return 'unreachable' }
    finally { $client.Close() }
}

function Get-UpdateAgentInfo {
    <# Reads the Windows Update Agent's own view: registered update services and AU settings. #>
    $info = [pscustomobject]@{ Services = @(); NotificationLevel = $null; ServiceEnabled = $null; RebootRequired = $null; Errors = @() }
    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        foreach ($svc in $sm.Services) {
            $info.Services += [pscustomobject]@{ Name = $svc.Name; IsDefaultAUService = $svc.IsDefaultAUService; IsManaged = $svc.IsManaged }
        }
    }
    catch { $info.Errors += ('ServiceManager: {0}' -f $_.Exception.Message) }
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $info.ServiceEnabled = $au.ServiceEnabled
        $info.NotificationLevel = $au.Settings.NotificationLevel
    }
    catch { $info.Errors += ('AutoUpdate: {0}' -f $_.Exception.Message) }
    try {
        $si = New-Object -ComObject Microsoft.Update.SystemInfo
        $info.RebootRequired = $si.RebootRequired
    }
    catch { $info.Errors += ('SystemInfo: {0}' -f $_.Exception.Message) }
    return $info
}

function Get-ServiceDefinitions {
    <# Clean-install start types. Only a Disabled service is ever changed. #>
    $usoDefault = if ($script:OSInfo.Build -ge 19041) { 'AutomaticDelayed' } else { 'Manual' }
    @(
        [pscustomobject]@{ Name = 'wuauserv';         Display = 'Windows Update';                    Default = 'Manual';           Required = $true;  Verify = $true;  Image = 'svchost\.exe';          Dll = 'wuaueng\.dll$' }
        [pscustomobject]@{ Name = 'BITS';             Display = 'Background Intelligent Transfer';  Default = 'Manual';           Required = $true;  Verify = $true;  Image = 'svchost\.exe';          Dll = 'qmgr\.dll$' }
        [pscustomobject]@{ Name = 'CryptSvc';         Display = 'Cryptographic Services';           Default = 'Automatic';        Required = $true;  Verify = $true;  Image = 'svchost\.exe';          Dll = 'cryptsvc\.dll$' }
        [pscustomobject]@{ Name = 'UsoSvc';           Display = 'Update Orchestrator Service';      Default = $usoDefault;        Required = $true;  Verify = $false; Image = 'svchost\.exe';          Dll = 'usosvc\.dll$' }
        [pscustomobject]@{ Name = 'WaaSMedicSvc';     Display = 'Windows Update Medic Service';     Default = 'Manual';           Required = $false; Verify = $false; Image = 'svchost\.exe';          Dll = 'waasmedicsvc\.dll$' }
        [pscustomobject]@{ Name = 'DoSvc';            Display = 'Delivery Optimization';            Default = 'AutomaticDelayed'; Required = $false; Verify = $false; Image = 'svchost\.exe';          Dll = 'dosvc\.dll$' }
        [pscustomobject]@{ Name = 'TrustedInstaller'; Display = 'Windows Modules Installer';        Default = 'Manual';           Required = $true;  Verify = $false; Image = 'trustedinstaller\.exe'; Dll = $null }
    )
}

function Get-ServiceStartMode {
    param([string]$Name)
    $k = Open-RegistryKey -Path ('HKLM\SYSTEM\CurrentControlSet\Services\' + $Name)
    if (-not $k) { return 'Missing' }
    try {
        $start = $k.GetValue('Start')
        $delayed = $k.GetValue('DelayedAutostart', 0)
    }
    finally { $k.Close() }
    $mode = switch ($start) {
        0 { 'Boot' }
        1 { 'System' }
        2 { if ($delayed -eq 1) { 'AutomaticDelayed' } else { 'Automatic' } }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { 'Unknown' }
    }
    return $mode
}

#endregion

#region ---------------------------------------------------------------- Audit

function New-Finding {
    param(
        [string]$Area, [string]$Location, [string]$Name, $RawValue, [string]$Severity,
        [string]$Source = '', [bool]$Org = $false, [string]$Note = '', $Action = $null,
        [string]$Tier = 'None', [string]$Scope = '', [string]$PolicyKey = '', [string]$PolicyName = ''
    )
    $f = [pscustomobject]@{
        Area = $Area; Location = $Location; Name = $Name; RawValue = $RawValue; Value = (Format-RegValue $RawValue)
        Severity = $Severity; Status = ''; Source = $Source; OrgManaged = $Org; Note = $Note; Action = $Action
        Tier = $Tier; Scope = $Scope; PolicyKey = $PolicyKey; PolicyName = $PolicyName
    }
    $f.Status = Get-StatusLabel -Severity $Severity -Org $Org
    return $f
}

function Get-StatusLabel {
    param([string]$Severity, [bool]$Org)
    if ($Severity -eq 'Block') { return 'POTENTIALLY BLOCKING' }
    if ($Severity -eq 'Info')  { return 'INFO' }
    if ($Severity -eq 'OK')    { return 'DEFAULT / NORMAL' }
    if ($Org) { return 'ORGANIZATION MANAGED' }
    return 'CUSTOM POLICY'
}

function Set-FindingSeverity {
    param($Finding, [string]$Severity, [string]$Note)
    $Finding.Severity = $Severity
    if ($Note) { $Finding.Note = ('{0} {1}' -f $Finding.Note, $Note).Trim() }
    $Finding.Status = Get-StatusLabel -Severity $Severity -Org $Finding.OrgManaged
}

function Get-PolicySource {
    param([string]$Scope, [string]$Key, [string]$Name, $PolIndex, $Management)
    if ($PolIndex.Contains(('{0}|{1}|{2}' -f $Scope, $Key, $Name))) { return @('Local Group Policy (gpedit)', $false) }
    if ($Management.DomainJoined) { return @('Domain Group Policy (probable)', $true) }
    return @('Registry edit or third-party tool', $false)
}

function Add-RegistryPolicyFindings {
    param($Findings, $PolIndex, $Management, [string[]]$Sids)
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($script:PolicyCatalog | Where-Object Scope -eq 'Machine' | Select-Object -ExpandProperty Key -Unique)) {
        $targets.Add([pscustomobject]@{ Scope = 'Machine'; Key = $k; Path = ('HKLM\' + $k); Hive = 'HKLM' })
    }
    foreach ($sid in $Sids) {
        foreach ($k in ($script:PolicyCatalog | Where-Object Scope -eq 'User' | Select-Object -ExpandProperty Key -Unique)) {
            $targets.Add([pscustomobject]@{ Scope = 'User'; Key = $k; Path = ('HKU\{0}\{1}' -f $sid, $k); Hive = ('HKU\' + $sid) })
        }
    }

    $otherDo = 0
    foreach ($t in $targets) {
        try { $values = @(Get-RegistryValueSet -Path $t.Path) }
        catch {
            $Findings.Add((New-Finding -Area $script:Areas.Errors -Location $t.Path -Name '(key)' -RawValue $null -Severity 'Info' `
                -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
            continue
        }
        $sweep = Test-IsSweepKey -Scope $t.Scope -Key $t.Key
        foreach ($v in $values) {
            if ($v.Name -eq '') { continue }
            $def = Find-PolicyDef -Scope $t.Scope -Key $t.Key -Name $v.Name
            if (-not $def -and -not $sweep) {
                # Shared keys (Explorer, DeliveryOptimization, ...) hold unrelated settings: never touched.
                if ($t.Key -ieq $script:Paths.DO) { $otherDo++ }
                continue
            }
            $src, $org = Get-PolicySource -Scope $t.Scope -Key $t.Key -Name $v.Name -PolIndex $PolIndex -Management $Management
            $action = [pscustomobject]@{
                Type = 'RegValue'; Path = $t.Path; Name = $v.Name; Counter = 'Removed'; Related = @()
                Display = ('{0}\{1}' -f $t.Path, $v.Name)
            }
            if ($def) {
                $sev = & $def.Eval $v.Value
                $area = $def.Area; $note = $def.Desc; $tier = $def.Tier
            }
            else {
                $sev = 'Custom'; $area = $script:Areas.Unknown; $tier = 'Unknown'
                $note = 'Not in the documented policy catalog used by this script; removed only by option 5.'
            }
            if ($t.Scope -eq 'User') { $note = ('{0} (user hive {1})' -f $note, $t.Hive) }
            $Findings.Add((New-Finding -Area $area -Location $t.Path -Name $v.Name -RawValue $v.Value -Severity $sev `
                -Source $src -Org $org -Note $note -Action $action -Tier $tier -Scope $t.Scope -PolicyKey $t.Key -PolicyName $v.Name))
        }
    }
    if ($otherDo -gt 0) {
        $Findings.Add((New-Finding -Area $script:Areas.DO -Location ('HKLM\' + $script:Paths.DO) -Name '(other values)' -RawValue $otherDo `
            -Severity 'Info' -Note 'Delivery Optimization peer-caching values not related to update blocking. Left untouched.'))
    }
}

function Add-PolFileFindings {
    param($Findings, $PolFiles)
    foreach ($pf in $PolFiles) {
        if ($pf.Error) {
            $Findings.Add((New-Finding -Area $script:Areas.LocalGpo -Location $pf.Path -Name '(file)' -RawValue $null -Severity 'Info' `
                -Note ('Could not be parsed and will NOT be modified: {0}' -f $pf.Error)))
            continue
        }
        foreach ($e in $pf.Parsed.Entries) {
            $key = $e.Key.TrimEnd('\')
            $eff = $e.ValueName -replace '^\*\*del\.', ''
            $def = Find-PolicyDef -Scope $pf.Scope -Key $key -Name $eff
            if (-not $def -and -not (Test-IsSweepKey -Scope $pf.Scope -Key $key)) { continue }
            $val = ConvertFrom-PolData -Type $e.Type -Data $e.Data
            if ($e.ValueName.StartsWith('**')) {
                $sev = 'Custom'; $note = ('Group Policy directive "{0}".' -f $e.ValueName)
            }
            elseif ($def) { $sev = & $def.Eval $val; $note = $def.Desc }
            else { $sev = 'Custom'; $note = 'Unrecognized Windows Update policy entry.' }
            $tier = if ($def) { $def.Tier } else { 'Unknown' }
            $action = [pscustomobject]@{
                Type = 'PolEntry'; File = $pf.Path; PolKey = $e.Key; ValueName = $e.ValueName; Counter = 'Reset'
                Display = ('{0}: {1}\{2}' -f $pf.Label, $e.Key, $e.ValueName)
            }
            $Findings.Add((New-Finding -Area $script:Areas.LocalGpo -Location ('{0} - {1}' -f $pf.Label, $pf.Path) `
                -Name ('{0}\{1}' -f $key, $e.ValueName) -RawValue $val -Severity $sev -Source 'Local Group Policy (gpedit)' `
                -Note $note -Action $action -Tier $tier -Scope $pf.Scope -PolicyKey $key -PolicyName $eff))
        }
    }
}

function Get-MdmSeverity {
    param([string]$Name, $Value)
    $v = [string]$Value
    switch ($Name) {
        'AllowAutoUpdate'                  { if ($v -eq '5') { return 'Block' } }      # 5 = turn off automatic updates
        'AllowUpdateService'               { if ($v -eq '0') { return 'Block' } }      # 0 = no Microsoft update service
        'SetDisableUXWUAccess'             { if ($v -eq '1') { return 'Block' } }
        'PauseFeatureUpdates'              { if ($v -eq '1') { return 'Block' } }
        'PauseQualityUpdates'              { if ($v -eq '1') { return 'Block' } }
        'PauseFeatureUpdatesStartTime'     { if (Test-PauseActive -Value $v) { return 'Block' } }
        'PauseQualityUpdatesStartTime'     { if (Test-PauseActive -Value $v) { return 'Block' } }
        'DeferFeatureUpdatesPeriodInDays'  { if ((ConvertTo-IntOrNull $v) -gt 0) { return 'Restrict' } }
        'DeferQualityUpdatesPeriodInDays'  { if ((ConvertTo-IntOrNull $v) -gt 0) { return 'Restrict' } }
        'TargetReleaseVersion'             { if ($v) { return 'Restrict' } }
        'ProductVersion'                   { if ($v) { return 'Restrict' } }
        'ExcludeWUDriversInQualityUpdate'  { if ($v -eq '1') { return 'Restrict' } }
        'DODownloadMode'                   { if ($v -eq '100') { return 'Restrict' } }
    }
    return 'Custom'
}

function Add-MdmFindings {
    <#
        MDM / provisioning-package policies live in two places:
          PolicyManager\providers\<enrollment GUID>\default\Device\<Area>  - each source's own copy
          PolicyManager\current\device\<Area>                               - the merged winner
        PolicyManager rebuilds "current" from the provider stores, so a stale value must be
        removed from its provider store too or it comes back. A value is treated as
        organization-owned only when its provider is an ACTIVE enrollment; values whose
        provider has no active enrollment (removed enrollment, old provisioning package) are
        orphaned and may be removed.
    #>
    param($Findings, $Management)
    $active = @($Management.ActiveEnrollmentIds)

    # 1) Winning (merged) values.
    foreach ($mk in @($script:Paths.MdmUpdate, $script:Paths.MdmDO)) {
        $path = 'HKLM\' + $mk
        try { $values = @(Get-RegistryValueSet -Path $path) }
        catch {
            $Findings.Add((New-Finding -Area $script:Areas.Mdm -Location $path -Name '(key)' -RawValue $null -Severity 'Info' `
                -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
            continue
        }
        $names = @($values | ForEach-Object Name)
        foreach ($v in $values) {
            if ($v.Name -eq '' -or $v.Name -match '_(ProviderSet|WinningProvider)$') { continue }
            $sev = Get-MdmSeverity -Name $v.Name -Value $v.Value
            $related = @(@(('{0}_ProviderSet' -f $v.Name), ('{0}_WinningProvider' -f $v.Name)) | Where-Object { $names -contains $_ })
            $winner = @($values | Where-Object { $_.Name -eq ('{0}_WinningProvider' -f $v.Name) } | ForEach-Object { ConvertTo-EnrollmentId $_.Value })
            $owner = if ($winner.Count -and $winner[0]) { $winner[0] } else { $null }
            $org = if ($owner) { $active -contains $owner } else { [bool]$Management.MdmEnrolled }
            Add-MdmFinding -Findings $Findings -Path $path -Value $v -Severity $sev -Owner $owner -Org $org -Related $related
        }
    }

    # 2) Per-provider stores.
    $root = 'HKLM\' + $script:Paths.MdmProviders
    $providers = @()
    try {
        $rk = Open-RegistryKey -Path $root
        if ($rk) { try { $providers = @($rk.GetSubKeyNames()) } finally { $rk.Close() } }
    }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.Mdm -Location $root -Name '(key)' -RawValue $null -Severity 'Info' `
            -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
    }
    foreach ($prov in $providers) {
        $id = ConvertTo-EnrollmentId $prov
        $org = $active -contains $id
        foreach ($area in @('Update', 'DeliveryOptimization')) {
            $path = '{0}\{1}\default\Device\{2}' -f $root, $prov, $area
            try { $values = @(Get-RegistryValueSet -Path $path) }
            catch {
                $Findings.Add((New-Finding -Area $script:Areas.Mdm -Location $path -Name '(key)' -RawValue $null -Severity 'Info' `
                    -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
                continue
            }
            foreach ($v in $values) {
                if ($v.Name -eq '' -or $v.Name -match '_(ProviderSet|WinningProvider|LastWrite)$') { continue }
                $sev = Get-MdmSeverity -Name $v.Name -Value $v.Value
                Add-MdmFinding -Findings $Findings -Path $path -Value $v -Severity $sev -Owner $id -Org $org -Related @()
            }
        }
    }
}

function Add-MdmFinding {
    param($Findings, [string]$Path, $Value, [string]$Severity, [string]$Owner, [bool]$Org, [object[]]$Related)
    if ($Org) {
        $action = $null
        $src = if ($Owner) { ('Active MDM enrollment {0}' -f $Owner) } else { 'Active MDM enrollment' }
        $note = 'Delivered by an active MDM enrollment. Change it in the MDM console (e.g. Intune update ring); it is not modified here.'
    }
    else {
        $suffix = if ($Related.Count) { ' (+ MDM metadata)' } else { '' }
        $action = [pscustomobject]@{
            Type = 'RegValue'; Path = $Path; Name = $Value.Name; Counter = 'Removed'; Related = $Related
            Display = ('{0}\{1}{2}' -f $Path, $Value.Name, $suffix)
        }
        $src = if ($Owner) { ('Orphaned provider {0} (no active enrollment)' -f $Owner) } else { 'Orphaned MDM / provisioning value' }
        $note = 'No active enrollment owns this value: it is left over from a removed enrollment or a provisioning package.'
    }
    $Findings.Add((New-Finding -Area $script:Areas.Mdm -Location $Path -Name $Value.Name -RawValue $Value.Value -Severity $Severity `
        -Source $src -Org $Org -Note $note -Action $action -Tier 'MDM'))
}

function Get-RegistryValuesRecursive {
    param([string]$Path, [int]$Depth = 5)
    foreach ($v in @(Get-RegistryValueSet -Path $Path)) { $v }
    if ($Depth -le 0) { return }
    $k = Open-RegistryKey -Path $Path
    if (-not $k) { return }
    try { $subs = @($k.GetSubKeyNames()) } finally { $k.Close() }
    foreach ($sub in $subs) { Get-RegistryValuesRecursive -Path ('{0}\{1}' -f $Path, $sub) -Depth ($Depth - 1) }
}

function Find-PolicyDefByName {
    <# Looks a bare value name up among the core machine Windows Update policies. #>
    param([string]$Name)
    foreach ($key in @($script:Paths.WU, $script:Paths.AU)) {
        $d = Find-PolicyDef -Scope 'Machine' -Key $key -Name $Name
        if ($d) { return $d }
    }
    return $null
}

function Add-GpCacheFindings {
    param($Findings)
    $path = 'HKLM\' + $script:Paths.GPCache
    try {
        if (-not (Test-RegistryKeyExists $path)) { return }
        $values = @(Get-RegistryValuesRecursive -Path $path | Where-Object { $_.Name -ne '' })
    }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.Cache -Location $path -Name '(key)' -RawValue $null -Severity 'Info' -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
        return
    }
    if ($values.Count -eq 0) { return }
    $sev = 'Custom'
    $bad = @()
    foreach ($v in $values) {
        $d = Find-PolicyDefByName -Name $v.Name
        if ($d -and ((& $d.Eval $v.Value) -in @('Block', 'Restrict'))) { $bad += ('{0}={1}' -f $v.Name, (Format-RegValue $v.Value)) }
    }
    if ($bad.Count) { $sev = 'Block' }
    $names = @($values | ForEach-Object Name | Select-Object -Unique)
    $shown = ($names | Select-Object -First 8) -join ', '
    if ($names.Count -gt 8) { $shown += ', ...' }
    $note = 'Windows Update''s cached copy of Group Policy. If it still holds removed policies, Settings keeps saying "managed by your organisation". Windows rebuilds it from current policy.'
    if ($bad.Count) { $note += (' Cached blocking values: {0}.' -f ($bad -join ', ')) }
    $action = [pscustomobject]@{ Type = 'CacheKey'; Path = $path; Counter = 'Reset'; Display = ('Clear policy cache {0}' -f $path) }
    $Findings.Add((New-Finding -Area $script:Areas.Cache -Location $path -Name ('{0} cached value(s)' -f $values.Count) -RawValue $shown `
        -Severity $sev -Source 'Windows Update policy cache' -Note $note -Action $action -Tier 'Cache'))
}

function Add-PolicyStateFindings {
    <# Read-only: what Windows Update itself evaluated. Useful when the source of a policy is unclear. #>
    param($Findings)
    $path = 'HKLM\' + $script:Paths.PolicyState
    try { $values = @(Get-RegistryValueSet -Path $path | Where-Object { $_.Name -ne '' }) }
    catch { return }
    foreach ($v in $values) {
        $Findings.Add((New-Finding -Area $script:Areas.Effective -Location $path -Name $v.Name -RawValue $v.Value -Severity 'Info'))
    }
}

function Add-IfeoFindings {
    param($Findings)
    foreach ($exe in $script:WUExecutables) {
        $path = 'HKLM\{0}\{1}' -f $script:Paths.IFEO, $exe
        try { $dbg = @(Get-RegistryValueSet -Path $path | Where-Object { $_.Name -eq 'Debugger' }) }
        catch {
            $Findings.Add((New-Finding -Area $script:Areas.Ifeo -Location $path -Name 'Debugger' -RawValue $null -Severity 'Info' -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
            continue
        }
        foreach ($v in $dbg) {
            $action = [pscustomobject]@{ Type = 'RegValue'; Path = $path; Name = 'Debugger'; Counter = 'Reset'; Related = @(); Display = ('{0}\Debugger' -f $path) }
            $Findings.Add((New-Finding -Area $script:Areas.Ifeo -Location $path -Name ('{0} Debugger' -f $exe) -RawValue $v.Value -Severity 'Block' `
                -Source 'Update-blocking tool' -Note ('Prevents {0} from running. Not present on a clean install; only this value is removed.' -f $exe) -Action $action -Tier 'Tamper'))
        }
    }
}

function Get-UpdateFirewallRules {
    <# Outbound Block rules aimed at update services or programs, enabled or not. Throws if the firewall API is unavailable. #>
    $svcNames = @('wuauserv', 'UsoSvc', 'DoSvc', 'BITS', 'WaaSMedicSvc')
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @(Get-NetFirewallServiceFilter -All -ErrorAction Stop)) {
        if ($f.Service -and ($svcNames -contains $f.Service)) { [void]$ids.Add($f.InstanceID) }
    }
    foreach ($f in @(Get-NetFirewallApplicationFilter -All -ErrorAction Stop)) {
        if ($f.Program -and $f.Program -ne 'Any' -and ($script:WUExecutables -contains ([IO.Path]::GetFileName($f.Program)).ToLowerInvariant())) { [void]$ids.Add($f.InstanceID) }
    }
    foreach ($id in $ids) {
        try { $r = Get-NetFirewallRule -Name $id -ErrorAction Stop }
        catch { continue }   # filter without a readable rule (e.g. removed meanwhile)
        if ([string]$r.Direction -eq 'Outbound' -and [string]$r.Action -eq 'Block') { $r }
    }
}

function Add-FirewallFindings {
    <# Enabled outbound Block rules aimed at update services or programs. Locally created ones can be disabled (not deleted). #>
    param($Findings)
    try { $rules = @(Get-UpdateFirewallRules) }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.Firewall -Location 'Windows Firewall' -Name '(rules)' -RawValue $null -Severity 'Info' -Note ('Could not read firewall rules: {0}' -f $_.Exception.Message)))
        return
    }
    foreach ($r in ($rules | Where-Object { [string]$_.Enabled -eq 'True' })) {
        $gp = ([string]$r.PolicyStoreSourceType -eq 'GroupPolicy')
        $action = if ($gp) { $null } else {
            [pscustomobject]@{ Type = 'FirewallRule'; RuleName = $r.Name; Counter = 'Reset'; Display = ('Disable firewall rule "{0}"' -f $r.DisplayName) }
        }
        $src = if ($gp) { 'Group Policy firewall rule' } else { 'Local firewall rule' }
        $Findings.Add((New-Finding -Area $script:Areas.Firewall -Location ('Firewall rule {0}' -f $r.Name) -Name $r.DisplayName -RawValue 'Outbound, Block, Enabled' `
            -Severity 'Block' -Source $src -Org $gp -Note 'Blocks Windows Update traffic. Local rules are disabled, not deleted.' -Action $action -Tier 'Tamper'))
    }
}

function Add-PauseStateFindings {
    <#
        The Settings app "Pause updates" button is not a policy: it stores its state in
        UX\Settings and Windows Update mirrors it in UpdatePolicy\Settings. Clearing these
        values is the registry equivalent of "Resume updates". FlightSettingsMaxPauseDays
        is not written by a clean install; it is a common tweak that extends the pause limit.
    #>
    param($Findings)
    $now = (Get-Date).ToUniversalTime()
    $uxPath = 'HKLM\' + $script:Paths.UXSettings
    try {
        $ux = @(Get-RegistryValueSet -Path $uxPath)
        $pauseVals = @($ux | Where-Object { $_.Name -like 'Pause*' })
        $until = $null
        foreach ($pv in ($pauseVals | Where-Object { $_.Name -match 'ExpiryTime$|EndTime$' })) {
            $d = ConvertTo-DateOrNull $pv.Value
            if ($d -and $d -gt $now -and ($null -eq $until -or $d -gt $until)) { $until = $d }
        }
        foreach ($pv in $pauseVals) {
            $sev = if ($until) { 'Block' } else { 'Custom' }
            $note = if ($until) { ('Updates are paused from the Settings app until {0:yyyy-MM-dd} (UTC).' -f $until) } else { 'Expired pause record.' }
            $action = [pscustomobject]@{ Type = 'RegValue'; Path = $uxPath; Name = $pv.Name; Counter = 'Reset'; Related = @(); Display = ('{0}\{1}' -f $uxPath, $pv.Name) }
            $Findings.Add((New-Finding -Area $script:Areas.UxPause -Location $uxPath -Name $pv.Name -RawValue $pv.Value -Severity $sev `
                -Source 'Settings app (user pause)' -Note $note -Action $action -Tier 'State'))
        }
        foreach ($fv in ($ux | Where-Object { $_.Name -eq 'FlightSettingsMaxPauseDays' })) {
            $action = [pscustomobject]@{ Type = 'RegValue'; Path = $uxPath; Name = $fv.Name; Counter = 'Reset'; Related = @(); Display = ('{0}\{1}' -f $uxPath, $fv.Name) }
            $Findings.Add((New-Finding -Area $script:Areas.UxPause -Location $uxPath -Name $fv.Name -RawValue $fv.Value -Severity 'Custom' `
                -Source 'Registry tweak' -Note 'Non-default tweak that extends the maximum pause period; absent on a clean installation.' -Action $action -Tier 'State'))
        }
    }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.UxPause -Location $uxPath -Name '(key)' -RawValue $null -Severity 'Info' -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
    }

    $upPath = 'HKLM\' + $script:Paths.UpdatePolicySettings
    try {
        $up = @(Get-RegistryValueSet -Path $upPath | Where-Object { $_.Name -in @('PausedFeatureStatus', 'PausedQualityStatus', 'PausedFeatureDate', 'PausedQualityDate') })
        $paused = @($up | Where-Object { $_.Name -like '*Status' -and [string]$_.Value -eq '1' }).Count -gt 0
        foreach ($v in $up) {
            $sev = if ($paused) { 'Block' } else { 'Custom' }
            $action = [pscustomobject]@{ Type = 'RegValue'; Path = $upPath; Name = $v.Name; Counter = 'Reset'; Related = @(); Display = ('{0}\{1}' -f $upPath, $v.Name) }
            $Findings.Add((New-Finding -Area $script:Areas.UxPause -Location $upPath -Name $v.Name -RawValue $v.Value -Severity $sev `
                -Source 'Windows Update pause state' -Note 'Windows Update internal pause state (recomputed by Windows when cleared).' -Action $action -Tier 'State'))
        }
    }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.UxPause -Location $upPath -Name '(key)' -RawValue $null -Severity 'Info' -Note ('Could not read: {0}' -f (Get-FailureReason $_))))
    }
}

function Update-WsusFindings {
    <# An intranet server that is missing, loopback or unreachable leaves Windows Update with no source at all. #>
    param($Findings)
    $wsusNames = @('UseWUServer', 'WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate', 'FillEmptyContentUrls',
                   'DoNotConnectToWindowsUpdateInternetLocations', 'SetPolicyDrivenUpdateSourceForFeatureUpdates',
                   'SetPolicyDrivenUpdateSourceForQualityUpdates', 'SetPolicyDrivenUpdateSourceForDriverUpdates',
                   'SetPolicyDrivenUpdateSourceForOtherUpdates')
    $related = @($Findings | Where-Object {
        $_.Scope -eq 'Machine' -and ($_.PolicyKey -ieq $script:Paths.WU -or $_.PolicyKey -ieq $script:Paths.AU) -and ($wsusNames -contains $_.PolicyName)
    })
    # Registry values win over Registry.pol entries (they are what Windows Update reads).
    $pick = {
        param($name)
        $r = @($related | Where-Object { $_.PolicyName -eq $name -and $_.Action -and $_.Action.Type -eq 'RegValue' })
        if ($r.Count) { return $r[0] }
        $r = @($related | Where-Object { $_.PolicyName -eq $name })
        if ($r.Count) { return $r[0] }
        return $null
    }
    $use = & $pick 'UseWUServer'
    $srv = & $pick 'WUServer'
    $state = [pscustomobject]@{ Enabled = $false; Server = $null; Reachability = 'not configured' }

    if ($use -and [string]$use.RawValue -eq '1') {
        $state.Enabled = $true
        $state.Server = if ($srv) { [string]$srv.RawValue } else { $null }
        $state.Reachability = Test-WsusServer -Url $state.Server
        if ($state.Reachability -ne 'Reachable') {
            $msg = ("Intranet update server '{0}' is {1}: Windows Update has no working update source." -f $state.Server, $state.Reachability)
            foreach ($f in $related) {
                if ($f.PolicyName -like 'SetPolicyDrivenUpdateSource*' -and [string]$f.RawValue -ne '1') { continue }
                Set-FindingSeverity -Finding $f -Severity 'Block' -Note $msg
            }
        }
        else {
            foreach ($f in $related) { Set-FindingSeverity -Finding $f -Severity $f.Severity -Note ('Intranet server {0} is reachable.' -f $state.Server) }
        }
    }
    else {
        foreach ($f in $related) {
            if ($f.PolicyName -eq 'DoNotConnectToWindowsUpdateInternetLocations') {
                Set-FindingSeverity -Finding $f -Severity 'Restrict' -Note 'No intranet server is active; this value is typically left behind by update-blocking tools.'
            }
            elseif ($f.PolicyName -like 'SetPolicyDrivenUpdateSource*' -and [string]$f.RawValue -eq '1') {
                Set-FindingSeverity -Finding $f -Severity 'Restrict' -Note 'Points the update source at an intranet server, but none is configured.'
            }
            elseif ($f.PolicyName -ne 'UseWUServer') {
                Set-FindingSeverity -Finding $f -Severity $f.Severity -Note 'Inactive: UseWUServer is not 1.'
            }
        }
    }
    return $state
}

function Add-ServiceFindings {
    param($Findings)
    foreach ($d in (Get-ServiceDefinitions)) {
        $mode = Get-ServiceStartMode -Name $d.Name
        $svc = Get-Service -Name $d.Name -ErrorAction SilentlyContinue   # missing service is reported below
        $status = if ($svc) { [string]$svc.Status } else { 'Missing' }
        $action = $null; $note = ('Default start type: {0}.' -f $d.Default)
        if ($mode -eq 'Missing' -or -not $svc) {
            $sev = if ($d.Required) { 'Block' } else { 'Restrict' }
            $note = 'Service is not registered. Repair with DISM /RestoreHealth or an in-place upgrade.'
        }
        elseif ($mode -eq 'Disabled') {
            $sev = if ($d.Required) { 'Block' } else { 'Restrict' }
            $action = [pscustomobject]@{
                Type = 'Service'; ServiceName = $d.Name; TargetMode = $d.Default; Counter = 'Service'
                Display = ('Restore start type of {0}: Disabled -> {1}' -f $d.Name, $d.Default)
            }
        }
        elseif ($mode -ne $d.Default) {
            $sev = 'OK'; $note = ('{0} Current start type also works; left unchanged.' -f $note)
        }
        else { $sev = 'OK' }
        $Findings.Add((New-Finding -Area $script:Areas.Services -Location ('HKLM\SYSTEM\CurrentControlSet\Services\' + $d.Name) `
            -Name ('{0} ({1})' -f $d.Display, $d.Name) -RawValue ('{0} / {1}' -f $mode, $status) -Severity $sev -Note $note -Action $action -Tier 'Service'))
        if ($mode -ne 'Missing') { Add-ServiceRegistrationFinding -Findings $Findings -Definition $d }
    }
}

function Add-ServiceRegistrationFinding {
    <#
        Some blocker tools point a service at a missing binary/DLL so it can never run. This is
        reported but NOT auto-fixed: the correct values differ between builds, and guessing them
        could leave the service worse off.
    #>
    param($Findings, $Definition)
    $base = 'HKLM\SYSTEM\CurrentControlSet\Services\' + $Definition.Name
    try {
        $img = @(Get-RegistryValueSet -Path $base | Where-Object Name -eq 'ImagePath' | ForEach-Object Value)
        $dll = @(Get-RegistryValueSet -Path ($base + '\Parameters') | Where-Object Name -eq 'ServiceDll' | ForEach-Object Value)
    }
    catch { return }
    $problems = @()
    if ($img.Count -and [string]$img[0] -notmatch $Definition.Image) { $problems += ('ImagePath = {0}' -f $img[0]) }
    if ($Definition.Dll -and $dll.Count -and [string]$dll[0] -notmatch $Definition.Dll) { $problems += ('ServiceDll = {0}' -f $dll[0]) }
    if ($Definition.Dll -and $dll.Count -eq 0 -and [string]$img[0] -match 'svchost') { $problems += 'ServiceDll missing' }
    if ($problems.Count -eq 0) { return }
    $Findings.Add((New-Finding -Area $script:Areas.Services -Location $base -Name ('{0} registration' -f $Definition.Name) -RawValue ($problems -join '; ') `
        -Severity 'Block' -Source 'Altered service registration' `
        -Note 'The service points at an unexpected program or DLL. Not changed automatically: repair with an in-place upgrade (keeps apps and files), or import this key from a healthy PC on the same build.'))
}

function Add-TaskFindings {
    param($Findings)
    foreach ($t in $script:TaskDefs) {
        $full = $t.Path + $t.Name
        try {
            $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop
            if ([string]$task.State -eq 'Disabled') {
                $action = [pscustomobject]@{ Type = 'Task'; TaskPath = $t.Path; TaskName = $t.Name; Counter = 'Reset'; Display = ('Enable scheduled task {0}' -f $full) }
                $Findings.Add((New-Finding -Area $script:Areas.Tasks -Location $full -Name $t.Name -RawValue 'Disabled' -Severity 'Block' `
                    -Note 'Enabled on a clean installation; disabling it stops automatic scans.' -Action $action -Tier 'Task'))
            }
            else {
                $Findings.Add((New-Finding -Area $script:Areas.Tasks -Location $full -Name $t.Name -RawValue ([string]$task.State) -Severity 'OK'))
            }
        }
        catch {
            $Findings.Add((New-Finding -Area $script:Areas.Tasks -Location $full -Name $t.Name -RawValue 'Not found' -Severity 'Info' `
                -Note 'Task not present or not readable on this build.'))
        }
    }
}

function Test-HostsLineBlocksUpdate {
    <# True for an active (uncommented) hosts line that maps a Windows Update endpoint. #>
    param([string]$Line)
    if ($Line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($Line)) { return $false }
    $tokens = @((($Line -split '#', 2)[0]).Trim() -split '\s+')
    if ($tokens.Count -lt 2) { return $false }
    foreach ($h in $tokens[1..($tokens.Count - 1)]) {
        foreach ($suffix in $script:WUHostSuffixes) {
            if ($h -ieq $suffix -or $h.EndsWith('.' + $suffix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Add-HostsFindings {
    param($Findings)
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) { return }
    try { $lines = [System.IO.File]::ReadAllLines($hostsPath, [System.Text.Encoding]::Default) }
    catch {
        $Findings.Add((New-Finding -Area $script:Areas.Hosts -Location $hostsPath -Name '(file)' -RawValue $null -Severity 'Info' -Note ('Could not read: {0}' -f $_.Exception.Message)))
        return
    }
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if (Test-HostsLineBlocksUpdate $line) {
            $action = [pscustomobject]@{ Type = 'Hosts'; File = $hostsPath; LineIndex = $i; Line = $line; Counter = 'Reset'; Display = ('Comment out hosts line {0}: {1}' -f ($i + 1), $line.Trim()) }
            $Findings.Add((New-Finding -Area $script:Areas.Hosts -Location ('{0} (line {1})' -f $hostsPath, ($i + 1)) -Name $line.Trim() -RawValue $line.Trim() `
                -Severity 'Block' -Note 'Redirects a Windows Update endpoint.' -Action $action -Tier 'Hosts'))
        }
    }
}

function Get-UpdateReadiness {
    param($Findings, $Wsus, $Pending)
    $block = @($Findings | Where-Object Severity -eq 'Block')
    if ($block.Count -gt 0) {
        if (@($block | Where-Object { -not $_.OrgManaged }).Count -eq 0) { return 'BLOCKED BY ORGANIZATION POLICY' }
        return 'BLOCKED - ATTENTION REQUIRED'
    }
    $status = 'READY'
    if ($Wsus.Enabled) { $status = ('READY (updates from intranet server {0})' -f $Wsus.Server) }
    elseif (@($Findings | Where-Object OrgManaged).Count -gt 0) { $status = 'READY (organization-managed policies present)' }
    if ($Pending.Any) { $status += ' - restart pending' }
    return $status
}

function Get-WindowsUpdateState {
    <# Collects everything the audit shows. Read-only. #>
    $mgmt = Get-ManagementState
    $sids = @(Get-LoadedUserSids)
    $polFiles = @(Get-LocalPolicyFiles)

    $polIndex = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pf in ($polFiles | Where-Object { $_.Parsed })) {
        foreach ($e in $pf.Parsed.Entries) {
            [void]$polIndex.Add(('{0}|{1}|{2}' -f $pf.Scope, $e.Key.TrimEnd('\'), ($e.ValueName -replace '^\*\*del\.', '')))
        }
    }

    $findings = New-Object System.Collections.Generic.List[object]
    Add-RegistryPolicyFindings -Findings $findings -PolIndex $polIndex -Management $mgmt -Sids $sids
    Add-PolFileFindings -Findings $findings -PolFiles $polFiles
    Add-MdmFindings -Findings $findings -Management $mgmt
    Add-GpCacheFindings -Findings $findings
    Add-PauseStateFindings -Findings $findings
    $wsus = Update-WsusFindings -Findings $findings
    Add-ServiceFindings -Findings $findings
    Add-TaskFindings -Findings $findings
    Add-HostsFindings -Findings $findings
    Add-IfeoFindings -Findings $findings
    Add-FirewallFindings -Findings $findings
    Add-PolicyStateFindings -Findings $findings

    $proxy = Get-WinHttpProxy
    if ($proxy) {
        $findings.Add((New-Finding -Area $script:Areas.Network -Location 'netsh winhttp show proxy' -Name 'WinHTTP proxy' -RawValue $proxy -Severity 'Custom' `
            -Note 'Windows Update uses this proxy. Not modified by this script; if it is stale, run: netsh winhttp reset proxy'))
    }
    else {
        $findings.Add((New-Finding -Area $script:Areas.Network -Location 'netsh winhttp show proxy' -Name 'WinHTTP proxy' -RawValue 'Direct access' -Severity 'OK'))
    }

    $pending = Test-PendingReboot
    [pscustomobject]@{
        Timestamp  = Get-Date
        Management = $mgmt
        UserSids   = $sids
        PolFiles   = $polFiles
        Findings   = $findings
        Wsus       = $wsus
        Agent      = Get-UpdateAgentInfo
        Pending    = $pending
        Readiness  = Get-UpdateReadiness -Findings $findings -Wsus $wsus -Pending $pending
    }
}

function Write-FindingLine {
    param($Finding)
    $color = switch ($Finding.Status) {
        'POTENTIALLY BLOCKING' { 'Red' }
        'ORGANIZATION MANAGED' { 'Magenta' }
        'CUSTOM POLICY'        { 'Yellow' }
        'INFO'                 { 'DarkGray' }
        default                { 'Green' }
    }
    $flag = if ($Finding.Severity -eq 'Restrict') { ' (restrictive)' } else { '' }
    Out-Report ('  [{0,-20}] {1} = {2}{3}' -f $Finding.Status, $Finding.Name, $Finding.Value, $flag) $color
    Out-Report ('      {0}' -f $Finding.Location) 'DarkGray'
    $detail = @()
    if ($Finding.Source) { $detail += ('Source: {0}.' -f $Finding.Source) }
    if ($Finding.Note)   { $detail += $Finding.Note }
    if ($detail.Count)   { Out-Report ('      {0}' -f ($detail -join ' ')) 'Gray' }
}

function Show-AuditReport {
    param($State)
    $a = $script:Areas
    $os = $script:OSInfo
    $m = $State.Management

    Out-Report ''
    Out-Report '========================================================================' Cyan
    Out-Report (' Windows Update audit - {0:yyyy-MM-dd HH:mm:ss}' -f $State.Timestamp) Cyan
    Out-Report '========================================================================' Cyan
    Out-Report (' Computer   : {0}' -f $env:COMPUTERNAME)
    Out-Report (' Windows    : {0} {1} ({2}), build {3}' -f $os.Name, $os.DisplayVersion, $os.Edition, $os.FullBuild)
    Out-Report (' PowerShell : {0}' -f $PSVersionTable.PSVersion)
    Out-Report ''
    Out-Report ' Management' White
    Out-Report ('   Domain joined       : {0}' -f $(if ($m.DomainJoined) { 'Yes (' + $m.Domain + ')' } else { 'No' }))
    Out-Report ('   Entra ID joined     : {0}' -f $(if ($m.EntraJoined) { 'Yes' } else { 'No' }))
    Out-Report ('   MDM enrollment      : {0}' -f $(if ($m.MdmEnrolled) { 'Yes (' + ($m.MdmProviders -join ', ') + ')' } else { 'No' }))
    Out-Report ('   ConfigMgr client    : {0}' -f $(if ($m.ConfigMgr) { 'Yes' } else { 'No' }))
    if ($m.DomainGpos.Count) { Out-Report ('   Applied domain GPOs : {0}' -f ($m.DomainGpos -join ', ')) }
    if ($m.IsManaged) {
        Out-Report '   => ORGANIZATION MANAGED: policies may be re-applied automatically after removal.' Magenta
    }
    else { Out-Report '   => Not managed by an organization (standalone PC).' Green }

    $sections = @($a.Access, $a.AU, $a.Feature, $a.Quality, $a.Pause, $a.Target, $a.WUfB, $a.WSUS, $a.Driver,
                  $a.Restart, $a.Legacy, $a.Unknown, $a.User, $a.DO, $a.LocalGpo, $a.Mdm, $a.Cache, $a.UxPause,
                  $a.Services, $a.Tasks, $a.Ifeo, $a.Firewall, $a.Hosts, $a.Network, $a.Effective, $a.Errors)
    $emptyText = @{
        $a.Unknown  = 'None.'
        $a.User     = ('Not configured in {0} loaded user hive(s) - DEFAULT / NORMAL.' -f $State.UserSids.Count)
        $a.LocalGpo = 'No Windows Update entries in Local Group Policy - DEFAULT / NORMAL.'
        $a.Mdm      = 'No MDM Windows Update policies - DEFAULT / NORMAL.'
        $a.UxPause  = 'Updates are not paused - DEFAULT / NORMAL.'
        $a.Hosts    = 'No Windows Update endpoints redirected - DEFAULT / NORMAL.'
        $a.Cache    = 'No cached Windows Update policy - DEFAULT / NORMAL.'
        $a.Ifeo     = 'No update program is blocked - DEFAULT / NORMAL.'
        $a.Firewall = 'No firewall rule blocks Windows Update - DEFAULT / NORMAL.'
        $a.Effective = 'No evaluated policy state recorded.'
        $a.Errors   = $null
    }
    foreach ($sec in $sections) {
        $items = @($State.Findings | Where-Object Area -eq $sec)
        if ($items.Count -eq 0 -and $emptyText.ContainsKey($sec) -and -not $emptyText[$sec]) { continue }
        Out-Report ''
        Out-Report (' {0}' -f $sec) White
        if ($items.Count -eq 0) {
            $txt = if ($emptyText.ContainsKey($sec)) { $emptyText[$sec] } else { 'Not configured - DEFAULT / NORMAL.' }
            Out-Report ('  {0}' -f $txt) Green
            continue
        }
        foreach ($f in $items) { Write-FindingLine $f }
    }

    Out-Report ''
    Out-Report ' Windows Update source and agent' White
    if ($State.Wsus.Enabled) {
        $c = if ($State.Wsus.Reachability -eq 'Reachable') { 'Magenta' } else { 'Red' }
        Out-Report ('  Update source       : Intranet server {0} ({1})' -f $State.Wsus.Server, $State.Wsus.Reachability) $c
    }
    else { Out-Report '  Update source       : Microsoft Windows Update (Internet) - DEFAULT / NORMAL' Green }
    foreach ($s in $State.Agent.Services) {
        $flags = @()
        if ($s.IsDefaultAUService) { $flags += 'default for Automatic Updates' }
        if ($s.IsManaged) { $flags += 'managed' }
        Out-Report ('  Registered service  : {0}{1}' -f $s.Name, $(if ($flags.Count) { ' [' + ($flags -join ', ') + ']' } else { '' }))
    }
    if ($null -ne $State.Agent.NotificationLevel) {
        $lvl = switch ([int]$State.Agent.NotificationLevel) {
            0 { 'Not configured (default)' } 1 { 'Disabled' } 2 { 'Notify before download' }
            3 { 'Notify before installation' } 4 { 'Scheduled installation' } default { 'Unknown' }
        }
        $c = if ([int]$State.Agent.NotificationLevel -eq 1) { 'Red' } else { 'Gray' }
        Out-Report ('  AU notification     : {0} ({1})' -f $State.Agent.NotificationLevel, $lvl) $c
    }
    if ($State.Pending.Any) { Out-Report ('  Restart pending     : Yes ({0})' -f ($State.Pending.Reasons -join ', ')) Yellow }
    else { Out-Report '  Restart pending     : No' }
    foreach ($e in $State.Agent.Errors) { Out-Report ('  Agent query error   : {0}' -f $e) Yellow }
    if ($State.UserSids.Count -eq 0) { Out-Report '  Note: no user hives loaded; user-level policies of signed-out users were not checked.' DarkGray }

    $blocking = @($State.Findings | Where-Object Status -eq 'POTENTIALLY BLOCKING').Count
    $org      = @($State.Findings | Where-Object Status -eq 'ORGANIZATION MANAGED').Count
    $custom   = @($State.Findings | Where-Object Status -eq 'CUSTOM POLICY').Count
    $normal   = @($State.Findings | Where-Object Status -eq 'DEFAULT / NORMAL').Count
    Out-Report ''
    Out-Report '------------------------------------------------------------------------' DarkCyan
    Out-Report (' POTENTIALLY BLOCKING : {0}' -f $blocking) $(if ($blocking) { 'Red' } else { 'Green' })
    Out-Report (' ORGANIZATION MANAGED : {0}' -f $org) $(if ($org) { 'Magenta' } else { 'Gray' })
    Out-Report (' CUSTOM POLICY        : {0}' -f $custom) $(if ($custom) { 'Yellow' } else { 'Gray' })
    Out-Report (' DEFAULT / NORMAL     : {0}' -f $normal) Green
    Out-Report ''
    $rc = if ($State.Readiness -like 'READY*') { 'Green' } else { 'Red' }
    Out-Report (' Windows Update status: {0}' -f $State.Readiness) $rc
    Out-Report '------------------------------------------------------------------------' DarkCyan
}

function Get-WindowsUpdateAudit {
    <# Option 1. Read-only. -Quiet returns the state without printing. #>
    [CmdletBinding()]
    param([switch]$Quiet)
    if (-not $Quiet) { Write-Log -Message 'Collecting Windows Update configuration (read-only)...' }
    $state = Get-WindowsUpdateState
    if ($Quiet) { return $state }

    $script:ReportLines = New-Object System.Collections.Generic.List[string]
    try { Show-AuditReport -State $state }
    finally {
        $reportPath = Join-Path $script:SessionDir ('Audit-{0}.txt' -f (Get-Date -Format 'HHmmss'))
        try {
            [System.IO.File]::WriteAllLines($reportPath, $script:ReportLines.ToArray(), [System.Text.Encoding]::UTF8)
            Write-Log -Message ('Audit report saved: {0}' -f $reportPath)
        }
        catch { Write-Log -Message ('Could not save audit report: {0}' -f $_.Exception.Message) -Level WARN }
        $script:ReportLines = $null
    }
    return $state
}

#endregion

#region ---------------------------------------------------------------- Backup

function Get-BackupKeyList {
    param([string[]]$Sids)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($k in ($script:PolicyCatalog | Where-Object Scope -eq 'Machine' | Select-Object -ExpandProperty Key -Unique)) { $keys.Add('HKLM\' + $k) }
    foreach ($sid in $Sids) {
        foreach ($k in ($script:PolicyCatalog | Where-Object Scope -eq 'User' | Select-Object -ExpandProperty Key -Unique)) { $keys.Add(('HKU\{0}\{1}' -f $sid, $k)) }
    }
    foreach ($k in @($script:Paths.UXSettings, $script:Paths.UpdatePolicySettings, $script:Paths.MdmUpdate, $script:Paths.MdmDO,
                     $script:Paths.GPCache, $script:Paths.PolicyState)) { $keys.Add('HKLM\' + $k) }
    foreach ($exe in $script:WUExecutables) { $keys.Add(('HKLM\{0}\{1}' -f $script:Paths.IFEO, $exe)) }
    try {
        $rk = Open-RegistryKey -Path ('HKLM\' + $script:Paths.MdmProviders)
        if ($rk) {
            try { $provs = @($rk.GetSubKeyNames()) } finally { $rk.Close() }
            foreach ($prov in $provs) {
                foreach ($area in @('Update', 'DeliveryOptimization')) {
                    $keys.Add(('HKLM\{0}\{1}\default\Device\{2}' -f $script:Paths.MdmProviders, $prov, $area))
                }
            }
        }
    }
    catch { Write-Log -Message ('Cannot list MDM providers for backup: {0}' -f $_.Exception.Message) -Level WARN }
    foreach ($d in (Get-ServiceDefinitions)) { $keys.Add('HKLM\SYSTEM\CurrentControlSet\Services\' + $d.Name) }
    return ($keys | Select-Object -Unique)
}

function Backup-WindowsUpdatePolicies {
    <#
        Exports every registry key this tool may touch (reg.exe export, restorable with
        reg import), copies Local Group Policy Registry.pol files and the hosts file.
        Returns the backup folder, or $null if any export failed (callers then abort).
    #>
    param([string]$Label = 'Manual', [string]$Description = '')
    $dir = Join-Path $script:SessionDir ('Backup-{0}-{1}' -f $Label, (Get-Date -Format 'HHmmss'))
    Write-Log -Message ('Creating backup in {0}' -f $dir)
    try {
        New-Item -ItemType Directory -Path (Join-Path $dir 'Registry') -Force -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'Files') -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Add-Failure -Target $dir -Reason ('Cannot create backup folder: {0}' -f $_.Exception.Message)
        return $null
    }

    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $ok = $true; $count = 0
    foreach ($k in (Get-BackupKeyList -Sids @(Get-LoadedUserSids))) {
        if (-not (Test-RegistryKeyExists $k)) { continue }
        $file = Join-Path (Join-Path $dir 'Registry') (($k -replace '[\\/:*?"<>| ]', '_') + '.reg')
        $out = & $reg export $k $file /y 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message ('Backup of {0} failed: {1}' -f $k, $out.Trim()) -Level ERROR
            $ok = $false
        }
        else {
            $count++
            Write-Log -Message ('Exported {0}' -f $k) -Level DEBUG
        }
    }

    $sys32 = Join-Path $env:SystemRoot 'System32'
    $files = @(Get-LocalPolicyFiles | ForEach-Object Path) + @(Join-Path $sys32 'drivers\etc\hosts')
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $rel = $f.Substring($sys32.Length).TrimStart('\')
            $dest = Join-Path (Join-Path $dir 'Files') $rel
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
            $count++
        }
        catch {
            Write-Log -Message ('Backup of {0} failed: {1}' -f $f, $_.Exception.Message) -Level ERROR
            $ok = $false
        }
    }

    # Local firewall policy, so disabled rules can be restored (netsh advfirewall import).
    $wfw = Join-Path (Join-Path $dir 'Files') 'firewall-policy.wfw'
    $out = & (Join-Path $env:SystemRoot 'System32\netsh.exe') advfirewall export $wfw 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $count++ }
    else { Write-Log -Message ('Firewall policy export failed: {0}' -f $out.Trim()) -Level WARN }

    # Exact snapshot of every managed setting, used by option 8 to restore this backup.
    try {
        $snap = Get-ConfigurationSnapshot -Label $Label -Description $Description
        $snapFile = Join-Path $dir 'snapshot.json'
        [System.IO.File]::WriteAllText($snapFile, ($snap | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log -Message ('Saved configuration snapshot {0}' -f $snapFile) -Level DEBUG
    }
    catch {
        Write-Log -Message ('Configuration snapshot failed: {0}' -f $_.Exception.Message) -Level ERROR
        $ok = $false
    }

    $readme = @(
        ('Windows Update Policy Repair v{0} - backup' -f $script:ToolVersion)
        ('Created: {0}' -f (Get-Date))
        $(if ($Description) { 'Description: ' + $Description } else { '' })
        ''
        'Easiest restore: run the script and choose option 8, "Restore Windows Update configuration".'
        'It returns every setting the script manages to exactly this state (snapshot.json).'
        ''
        'Manual restore:'
        'Registry\*.reg : restore with "reg import <file>" (or double-click) from an elevated prompt.'
        'Files\*        : paths are relative to %SystemRoot%\System32. Copy Registry.pol files back to'
        '                 GroupPolicy\... and run "gpupdate /force". Copy drivers\etc\hosts back if needed.'
        'Files\firewall-policy.wfw : "netsh advfirewall import <file>" restores the whole local firewall policy.'
    )
    try { Set-Content -LiteralPath (Join-Path $dir 'RESTORE-README.txt') -Value $readme -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Log -Message ('Could not write README: {0}' -f $_.Exception.Message) -Level WARN }

    if (-not $ok) {
        Add-Failure -Target $dir -Reason 'Backup incomplete (see log). No changes were made.'
        return $null
    }
    Write-Log -Message ('Backup complete: {0} item(s) saved.' -f $count) -Level SUCCESS
    if ($script:Summary) { $script:Summary.BackupDir = $dir }
    return $dir
}

#endregion

#region ---------------------------------------------------------------- Configuration snapshot and restore

# A snapshot records the exact state of every setting this script can change. It is saved as
# snapshot.json in every Backup-* folder: manual backups (option 7) and the automatic ones
# taken before each repair. Restoring (option 8) compares the snapshot with the current state
# and changes only what differs: values added since the backup are deleted, values changed or
# removed since are written back. A plain "reg import" cannot do that, because it never
# deletes values added after the export. Settings the script does not manage are not touched.

$script:SnapshotVersion = 1

function Get-MdmProviderIds {
    try {
        $rk = Open-RegistryKey -Path ('HKLM\' + $script:Paths.MdmProviders)
        if (-not $rk) { return }
        try { $rk.GetSubKeyNames() } finally { $rk.Close() }
    }
    catch { Write-Log -Message ('Cannot list MDM providers: {0}' -f $_.Exception.Message) -Level WARN }
}

function Get-TrackedRegistryLocations {
    <#
        Every registry location the script can modify. Filter limits which value names are
        tracked (shared keys such as Explorer or UX\Settings also hold unrelated settings).
        Recurse tracks sub-keys too; CleanupEmpty removes the key on restore if it did not
        exist in the backup and nothing is left in it.
    #>
    param([string[]]$Sids)
    $p = $script:Paths
    $doNames = @($script:PolicyCatalog | Where-Object { $_.Key -eq $p.DO } | ForEach-Object Name)
    $list = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Path, [string]$Filter, [bool]$Recurse, [bool]$CleanupEmpty)
        $list.Add([pscustomobject]@{ Path = $Path; Filter = $Filter; Recurse = $Recurse; CleanupEmpty = $CleanupEmpty })
    }
    & $add ('HKLM\' + $p.WU) '.*' $false $true
    & $add ('HKLM\' + $p.AU) '.*' $false $true
    & $add ('HKLM\' + $p.DO) ('^(' + ($doNames -join '|') + ')$') $false $true
    & $add ('HKLM\' + $p.DriverSearch) '^DontSearchWindowsUpdate$' $false $true
    & $add ('HKLM\' + $p.ExplorerPol) '^NoWindowsUpdate$' $false $false
    & $add ('HKLM\' + $p.ICM) '^DisableWindowsUpdateAccess$' $false $false
    & $add ('HKLM\' + $p.UXSettings) '^(Pause.*|FlightSettingsMaxPauseDays)$' $false $false
    & $add ('HKLM\' + $p.UpdatePolicySettings) '^(PausedFeatureStatus|PausedQualityStatus|PausedFeatureDate|PausedQualityDate)$' $false $false
    & $add ('HKLM\' + $p.MdmUpdate) '.*' $false $false
    & $add ('HKLM\' + $p.MdmDO) '.*' $false $false
    & $add ('HKLM\' + $p.GPCache) '.*' $true $true
    foreach ($exe in $script:WUExecutables) { & $add ('HKLM\{0}\{1}' -f $p.IFEO, $exe) '^Debugger$' $false $false }
    foreach ($prov in @(Get-MdmProviderIds)) {
        foreach ($area in @('Update', 'DeliveryOptimization')) {
            & $add ('HKLM\{0}\{1}\default\Device\{2}' -f $p.MdmProviders, $prov, $area) '.*' $false $false
        }
    }
    foreach ($sid in $Sids) {
        & $add ('HKU\{0}\{1}' -f $sid, $p.UserWU) '.*' $false $true
        & $add ('HKU\{0}\{1}' -f $sid, $p.ExplorerPol) '^NoWindowsUpdate$' $false $false
    }
    return $list
}

function Get-RegistryKeyPaths {
    param([string]$Path)
    $k = Open-RegistryKey -Path $Path
    if (-not $k) { return }
    try { $subs = @($k.GetSubKeyNames()) } finally { $k.Close() }
    $Path
    foreach ($sub in $subs) { Get-RegistryKeyPaths -Path ('{0}\{1}' -f $Path, $sub) }
}

function ConvertTo-SnapshotValue {
    <# Registry value -> JSON-safe form (binary as base64, multi-string as array). #>
    param([string]$Name, $Value, [string]$Kind)
    $data = switch ($Kind) {
        'Binary'      { [Convert]::ToBase64String([byte[]]$Value) }
        'None'        { if ($Value -is [byte[]]) { [Convert]::ToBase64String($Value) } else { '' } }
        'MultiString' { , ([string[]]@($Value)) }
        'DWord'       { [int]$Value }
        'QWord'       { [long]$Value }
        default       { [string]$Value }
    }
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Data = $data }
}

function Get-SnapshotValueSignature {
    param($Value)
    if ($null -eq $Value) { return '(absent)' }
    $d = if ($Value.Kind -eq 'MultiString') { (@($Value.Data) | ForEach-Object { [string]$_ }) -join [char]0 } else { [string]$Value.Data }
    return ('{0}|{1}' -f $Value.Kind, $d)
}

function Format-SnapshotValue {
    param($Value)
    if ($null -eq $Value) { return '(absent)' }
    switch ($Value.Kind) {
        'Binary'      { return '(binary data)' }
        'None'        { return '(binary data)' }
        'MultiString' { return ((@($Value.Data) | ForEach-Object { [string]$_ }) -join '; ') }
    }
    $t = [string]$Value.Data
    if ($t.Length -eq 0) { return '(empty string)' }
    return $t
}

function Set-RegistryValueFromSnapshot {
    param([string]$Path, $Value)
    $parts = $Path -split '\\', 2
    $base = switch ($parts[0].ToUpperInvariant()) {
        'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKU'  { [Microsoft.Win32.Registry]::Users }
        default { throw "Unsupported registry hive '$($parts[0])'." }
    }
    $key = $null
    try {
        $key = $base.CreateSubKey($parts[1])   # opens for writing, creating the key if needed
        $kind = [Microsoft.Win32.RegistryValueKind]$Value.Kind
        switch ($Value.Kind) {
            'Binary'      { $key.SetValue($Value.Name, [byte[]][Convert]::FromBase64String([string]$Value.Data), $kind) }
            'None'        { $key.SetValue($Value.Name, [byte[]][Convert]::FromBase64String([string]$Value.Data), $kind) }
            'MultiString' { $key.SetValue($Value.Name, [string[]]@(@($Value.Data) | ForEach-Object { [string]$_ }), $kind) }
            'DWord'       { $key.SetValue($Value.Name, [int]$Value.Data, $kind) }
            'QWord'       { $key.SetValue($Value.Name, [long]$Value.Data, $kind) }
            default       { $key.SetValue($Value.Name, [string]$Value.Data, $kind) }
        }
        Write-Log -Message ('Restored {0}\{1} = {2}' -f $Path, $Value.Name, (Format-SnapshotValue $Value)) -Level CHANGE
        $script:Summary.Restored++
    }
    catch { Add-Failure -Target ('{0}\{1}' -f $Path, $Value.Name) -Reason (Get-FailureReason $_) }
    finally { if ($key) { $key.Close() } }
}

function Get-RegistryLocationSnapshot {
    param($Location)
    $paths = if ($Location.Recurse) { @(Get-RegistryKeyPaths -Path $Location.Path) }
             elseif (Test-RegistryKeyExists $Location.Path) { @($Location.Path) } else { @() }
    $keys = foreach ($kp in $paths) {
        $vals = @(Get-RegistryValueSet -Path $kp | Where-Object { $_.Name -ne '' -and $_.Name -match $Location.Filter } |
                  ForEach-Object { ConvertTo-SnapshotValue -Name $_.Name -Value $_.Value -Kind ([string]$_.Kind) })
        [pscustomobject]@{ Path = $kp; Values = $vals }
    }
    [pscustomobject]@{
        Path = $Location.Path; Filter = $Location.Filter; Recurse = [bool]$Location.Recurse
        CleanupEmpty = [bool]$Location.CleanupEmpty; Keys = @($keys)
    }
}

function Get-PolicyFileTargets {
    <# The two standard Local Group Policy files (even if absent) plus any per-user/group ones. #>
    $gp = Join-Path $env:SystemRoot 'System32\GroupPolicy'
    [pscustomobject]@{ Path = (Join-Path $gp 'Machine\Registry.pol'); Scope = 'Machine' }
    [pscustomobject]@{ Path = (Join-Path $gp 'User\Registry.pol'); Scope = 'User' }
    foreach ($f in @(Get-LocalPolicyFiles | Where-Object { $_.Path -like '*\GroupPolicyUsers\*' })) {
        [pscustomobject]@{ Path = $f.Path; Scope = $f.Scope }
    }
}

function Test-PolEntryTracked {
    param([string]$Scope, $Entry)
    $key = $Entry.Key.TrimEnd('\')
    $eff = $Entry.ValueName -replace '^\*\*del\.', ''
    return [bool]((Find-PolicyDef -Scope $Scope -Key $key -Name $eff) -or (Test-IsSweepKey -Scope $Scope -Key $key))
}

function Get-PolFileSnapshot {
    <# Windows Update entries of one Registry.pol, stored as their raw bytes (base64). #>
    param([string]$Path, [string]$Scope)
    $snap = [pscustomobject]@{ Path = $Path; Scope = $Scope; Exists = $false; Unparsed = $false; Entries = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $snap }
    $snap.Exists = $true
    try { $pol = Read-RegistryPolFile -FilePath $Path }
    catch {
        Write-Log -Message ('Snapshot: {0} could not be parsed and will not be restored: {1}' -f $Path, $_.Exception.Message) -Level WARN
        $snap.Unparsed = $true
        return $snap
    }
    $snap.Entries = @($pol.Entries | Where-Object { Test-PolEntryTracked -Scope $Scope -Entry $_ } |
                      ForEach-Object { [Convert]::ToBase64String($pol.Bytes, $_.Start, $_.Length) })
    return $snap
}

function Get-HostsUpdateLines {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($hostsPath, [System.Text.Encoding]::Default)) {
        if (Test-HostsLineBlocksUpdate $line) { $line.Trim() }
    }
}

function Get-ConfigurationSnapshot {
    <# Captures everything the script manages. Throws on read errors so an incomplete backup is never reported as complete. #>
    param([string]$Label = 'Manual', [string]$Description = '')
    $sids = @(Get-LoadedUserSids)
    $registry = foreach ($loc in @(Get-TrackedRegistryLocations -Sids $sids)) { Get-RegistryLocationSnapshot -Location $loc }
    $pol = foreach ($t in @(Get-PolicyFileTargets)) { Get-PolFileSnapshot -Path $t.Path -Scope $t.Scope }
    $services = foreach ($d in (Get-ServiceDefinitions)) { [pscustomobject]@{ Name = $d.Name; StartMode = (Get-ServiceStartMode -Name $d.Name) } }
    $tasks = foreach ($t in $script:TaskDefs) {
        $state = 'Missing'
        try { $state = [string](Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop).State }
        catch { Write-Log -Message ('Snapshot: task {0}{1} not found.' -f $t.Path, $t.Name) -Level DEBUG }
        [pscustomobject]@{ Path = $t.Path; Name = $t.Name; State = $state }
    }
    $fwOk = $true
    $fw = @()
    try {
        $fw = @(Get-UpdateFirewallRules | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Enabled = ([string]$_.Enabled -eq 'True') }
        })
    }
    catch {
        $fwOk = $false
        Write-Log -Message ('Snapshot: firewall rules unavailable ({0}); they will not be restored from this backup.' -f $_.Exception.Message) -Level WARN
    }
    [pscustomobject]@{
        SnapshotVersion   = $script:SnapshotVersion
        ToolVersion       = $script:ToolVersion
        Created           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Computer          = $env:COMPUTERNAME
        OS                = ('{0} {1} build {2}' -f $script:OSInfo.Name, $script:OSInfo.DisplayVersion, $script:OSInfo.FullBuild)
        Label             = $Label
        Description       = $Description
        UserSids          = $sids
        Registry          = @($registry)
        PolicyFiles       = @($pol)
        Services          = @($services)
        Tasks             = @($tasks)
        FirewallAvailable = $fwOk
        Firewall          = $fw
        HostsLines        = @(Get-HostsUpdateLines)
    }
}

function Get-BackupLabelText {
    param([string]$Label)
    switch ($Label) {
        'Manual'          { return 'Manual backup' }
        'RemoveBlocking'  { return 'Automatic, before option 2' }
        'RestoreDefaults' { return 'Automatic, before option 3' }
        'Components'      { return 'Automatic, before option 4' }
        'RestoreAll'      { return 'Automatic, before option 5' }
        'CompleteRepair'  { return 'Automatic, before option 6' }
        'BeforeRestore'   { return 'Automatic, before a restore' }
        'Hosts'           { return 'Automatic, before a hosts-file edit' }
    }
    return $Label
}

function Get-AvailableBackups {
    <# Every restorable backup (folders with snapshot.json) from all sessions, newest first. #>
    if (-not (Test-Path -LiteralPath $script:BaseDir)) { return }
    $found = foreach ($session in @(Get-ChildItem -LiteralPath $script:BaseDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($b in @(Get-ChildItem -LiteralPath $session.FullName -Directory -Filter 'Backup-*' -ErrorAction SilentlyContinue)) {
            $json = Join-Path $b.FullName 'snapshot.json'
            if (-not (Test-Path -LiteralPath $json)) { continue }
            try {
                $j = Get-Content -LiteralPath $json -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                [pscustomobject]@{ Folder = $b.FullName; Created = [string]$j.Created; Label = [string]$j.Label; Description = [string]$j.Description; Computer = [string]$j.Computer }
            }
            catch { Write-Log -Message ('Unreadable backup {0}: {1}' -f $json, $_.Exception.Message) -Level WARN }
        }
    }
    $found | Sort-Object Created -Descending
}

function Get-RestorePlan {
    <# Compares a snapshot with the current state. Returns Changes, CleanupKeys and Warnings. #>
    param($Snapshot)
    $changes = New-Object System.Collections.Generic.List[object]
    $cleanup = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $sids = @(Get-LoadedUserSids)

    # ---- Registry: every location in the backup plus every location tracked now.
    $locs = [ordered]@{}
    foreach ($l in @($Snapshot.Registry)) { $locs[('{0}|{1}' -f $l.Path, $l.Filter).ToLowerInvariant()] = [pscustomobject]@{ Def = $l; Backup = $l } }
    foreach ($l in @(Get-TrackedRegistryLocations -Sids $sids)) {
        $id = ('{0}|{1}' -f $l.Path, $l.Filter).ToLowerInvariant()
        if (-not $locs.Contains($id)) { $locs[$id] = [pscustomobject]@{ Def = $l; Backup = $null } }
    }
    foreach ($entry in $locs.Values) {
        $def = $entry.Def
        if ($def.Path -match '^HKU\\([^\\]+)\\' -and ($sids -notcontains $Matches[1])) {
            if ($entry.Backup -and @($entry.Backup.Keys | ForEach-Object { @($_.Values) }).Count -gt 0) {
                $warnings.Add(('User {0} is not signed in; their user-level Windows Update policies were not restored.' -f $Matches[1]))
            }
            continue
        }
        $current = Get-RegistryLocationSnapshot -Location $def
        $bKeys = @{}; $cKeys = @{}
        if ($entry.Backup) { foreach ($k in @($entry.Backup.Keys)) { $bKeys[$k.Path.ToLowerInvariant()] = $k } }
        foreach ($k in @($current.Keys)) { $cKeys[$k.Path.ToLowerInvariant()] = $k }
        foreach ($kp in @(@($bKeys.Keys) + @($cKeys.Keys) | Select-Object -Unique)) {
            $bv = @{}; $cv = @{}
            $keyPath = if ($bKeys.ContainsKey($kp)) { $bKeys[$kp].Path } else { $cKeys[$kp].Path }
            if ($bKeys.ContainsKey($kp)) { foreach ($v in @($bKeys[$kp].Values)) { $bv[$v.Name.ToLowerInvariant()] = $v } }
            if ($cKeys.ContainsKey($kp)) { foreach ($v in @($cKeys[$kp].Values)) { $cv[$v.Name.ToLowerInvariant()] = $v } }
            foreach ($n in @($cv.Keys)) {
                if (-not $bv.ContainsKey($n)) {
                    $changes.Add([pscustomobject]@{
                        Type = 'RegDelete'; Path = $keyPath; Name = $cv[$n].Name
                        Display = ('Remove  {0}\{1}  (now {2}; absent in backup)' -f $keyPath, $cv[$n].Name, (Format-SnapshotValue $cv[$n]))
                    })
                }
            }
            foreach ($n in @($bv.Keys)) {
                $now = if ($cv.ContainsKey($n)) { $cv[$n] } else { $null }
                if ((Get-SnapshotValueSignature $now) -ne (Get-SnapshotValueSignature $bv[$n])) {
                    $changes.Add([pscustomobject]@{
                        Type = 'RegSet'; Path = $keyPath; Value = $bv[$n]
                        Display = ('Set     {0}\{1} = {2}  (now {3})' -f $keyPath, $bv[$n].Name, (Format-SnapshotValue $bv[$n]), (Format-SnapshotValue $now))
                    })
                }
            }
            if (($def.CleanupEmpty -or $def.Recurse) -and -not $bKeys.ContainsKey($kp)) { $cleanup.Add($keyPath) }
        }
    }

    # ---- Local Group Policy files: Windows Update entries only; every other entry is kept.
    $polTargets = [ordered]@{}
    foreach ($pf in @($Snapshot.PolicyFiles)) { $polTargets[$pf.Path.ToLowerInvariant()] = [pscustomobject]@{ Path = $pf.Path; Scope = $pf.Scope; Backup = $pf } }
    foreach ($t in @(Get-PolicyFileTargets)) {
        if (-not $polTargets.Contains($t.Path.ToLowerInvariant())) { $polTargets[$t.Path.ToLowerInvariant()] = [pscustomobject]@{ Path = $t.Path; Scope = $t.Scope; Backup = $null } }
    }
    foreach ($t in $polTargets.Values) {
        if ($t.Backup -and $t.Backup.Unparsed) { $warnings.Add(('{0} could not be read when the backup was made; it was not restored.' -f $t.Path)); continue }
        $wanted = if ($t.Backup) { @($t.Backup.Entries) } else { @() }
        $now = Get-PolFileSnapshot -Path $t.Path -Scope $t.Scope
        if ($now.Unparsed) { $warnings.Add(('{0} cannot be parsed now; it was not restored.' -f $t.Path)); continue }
        if ((@($now.Entries) -join ',') -ne ($wanted -join ',')) {
            $changes.Add([pscustomobject]@{
                Type = 'PolFile'; Path = $t.Path; Scope = $t.Scope; Entries = $wanted
                Display = ('Local Group Policy {0}: restore {1} Windows Update entr(ies) (now {2})' -f $t.Path, $wanted.Count, @($now.Entries).Count)
            })
        }
    }

    # ---- Services (start type).
    foreach ($b in @($Snapshot.Services)) {
        if ($b.StartMode -notin @('Manual', 'Automatic', 'AutomaticDelayed', 'Disabled')) { continue }
        $cur = Get-ServiceStartMode -Name $b.Name
        if ($cur -eq 'Missing') { $warnings.Add(('Service {0} no longer exists; start type not restored.' -f $b.Name)); continue }
        if ($cur -ne $b.StartMode) {
            $note = if ($b.StartMode -eq 'Disabled') { '  [the backup had this service DISABLED]' } else { '' }
            $changes.Add([pscustomobject]@{ Type = 'Service'; Name = $b.Name; StartMode = $b.StartMode; Display = ('Service {0}: {1} -> {2}{3}' -f $b.Name, $cur, $b.StartMode, $note) })
        }
    }

    # ---- Scheduled tasks (enabled / disabled).
    foreach ($b in @($Snapshot.Tasks)) {
        if ($b.State -eq 'Missing') { continue }
        $cur = 'Missing'
        try { $cur = [string](Get-ScheduledTask -TaskPath $b.Path -TaskName $b.Name -ErrorAction Stop).State }
        catch { $warnings.Add(('Task {0}{1} not found; not restored.' -f $b.Path, $b.Name)); continue }
        $wantDisabled = ($b.State -eq 'Disabled')
        if ($wantDisabled -ne ($cur -eq 'Disabled')) {
            $changes.Add([pscustomobject]@{
                Type = 'Task'; Path = $b.Path; Name = $b.Name; Enable = (-not $wantDisabled)
                Display = ('Task {0}{1}: {2}' -f $b.Path, $b.Name, $(if ($wantDisabled) { 'disable (as in backup)' } else { 'enable (as in backup)' }))
            })
        }
    }

    # ---- Firewall rules (enabled state only; rules are never created or deleted).
    if ($Snapshot.FirewallAvailable) {
        $curRules = @()
        try { $curRules = @(Get-UpdateFirewallRules) }
        catch { $warnings.Add(('Firewall rules could not be read ({0}); not restored.' -f $_.Exception.Message)) }
        $backupNames = @($Snapshot.Firewall | ForEach-Object Name)
        foreach ($b in @($Snapshot.Firewall)) {
            $r = @($curRules | Where-Object { $_.Name -eq $b.Name })
            if ($r.Count -eq 0) { $warnings.Add(('Firewall rule "{0}" no longer exists; not restored.' -f $b.DisplayName)); continue }
            if ((([string]$r[0].Enabled -eq 'True')) -ne [bool]$b.Enabled) {
                $changes.Add([pscustomobject]@{ Type = 'Firewall'; Name = $b.Name; DisplayName = $b.DisplayName; Enable = [bool]$b.Enabled
                    Display = ('Firewall rule "{0}": {1}' -f $b.DisplayName, $(if ($b.Enabled) { 'enable (as in backup)' } else { 'disable (as in backup)' })) })
            }
        }
        foreach ($r in ($curRules | Where-Object { [string]$_.Enabled -eq 'True' -and $backupNames -notcontains $_.Name })) {
            $changes.Add([pscustomobject]@{ Type = 'Firewall'; Name = $r.Name; DisplayName = $r.DisplayName; Enable = $false
                Display = ('Firewall rule "{0}": disable (created after the backup)' -f $r.DisplayName) })
        }
    }

    # ---- Hosts file: Windows Update lines only.
    $nowLines = @(Get-HostsUpdateLines)
    $backupLines = @($Snapshot.HostsLines)
    foreach ($l in $nowLines) {
        if ($backupLines -notcontains $l) { $changes.Add([pscustomobject]@{ Type = 'HostsComment'; Line = $l; Display = ('Hosts: comment out "{0}" (not in backup)' -f $l) }) }
    }
    foreach ($l in $backupLines) {
        if ($nowLines -notcontains $l) { $changes.Add([pscustomobject]@{ Type = 'HostsUncomment'; Line = $l; Display = ('Hosts: re-activate "{0}" (as in backup)' -f $l) }) }
    }

    [pscustomobject]@{ Changes = $changes; CleanupKeys = $cleanup; Warnings = $warnings }
}

function Set-PolFileTrackedEntries {
    <# Rewrites one Registry.pol: current non-Windows-Update entries + the backed-up Windows Update entries. #>
    param([string]$Path, [string]$Scope, [string[]]$Entries)
    $exists = Test-Path -LiteralPath $Path
    $kept = @()
    $bytes = $null
    if ($exists) {
        $pol = Read-RegistryPolFile -FilePath $Path
        $bytes = $pol.Bytes
        $kept = @($pol.Entries | Where-Object { -not (Test-PolEntryTracked -Scope $Scope -Entry $_) })
    }
    if (-not $exists -and @($Entries).Count -eq 0) { return }
    $ms = New-Object System.IO.MemoryStream
    try {
        $header = [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0)
        $ms.Write($header, 0, 8)
        foreach ($e in $kept) { $ms.Write($bytes, $e.Start, $e.Length) }
        foreach ($b64 in @($Entries)) { $raw = [Convert]::FromBase64String($b64); $ms.Write($raw, 0, $raw.Length) }
        $newBytes = $ms.ToArray()
    }
    finally { $ms.Dispose() }
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $tmp = $Path + '.wurepair.tmp'
    [System.IO.File]::WriteAllBytes($tmp, $newBytes)
    try {
        $null = Read-RegistryPolFile -FilePath $tmp
        [System.IO.File]::Copy($tmp, $Path, $true)
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }   # temp file cleanup only
    Write-Log -Message ('Restored {0} Windows Update entr(ies) in {1}' -f @($Entries).Count, $Path) -Level CHANGE
    $script:Summary.Restored++
}

function Set-HostsUpdateLines {
    <# Comments out / re-activates specific Windows Update hosts lines. Other lines are untouched. #>
    param([object[]]$Changes)
    if (@($Changes).Count -eq 0) { return }
    $file = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    try {
        $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::Default)
        $stamp = Get-Date -Format 'yyyy-MM-dd'
        $done = 0
        foreach ($c in $Changes) {
            $hit = $false
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($c.Type -eq 'HostsComment' -and $lines[$i].Trim() -eq $c.Line -and (Test-HostsLineBlocksUpdate $lines[$i])) {
                    $lines[$i] = ('# [WU Policy Repair {0}] {1}' -f $stamp, $lines[$i]); $hit = $true; break
                }
                if ($c.Type -eq 'HostsUncomment' -and $lines[$i] -match '^# \[WU Policy Repair [^\]]*\] (.*)$' -and $Matches[1].Trim() -eq $c.Line) {
                    $lines[$i] = $Matches[1]; $hit = $true; break
                }
            }
            if ($hit) { $done++ } else { Add-SummaryWarning ('Hosts line "{0}" not found; not restored.' -f $c.Line) }
        }
        if ($done -gt 0) {
            [System.IO.File]::WriteAllLines($file, $lines, [System.Text.Encoding]::Default)
            $script:Summary.Restored += $done
            Write-Log -Message ('Updated {0} Windows Update line(s) in {1}' -f $done, $file) -Level CHANGE
            $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns 2>&1
        }
    }
    catch { Add-Failure -Target $file -Reason (Get-FailureReason $_) }
}

function Invoke-RestorePlan {
    param($Plan)
    $c = @($Plan.Changes)
    # Local Group Policy first, so a policy refresh cannot fight the registry restore.
    foreach ($x in ($c | Where-Object Type -eq 'PolFile')) {
        try { Set-PolFileTrackedEntries -Path $x.Path -Scope $x.Scope -Entries @($x.Entries) }
        catch { Add-Failure -Target $x.Path -Reason ('Local Group Policy file not restored: {0}' -f (Get-FailureReason $_)) }
    }
    foreach ($x in ($c | Where-Object Type -eq 'RegDelete')) {
        Remove-RegistryPolicyValue -Path $x.Path -Name $x.Name -Reason '[not in backup]' -Counter 'Restored'
    }
    foreach ($x in ($c | Where-Object Type -eq 'RegSet')) { Set-RegistryValueFromSnapshot -Path $x.Path -Value $x.Value }
    foreach ($x in ($c | Where-Object Type -eq 'Service')) {
        if (Repair-ServiceStartType -Name $x.Name -StartMode $x.StartMode) { $script:Summary.ServicesRepaired-- ; $script:Summary.Restored++ }
    }
    foreach ($x in ($c | Where-Object Type -eq 'Task')) {
        try {
            if ($x.Enable) { Enable-ScheduledTask -TaskPath $x.Path -TaskName $x.Name -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $x.Path -TaskName $x.Name -ErrorAction Stop | Out-Null }
            Write-Log -Message ('Task {0}{1} {2}' -f $x.Path, $x.Name, $(if ($x.Enable) { 'enabled' } else { 'disabled' })) -Level CHANGE
            $script:Summary.Restored++
        }
        catch { Add-Failure -Target ('Scheduled task ' + $x.Path + $x.Name) -Reason (Get-FailureReason $_) }
    }
    foreach ($x in ($c | Where-Object Type -eq 'Firewall')) {
        try {
            if ($x.Enable) { Enable-NetFirewallRule -Name $x.Name -ErrorAction Stop } else { Disable-NetFirewallRule -Name $x.Name -ErrorAction Stop }
            Write-Log -Message ('Firewall rule "{0}" {1}' -f $x.DisplayName, $(if ($x.Enable) { 'enabled' } else { 'disabled' })) -Level CHANGE
            $script:Summary.Restored++
        }
        catch { Add-Failure -Target ('Firewall rule ' + $x.DisplayName) -Reason (Get-FailureReason $_) }
    }
    Set-HostsUpdateLines -Changes @($c | Where-Object { $_.Type -in @('HostsComment', 'HostsUncomment') })
    # Keys that did not exist at backup time: remove them if nothing is left (deepest first).
    foreach ($k in (@($Plan.CleanupKeys) | Sort-Object Length -Descending)) { Remove-EmptyRegistryKey $k }
    Restart-UpdateAgent
}

function Backup-CurrentConfiguration {
    <# Option 7: a named backup you can restore later with option 8. #>
    [CmdletBinding()]
    param()
    Write-Section 'Back up current Windows Update configuration'
    Write-Host '  Saves every Windows Update setting this tool manages, so you can return to'
    Write-Host '  exactly this state later with option 8. Nothing is changed.'
    $desc = [string](Read-Host '  Optional description (Enter to skip)')
    $dir = Backup-WindowsUpdatePolicies -Label 'Manual' -Description $desc.Trim()
    if ($dir) { Write-Log -Message 'Backup ready. Use option 8 to restore it.' -Level SUCCESS }
}

function Restore-WindowsUpdateConfiguration {
    <# Option 8: return every managed setting to the state recorded in a backup. #>
    [CmdletBinding()]
    param()
    Write-Section 'Restore Windows Update configuration from a backup'
    $backups = @(Get-AvailableBackups | Select-Object -First 20)
    if ($backups.Count -eq 0) { Write-Host ('  No restorable backups found under {0}.' -f $script:BaseDir) -ForegroundColor Yellow }
    $i = 0
    foreach ($b in $backups) {
        $i++
        $extra = if ($b.Description) { (' - "{0}"' -f $b.Description) } else { '' }
        $pc = if ($b.Computer -and $b.Computer -ne $env:COMPUTERNAME) { (' [from {0}]' -f $b.Computer) } else { '' }
        Write-Host ('  {0,2}. {1}  {2}{3}{4}' -f $i, $b.Created, (Get-BackupLabelText $b.Label), $extra, $pc)
    }
    Write-Host '   P. Enter the path of a backup folder'
    Write-Host ''
    $sel = ([string](Read-Host '  Select a backup (Enter to cancel)')).Trim()
    if (-not $sel) { Write-Log -Message 'Restore cancelled.' -Level WARN; $script:Summary.Cancelled = $true; return }
    $folder = $null
    if ($sel -match '^[Pp]$') { $folder = ([string](Read-Host '  Backup folder path')).Trim().Trim('"') }
    elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $backups.Count) { $folder = $backups[[int]$sel - 1].Folder }
    else { Write-Host '  Invalid selection.' -ForegroundColor Yellow; $script:Summary.Cancelled = $true; return }

    $json = Join-Path $folder 'snapshot.json'
    if (-not (Test-Path -LiteralPath $json)) {
        Add-Failure -Target $folder -Reason 'No snapshot.json in this folder (backups made before v1.2.0 can only be restored manually from their .reg files).'
        return
    }
    try { $snap = Get-Content -LiteralPath $json -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json }
    catch { Add-Failure -Target $json -Reason ('Unreadable snapshot: {0}' -f $_.Exception.Message); return }
    if ([int]$snap.SnapshotVersion -gt $script:SnapshotVersion) {
        Add-Failure -Target $json -Reason ('Snapshot format {0} is newer than this script supports ({1}). Use a newer version of the script.' -f $snap.SnapshotVersion, $script:SnapshotVersion)
        return
    }
    Write-Log -Message ('Restoring from {0} ({1}, {2}, created {3} by v{4})' -f $folder, (Get-BackupLabelText $snap.Label), $snap.OS, $snap.Created, $snap.ToolVersion)
    if ($snap.Computer -and $snap.Computer -ne $env:COMPUTERNAME) {
        Write-Host ('  This backup was made on {0}, not on this PC ({1}).' -f $snap.Computer, $env:COMPUTERNAME) -ForegroundColor Yellow
        if (-not (Read-YesNo -Prompt '  Apply it here anyway?' -Default 'N')) { $script:Summary.Cancelled = $true; return }
    }

    $plan = Get-RestorePlan -Snapshot $snap
    foreach ($w in $plan.Warnings) { Add-SummaryWarning $w }
    if ($plan.Changes.Count -eq 0) {
        Write-Log -Message 'The current configuration already matches this backup. Nothing to restore.' -Level SUCCESS
        return
    }
    Write-Host ''
    Write-Host ('  {0} change(s) are needed to return to this backup:' -f $plan.Changes.Count) -ForegroundColor White
    $n = 0
    foreach ($x in $plan.Changes) {
        $n++
        Write-Host ('  {0,3}. {1}' -f $n, $x.Display) -ForegroundColor Yellow
        Write-Log -Message ('Planned restore: {0}' -f $x.Display) -NoConsole
    }
    Write-Host ''
    if (-not (Read-YesNo -Prompt '  Restore this backup?' -Default 'N')) {
        Write-Log -Message 'Restore cancelled. No changes made.' -Level WARN
        $script:Summary.Cancelled = $true
        return
    }
    # The current state is backed up first, so a restore can itself be undone.
    if (-not (Backup-WindowsUpdatePolicies -Label 'BeforeRestore' -Description ('Before restoring {0}' -f $snap.Created))) {
        Write-Log -Message 'Backup of the current state failed - restore aborted without changes.' -Level ERROR
        return
    }
    Invoke-RestorePlan -Plan $plan
    Write-Log -Message 'Restore finished. Restart Windows so Settings and Windows Update pick up the restored configuration.' -Level SUCCESS
}

#endregion

#region ---------------------------------------------------------------- Remediation engine

function Get-RemediationPlan {
    <#
        Blocking : values that block or restrict updates (+ disabled services/tasks, active pause)
        Defaults : every documented core policy value + anything blocking (policy locations only)
                   + the Windows Update policy cache
        All      : everything with an action, including unrecognized values in WU policy keys,
                   Delivery Optimization, user-level, legacy, orphaned MDM and pause state
    #>
    param([ValidateSet('Blocking', 'Defaults', 'All')][string]$Mode, $State)
    foreach ($f in $State.Findings) {
        if (-not $f.Action -or $f.Action.Type -eq 'Hosts') { continue }
        $t = $f.Action.Type
        $bad = $f.Severity -in @('Block', 'Restrict')
        $include = switch ($Mode) {
            'Blocking' { $bad }
            'Defaults' { (($t -in @('RegValue', 'PolEntry')) -and ($f.Tier -notin @('State', 'Tamper')) -and ($bad -or $f.Tier -eq 'Standard')) -or $t -eq 'CacheKey' }
            'All'      { $true }
        }
        if ($include) { $f }
    }
}

function Show-RemediationPlan {
    param([object[]]$Findings)
    Write-Host ''
    Write-Host ('  The following {0} change(s) will be made:' -f $Findings.Count) -ForegroundColor White
    $i = 0
    foreach ($f in $Findings) {
        $i++
        $verb = switch ($f.Action.Type) {
            'RegValue' { 'Remove value ' }
            'PolEntry' { 'Remove GPO   ' }
            'Service'  { 'Service      ' }
            'Task'     { 'Task         ' }
            'CacheKey' { 'Clear cache  ' }
            'FirewallRule' { 'Firewall     ' }
            default    { 'Change       ' }
        }
        $color = switch ($f.Status) { 'POTENTIALLY BLOCKING' { 'Red' } 'ORGANIZATION MANAGED' { 'Magenta' } default { 'Yellow' } }
        Write-Host ('  {0,3}. {1}{2}' -f $i, $verb, $f.Action.Display) -ForegroundColor $color
        Write-Host ('       current: {0}   [{1}]' -f $f.Value, $f.Status) -ForegroundColor DarkGray
        Write-Log -Message ('Planned: {0} (current: {1}, {2})' -f $f.Action.Display, $f.Value, $f.Status) -NoConsole
    }
    Write-Host ''
}

function Confirm-ManagedDeviceChange {
    param($Management)
    if (-not $Management.IsManaged) { return $true }
    Write-Host ''
    Write-Host '  ================= ORGANIZATION-MANAGED DEVICE =================' -ForegroundColor Magenta
    if ($Management.DomainJoined) { Write-Host ('  - Joined to Active Directory domain {0} (Group Policy)' -f $Management.Domain) -ForegroundColor Magenta }
    if ($Management.EntraJoined)  { Write-Host '  - Joined to Microsoft Entra ID' -ForegroundColor Magenta }
    if ($Management.MdmEnrolled)  { Write-Host ('  - Enrolled in MDM: {0}' -f ($Management.MdmProviders -join ', ')) -ForegroundColor Magenta }
    if ($Management.ConfigMgr)    { Write-Host '  - Configuration Manager client installed' -ForegroundColor Magenta }
    Write-Host '  Your organization controls Windows Update on this PC. Removed policies' -ForegroundColor Magenta
    Write-Host '  will probably return at the next policy refresh / MDM sync, and changing' -ForegroundColor Magenta
    Write-Host '  them may be against your IT policy. MDM-delivered values are never modified.' -ForegroundColor Magenta
    Write-Host '  ================================================================' -ForegroundColor Magenta
    $answer = Read-Host '  Type YES to continue anyway, or press Enter to cancel'
    $ok = ($answer -ceq 'YES')
    Write-Log -Message ('Managed-device confirmation: {0}' -f $(if ($ok) { 'accepted' } else { 'declined' })) -Level $(if ($ok) { 'WARN' } else { 'INFO' })
    return $ok
}

function Repair-ServiceStartType {
    <# Sets a service start type through the Service Control Manager (repair: Disabled -> default). #>
    param([string]$Name, [ValidateSet('Manual', 'Automatic', 'AutomaticDelayed', 'Disabled')][string]$StartMode)
    # 'Disabled' is only ever requested by a restore that puts back a backed-up state.
    $scArg = @{ Manual = 'demand'; Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Disabled = 'disabled' }[$StartMode]
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    $out = & $sc config $Name start= $scArg 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Log -Message ('Service {0} start type set to {1}' -f $Name, $StartMode) -Level CHANGE
        $script:Summary.ServicesRepaired++
        return $true
    }
    # Protected services (e.g. WaaSMedicSvc) deny reconfiguration even to administrators.
    # That protection is deliberately NOT bypassed.
    $reason = if ($code -eq 5) {
        'Access denied - protected service. Repair with DISM /RestoreHealth or an in-place upgrade.'
    } else { ('sc.exe exit code {0}: {1}' -f $code, $out.Trim()) }
    Add-Failure -Target ('HKLM\SYSTEM\CurrentControlSet\Services\' + $Name) -Reason $reason
    return $false
}

function Enable-UpdateTask {
    param([string]$TaskPath, [string]$TaskName)
    try {
        Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log -Message ('Enabled scheduled task {0}{1}' -f $TaskPath, $TaskName) -Level CHANGE
        $script:Summary.PoliciesReset++
    }
    catch {
        $reason = if ($_.Exception.Message -match 'denied|0x80070005') { 'Access denied (task protected by Windows)' } else { $_.Exception.Message }
        Add-Failure -Target ('Scheduled task ' + $TaskPath + $TaskName) -Reason $reason
    }
}

function Clear-UpdatePolicyCache {
    <#
        Deletes Windows Update's cached copy of Group Policy (UpdatePolicy\GPCache). This is the
        only key tree the script ever deletes: it is a cache, exported first, and Windows Update
        rebuilds it from the policy that is actually in force.
    #>
    param([string]$Path)
    if ($Path -ne ('HKLM\' + $script:Paths.GPCache)) { throw "Refusing to delete unexpected key $Path" }
    try {
        $idx = $Path.LastIndexOf('\')
        $parent = Open-RegistryKey -Path $Path.Substring(0, $idx) -Writable
        if ($null -eq $parent) { return }
        try { $parent.DeleteSubKeyTree($Path.Substring($idx + 1), $false) } finally { $parent.Close() }
        Write-Log -Message ('Cleared Windows Update policy cache {0}' -f $Path) -Level CHANGE
        $script:Summary.PoliciesReset++
    }
    catch { Add-Failure -Target $Path -Reason (Get-FailureReason $_) }
}

function Disable-UpdateFirewallRule {
    param([string]$RuleName, [string]$DisplayName)
    try {
        Disable-NetFirewallRule -Name $RuleName -ErrorAction Stop
        Write-Log -Message ('Disabled firewall rule "{0}" ({1})' -f $DisplayName, $RuleName) -Level CHANGE
        $script:Summary.PoliciesReset++
    }
    catch { Add-Failure -Target ('Firewall rule ' + $DisplayName) -Reason (Get-FailureReason $_) }
}

function Restart-UpdateAgent {
    <# Windows Update reads policy when the service starts; restart it if running so changes apply now. #>
    $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue   # missing service is reported by the audit
    if ($svc -and $svc.Status -eq 'Running') {
        try {
            Restart-Service -Name 'wuauserv' -Force -ErrorAction Stop
            Write-Log -Message 'Restarted Windows Update service so it reloads policy.'
        }
        catch { Add-SummaryWarning ('Could not restart wuauserv: {0}' -f $_.Exception.Message) }
    }
    else { Write-Log -Message 'Windows Update service is not running; it reads the new configuration when it next starts.' }
}

function Remove-EmptyPolicyKeys {
    <# After a full restore, remove policy keys left completely empty (absent key = not configured). #>
    param([string[]]$Sids)
    Remove-EmptyRegistryKey ('HKLM\' + $script:Paths.AU)
    Remove-EmptyRegistryKey ('HKLM\' + $script:Paths.WU)
    Remove-EmptyRegistryKey ('HKLM\' + $script:Paths.DO)
    Remove-EmptyRegistryKey ('HKLM\' + $script:Paths.DriverSearch)
    foreach ($sid in $Sids) { Remove-EmptyRegistryKey ('HKU\{0}\{1}' -f $sid, $script:Paths.UserWU) }
}

function Invoke-RemediationPlan {
    <# Shows, confirms, backs up and applies a list of findings. Returns $true when applied (or nothing to do). #>
    param(
        [object[]]$Findings, [string]$Label, $Management,
        [switch]$Unattended, [switch]$SkipBackup, [switch]$NoPreview, [switch]$RemoveEmptyKeys, [string[]]$Sids = @()
    )
    $Findings = @($Findings | Where-Object { $_ })
    if ($Findings.Count -eq 0) {
        Write-Log -Message 'Nothing to change: no matching settings found (already default / not configured).' -Level SUCCESS
        return $true
    }
    if (-not $NoPreview) { Show-RemediationPlan -Findings $Findings }
    if (-not $Unattended) {
        if ($Management.IsManaged -and -not (Confirm-ManagedDeviceChange -Management $Management)) {
            Write-Log -Message 'Cancelled. No changes made.' -Level WARN
            $script:Summary.Cancelled = $true
            return $false
        }
        if (-not (Read-YesNo -Prompt '  Apply these changes?' -Default 'N')) {
            Write-Log -Message 'Cancelled by user. No changes made.' -Level WARN
            $script:Summary.Cancelled = $true
            return $false
        }
    }
    if (-not $SkipBackup) {
        if (-not (Backup-WindowsUpdatePolicies -Label $Label)) {
            Write-Log -Message 'Backup failed - aborting without making any change.' -Level ERROR
            return $false
        }
    }

    # 1) Local Group Policy files first, so a Group Policy refresh cannot re-create removed values.
    $polGroups = @($Findings | Where-Object { $_.Action.Type -eq 'PolEntry' } | Group-Object { $_.Action.File })
    foreach ($g in $polGroups) {
        try {
            $n = Remove-RegistryPolEntries -FilePath $g.Name -Targets @($g.Group | ForEach-Object Action)
            $script:Summary.PoliciesReset += $n
        }
        catch { Add-Failure -Target $g.Name -Reason ('Local Group Policy file not modified: {0}' -f (Get-FailureReason $_)) }
    }

    # 2) Registry values, services, tasks.
    $changedPolicy = $polGroups.Count -gt 0
    foreach ($f in $Findings) {
        $act = $f.Action
        switch ($act.Type) {
            'RegValue' {
                Remove-RegistryPolicyValue -Path $act.Path -Name $act.Name -Reason ('[{0}]' -f $f.Status) -Counter $act.Counter -OrgManaged $f.OrgManaged
                foreach ($r in $act.Related) { Remove-RegistryPolicyValue -Path $act.Path -Name $r -Reason '[MDM metadata]' -Counter 'None' }
                $changedPolicy = $true
            }
            'Service' { $null = Repair-ServiceStartType -Name $act.ServiceName -StartMode $act.TargetMode }
            'Task'    { Enable-UpdateTask -TaskPath $act.TaskPath -TaskName $act.TaskName }
            'CacheKey' { Clear-UpdatePolicyCache -Path $act.Path; $changedPolicy = $true }
            'FirewallRule' { Disable-UpdateFirewallRule -RuleName $act.RuleName -DisplayName $f.Name }
        }
    }
    if ($RemoveEmptyKeys) { Remove-EmptyPolicyKeys -Sids $Sids }
    if ($changedPolicy) { Restart-UpdateAgent }
    return $true
}

function Invoke-HostsRemediation {
    <# Comments out (never deletes) hosts-file lines that redirect Windows Update endpoints. #>
    param($State, [switch]$Unattended, [bool]$Approved = $false)
    $hosts = @($State.Findings | Where-Object { $_.Action -and $_.Action.Type -eq 'Hosts' })
    if ($hosts.Count -eq 0) { return }
    Write-Host ''
    Write-Host '  Hosts-file entries redirecting Windows Update:' -ForegroundColor White
    foreach ($h in $hosts) { Write-Host ('    line {0}: {1}' -f ($h.Action.LineIndex + 1), $h.Action.Line.Trim()) -ForegroundColor Red }
    $go = if ($Unattended) { $Approved } else { Read-YesNo -Prompt '  Comment out these lines? (a backup copy is kept)' -Default 'Y' }
    if (-not $go) { Add-SummaryWarning 'Hosts-file entries blocking Windows Update were left unchanged.'; return }
    if (-not $script:Summary.BackupDir) {
        if (-not (Backup-WindowsUpdatePolicies -Label 'Hosts')) { return }
    }
    $file = $hosts[0].Action.File
    try {
        $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::Default)
        $stamp = Get-Date -Format 'yyyy-MM-dd'
        $changed = 0
        foreach ($h in $hosts) {
            $i = $h.Action.LineIndex
            if ($i -lt $lines.Length -and $lines[$i] -eq $h.Action.Line) {
                $lines[$i] = ('# [WU Policy Repair {0}] {1}' -f $stamp, $lines[$i])
                $changed++
            }
            else { Add-SummaryWarning ('Hosts line {0} changed since the audit; skipped.' -f ($i + 1)) }
        }
        if ($changed -gt 0) {
            [System.IO.File]::WriteAllLines($file, $lines, [System.Text.Encoding]::Default)
            $script:Summary.PoliciesReset += $changed
            Write-Log -Message ('Commented out {0} hosts-file line(s) in {1}' -f $changed, $file) -Level CHANGE
            $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns 2>&1
        }
    }
    catch { Add-Failure -Target $file -Reason (Get-FailureReason $_) }
}

#endregion

#region ---------------------------------------------------------------- Menu operations

function Remove-BlockingPolicies {
    <# Option 2: remove only settings that block or restrict Windows Update. #>
    [CmdletBinding()]
    param([switch]$Unattended, [switch]$SkipBackup, [bool]$FixHosts = $false)
    Write-Section 'Remove blocking / restrictive Windows Update policies'
    $state = Get-WindowsUpdateAudit -Quiet
    $plan = @(Get-RemediationPlan -Mode Blocking -State $state)
    $ok = Invoke-RemediationPlan -Findings $plan -Label 'RemoveBlocking' -Management $state.Management -Unattended:$Unattended -SkipBackup:$SkipBackup
    if ($ok) { Invoke-HostsRemediation -State $state -Unattended:$Unattended -Approved $FixHosts }
    Add-OrgSkippedFailures -State $state -Plan $plan -OnlyBad
}

function Add-OrgSkippedFailures {
    <# Reports organization-owned (MDM) settings that were deliberately not modified. #>
    param($State, $Plan, [switch]$OnlyBad)
    foreach ($f in $State.Findings) {
        if ($f.Action -or -not $f.OrgManaged) { continue }
        if ($OnlyBad -and $f.Severity -notin @('Block', 'Restrict')) { continue }
        Add-Failure -Target ('{0}\{1}' -f $f.Location, $f.Name) -Reason 'Managed by organization (MDM) - change it in the MDM console'
    }
}

function Reset-WindowsUpdatePolicies {
    <#
        Option 3 (-Mode Defaults): delete every documented Windows Update policy value, which is
        exactly what "Not configured" means. Option 5 (-Mode All): additionally clears Delivery
        Optimization download limits, user-level and legacy policies, unrecognized values in the
        Windows Update policy keys, orphaned MDM values, pause state and empty policy keys.
    #>
    [CmdletBinding()]
    param([ValidateSet('Defaults', 'All')][string]$Mode = 'Defaults', [switch]$Unattended, [switch]$SkipBackup, [bool]$FixHosts = $false)

    if ($Mode -eq 'Defaults') {
        Write-Section 'Restore Windows Update policies to OEM defaults'
        $state = Get-WindowsUpdateAudit -Quiet
        $plan = @(Get-RemediationPlan -Mode Defaults -State $state)
        $null = Invoke-RemediationPlan -Findings $plan -Label 'RestoreDefaults' -Management $state.Management -Unattended:$Unattended -SkipBackup:$SkipBackup
        Add-OrgSkippedFailures -State $state -Plan $plan -OnlyBad
        return
    }

    Write-Section 'Restore ALL Windows Update policies'
    $state = Get-WindowsUpdateAudit -Quiet
    $plan = @(Get-RemediationPlan -Mode All -State $state)
    $hostsCount = @($state.Findings | Where-Object { $_.Action -and $_.Action.Type -eq 'Hosts' }).Count
    if ($plan.Count -eq 0 -and $hostsCount -eq 0) {
        Write-Log -Message 'Nothing to change: Windows Update policy configuration is already at its default / not-configured state.' -Level SUCCESS
        Add-OrgSkippedFailures -State $state -Plan $plan
        return
    }
    if ($plan.Count -gt 0) { Show-RemediationPlan -Findings $plan }

    if (-not $Unattended) {
        Write-Host '  WARNING' -ForegroundColor Red
        Write-Host ''
        Write-Host '  This will remove Windows Update policy configuration and attempt' -ForegroundColor Yellow
        Write-Host '  to restore Windows Update to normal Windows/OEM behavior.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  If this computer is managed by an organization, some policies' -ForegroundColor Yellow
        Write-Host '  may return automatically.' -ForegroundColor Yellow
        Write-Host ''
        if (-not (Read-YesNo -Prompt '  Continue?' -Default 'N')) {
            Write-Log -Message 'Cancelled by user. No changes made.' -Level WARN
            $script:Summary.Cancelled = $true
            return
        }
        if ($state.Management.IsManaged -and -not (Confirm-ManagedDeviceChange -Management $state.Management)) {
            Write-Log -Message 'Cancelled. No changes made.' -Level WARN
            $script:Summary.Cancelled = $true
            return
        }
    }

    # Complete backup before anything is touched.
    if (-not $SkipBackup) {
        if (-not (Backup-WindowsUpdatePolicies -Label 'RestoreAll')) {
            Write-Log -Message 'Backup failed - aborting without making any change.' -Level ERROR
            return
        }
    }
    $null = Invoke-RemediationPlan -Findings $plan -Label 'RestoreAll' -Management $state.Management -Unattended -SkipBackup -NoPreview `
        -RemoveEmptyKeys -Sids $state.UserSids
    Invoke-HostsRemediation -State $state -Unattended:$Unattended -Approved $FixHosts
    Add-OrgSkippedFailures -State $state -Plan $plan
}

function Test-WindowsUpdateServices {
    <# Checks the services Windows Update depends on. -Repair re-enables Disabled ones; -StartRequired starts core services. #>
    [CmdletBinding()]
    param([switch]$Repair, [switch]$StartRequired, [switch]$Quiet)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($d in (Get-ServiceDefinitions)) {
        $svc = Get-Service -Name $d.Name -ErrorAction SilentlyContinue   # missing service handled below
        $mode = Get-ServiceStartMode -Name $d.Name
        $r = [pscustomobject]@{
            Name = $d.Name; Display = $d.Display; StartMode = $mode; DefaultMode = $d.Default
            Status = $(if ($svc) { [string]$svc.Status } else { 'Missing' }); Healthy = $true; Note = ''
        }
        if (-not $svc -or $mode -eq 'Missing') {
            $r.Healthy = -not $d.Required
            $r.Note = 'Not registered'
            if ($Repair -and $d.Required) { Add-Failure -Target $d.Name -Reason 'Service is missing - repair with DISM /RestoreHealth or an in-place upgrade' }
        }
        elseif ($mode -eq 'Disabled') {
            $r.Healthy = $false
            $r.Note = 'Disabled'
            if ($Repair -and (Repair-ServiceStartType -Name $d.Name -StartMode $d.Default)) {
                $r.StartMode = Get-ServiceStartMode -Name $d.Name
                $r.Healthy = $true
                $r.Note = 'Re-enabled'
            }
        }
        if ($StartRequired -and $d.Verify -and $svc -and $r.StartMode -ne 'Disabled') {
            try {
                $svc.Refresh()
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name $d.Name -ErrorAction Stop
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                }
                $r.Status = 'Running'
            }
            catch {
                $r.Healthy = $false
                $r.Note = ('Start failed: {0}' -f $_.Exception.Message)
                Add-Failure -Target ('Service ' + $d.Name) -Reason ('Could not start: {0}' -f $_.Exception.Message)
            }
        }
        $results.Add($r)
    }
    if (-not $Quiet) {
        Write-Host ''
        Write-Host ('  {0,-18} {1,-18} {2,-18} {3,-10} {4}' -f 'Service', 'Start type', 'Default', 'Status', 'Note') -ForegroundColor White
        foreach ($r in $results) {
            $c = if ($r.Healthy) { 'Green' } else { 'Red' }
            Write-Host ('  {0,-18} {1,-18} {2,-18} {3,-10} {4}' -f $r.Name, $r.StartMode, $r.DefaultMode, $r.Status, $r.Note) -ForegroundColor $c
            Write-Log -Message ('Service {0}: {1} / {2} {3}' -f $r.Name, $r.StartMode, $r.Status, $r.Note) -NoConsole
        }
    }
    return $results
}

function Stop-UpdateService {
    param([string]$Name, [hashtable]$WasRunning, $Dependents)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue   # absent optional services are fine
    if (-not $svc) { Write-Log -Message ('Service {0} not present.' -f $Name) -Level WARN; return $true }
    if ($svc.Status -eq 'Stopped') { return $true }
    $WasRunning[$Name] = $true
    foreach ($d in $svc.DependentServices) {
        if ($d.Status -eq 'Running' -and -not ($Dependents -contains $d.Name)) { $Dependents.Add($d.Name) }
    }
    try {
        Stop-Service -InputObject $svc -Force -ErrorAction Stop
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(45))
        Write-Log -Message ('Stopped {0}' -f $Name)
        return $true
    }
    catch {
        Write-Log -Message ('Could not stop {0}: {1}' -f $Name, $_.Exception.Message) -Level WARN
        return $false
    }
}

function Start-UpdateService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue   # absent optional services are fine
    if (-not $svc) { return }
    if ((Get-ServiceStartMode -Name $Name) -eq 'Disabled') { Write-Log -Message ('{0} is disabled; not started.' -f $Name) -Level WARN; return }
    try {
        $svc.Refresh()
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
            Write-Log -Message ('Started {0}' -f $Name)
        }
    }
    catch { Add-SummaryWarning ('Could not start {0}: {1}' -f $Name, $_.Exception.Message) }
}

function Rename-CacheFolder {
    <# Renames (never deletes) a cache folder; Windows recreates it on next use. #>
    param([string]$Path, [string[]]$CoreServices, [hashtable]$WasRunning, $Dependents)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log -Message ('{0} not present; Windows will recreate it.' -f $Path); return $true }
    $newName = '{0}.bak-{1}' -f (Split-Path $Path -Leaf), (Get-Date -Format 'yyyyMMdd-HHmmss')
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Rename-Item -LiteralPath $Path -NewName $newName -ErrorAction Stop
            Write-Log -Message ('Renamed {0} -> {1}' -f $Path, $newName) -Level CHANGE
            return $true
        }
        catch {
            if ($attempt -lt 3) {
                # A trigger-start service may have restarted and re-locked the folder.
                Write-Log -Message ('Rename of {0} failed ({1}); retrying.' -f $Path, $_.Exception.Message) -Level WARN
                foreach ($s in $CoreServices) { $null = Stop-UpdateService -Name $s -WasRunning $WasRunning -Dependents $Dependents }
                Start-Sleep -Seconds 3
            }
            else {
                Add-Failure -Target $Path -Reason ('Could not rename: {0}' -f $_.Exception.Message)
                return $false
            }
        }
    }
    return $false
}

function Invoke-SystemFileRepair {
    <# Microsoft's supported component-store repair (replaces the obsolete regsvr32 routine). #>
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $sfc  = Join-Path $env:SystemRoot 'System32\sfc.exe'
    Write-Log -Message 'Running DISM /Online /Cleanup-Image /RestoreHealth (this can take a long time)...'
    try {
        $p = Start-Process -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($p.ExitCode -eq 0) { Write-Log -Message 'DISM completed successfully.' -Level SUCCESS }
        else { Add-SummaryWarning ('DISM exited with code {0}. See %windir%\Logs\DISM\dism.log' -f $p.ExitCode) }
    }
    catch { Add-SummaryWarning ('DISM could not run: {0}' -f $_.Exception.Message) }
    Write-Log -Message 'Running sfc /scannow...'
    try {
        $p = Start-Process -FilePath $sfc -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($p.ExitCode -eq 0) { Write-Log -Message 'SFC completed.' -Level SUCCESS }
        else { Add-SummaryWarning ('SFC exited with code {0}. See %windir%\Logs\CBS\CBS.log' -f $p.ExitCode) }
    }
    catch { Add-SummaryWarning ('SFC could not run: {0}' -f $_.Exception.Message) }
}

function Reset-WindowsUpdateComponents {
    <#
        Option 4. Stops the update services, renames SoftwareDistribution and catroot2 (Windows
        recreates both), and restarts the services - even if interrupted (finally block).
        DLL re-registration (regsvr32) is intentionally NOT performed: on Windows 10/11 those
        components are serviced by the component store and many listed DLLs no longer exist or
        do not self-register. DISM /RestoreHealth + SFC is offered instead.
    #>
    [CmdletBinding()]
    param([switch]$Unattended, [switch]$SkipBackup, [switch]$RunSystemRepair)
    Write-Section 'Reset Windows Update components'
    $sd  = Join-Path $env:SystemRoot 'SoftwareDistribution'
    $cr2 = Join-Path $env:SystemRoot 'System32\catroot2'

    Write-Host '  This will:' -ForegroundColor White
    Write-Host '   - stop Update Orchestrator, Windows Update, BITS and Cryptographic Services'
    Write-Host ('   - rename {0} and {1} (kept as *.bak-<date>)' -f $sd, $cr2)
    Write-Host '   - restart the services (Windows recreates both folders)'
    Write-Host '  Update history shown in Settings will be reset; installed updates are NOT removed.' -ForegroundColor Yellow

    $pending = Test-PendingReboot
    if ($pending.BlocksComponentReset) {
        Write-Log -Message ('A restart is pending ({0}). Resetting the cache now can break the pending installation.' -f ($pending.Reasons -join ', ')) -Level WARN
        if ($Unattended) {
            Add-Failure -Target $sd -Reason 'Restart pending - component reset skipped. Restart Windows, then run option 4.'
            return
        }
        if (-not (Read-YesNo -Prompt '  Continue anyway? (not recommended)' -Default 'N')) {
            Write-Log -Message 'Component reset cancelled (restart pending).' -Level WARN
            $script:Summary.Cancelled = $true
            return
        }
    }
    if (-not $Unattended) {
        if (-not (Read-YesNo -Prompt '  Reset Windows Update components now?' -Default 'N')) {
            Write-Log -Message 'Cancelled by user. No changes made.' -Level WARN
            $script:Summary.Cancelled = $true
            return
        }
        $RunSystemRepair = Read-YesNo -Prompt '  Also run DISM /RestoreHealth and SFC afterwards (10-30+ minutes)?' -Default 'N'
    }
    if (-not $SkipBackup -and -not $script:Summary.BackupDir) {
        if (-not (Backup-WindowsUpdatePolicies -Label 'Components')) { Write-Log -Message 'Backup failed - aborting.' -Level ERROR; return }
    }

    $core = @('wuauserv', 'BITS', 'CryptSvc')
    $stopOrder = @('UsoSvc', 'wuauserv', 'BITS', 'CryptSvc')
    $wasRunning = @{}
    $dependents = New-Object System.Collections.Generic.List[string]
    $renamed = 0
    try {
        foreach ($s in $stopOrder) { $null = Stop-UpdateService -Name $s -WasRunning $wasRunning -Dependents $dependents }
        # Delivery Optimization may be protected on newer builds; stopping it is best effort.
        $null = Stop-UpdateService -Name 'DoSvc' -WasRunning $wasRunning -Dependents $dependents

        $stillRunning = @($core | Where-Object { $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue; $svc -and $svc.Status -ne 'Stopped' })
        if ($stillRunning.Count -gt 0) {
            Add-Failure -Target $sd -Reason ('Services would not stop ({0}); caches left untouched.' -f ($stillRunning -join ', '))
        }
        else {
            if (Rename-CacheFolder -Path $sd  -CoreServices $core -WasRunning $wasRunning -Dependents $dependents) { $renamed++ }
            if (Rename-CacheFolder -Path $cr2 -CoreServices $core -WasRunning $wasRunning -Dependents $dependents) { $renamed++ }
        }
    }
    finally {
        # Always bring services back, including after Ctrl+C.
        foreach ($s in @('CryptSvc', 'BITS', 'wuauserv')) { Start-UpdateService -Name $s }
        foreach ($s in @('UsoSvc', 'DoSvc') + @($dependents)) { if ($wasRunning.ContainsKey($s) -or $dependents -contains $s) { Start-UpdateService -Name $s } }
    }
    $script:Summary.ComponentsReset = switch ($renamed) { 2 { 'Yes' } 0 { 'No' } default { 'Partial' } }

    if (-not $Unattended) {
        # Old backups from earlier runs: only deleted on explicit request.
        $old = @()
        $old += @(Get-ChildItem -LiteralPath $env:SystemRoot -Directory -Filter 'SoftwareDistribution.bak-*' -ErrorAction SilentlyContinue)
        $old += @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'System32') -Directory -Filter 'catroot2.bak-*' -ErrorAction SilentlyContinue)
        $old = @($old | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2)
        if ($old.Count -gt 0) {
            Write-Host ('  {0} older cache backup folder(s) from previous runs exist.' -f $old.Count) -ForegroundColor White
            if (Read-YesNo -Prompt '  Delete them?' -Default 'N') {
                foreach ($o in $old) {
                    try { Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction Stop; Write-Log -Message ('Deleted old backup {0}' -f $o.FullName) -Level CHANGE }
                    catch { Add-Failure -Target $o.FullName -Reason $_.Exception.Message }
                }
            }
        }
        # BITS jobs stuck in an error state can hold up Windows Update downloads.
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop | Where-Object { [string]$_.JobState -in @('Error', 'TransientError') })
            if ($jobs.Count -gt 0) {
                Write-Host ('  {0} BITS transfer job(s) are in an error state:' -f $jobs.Count) -ForegroundColor White
                foreach ($j in $jobs) { Write-Host ('    {0} ({1}, owner {2})' -f $j.DisplayName, $j.JobState, $j.OwnerAccount) }
                if (Read-YesNo -Prompt '  Cancel these failed jobs?' -Default 'N') {
                    foreach ($j in $jobs) {
                        try { Remove-BitsTransfer -BitsJob $j -ErrorAction Stop; Write-Log -Message ('Cancelled failed BITS job {0}' -f $j.DisplayName) -Level CHANGE }
                        catch { Add-Failure -Target ('BITS job ' + $j.DisplayName) -Reason $_.Exception.Message }
                    }
                }
            }
        }
        catch { Write-Log -Message ('BITS job inspection unavailable: {0}' -f $_.Exception.Message) -Level WARN }
    }
    if ($RunSystemRepair) { Invoke-SystemFileRepair }
}

function Invoke-GroupPolicyRefresh {
    $gp = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
    Write-Log -Message 'Refreshing Group Policy (gpupdate /force)...'
    try {
        # Answer "N" to any log-off / restart prompt gpupdate might show.
        $out = 'N', 'N' | & $gp /force /wait:180 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { Write-Log -Message 'Group Policy refreshed.' -Level SUCCESS }
        else { Add-SummaryWarning ('gpupdate exit code {0}: {1}' -f $LASTEXITCODE, $out.Trim()) }
        Write-Log -Message $out.Trim() -NoConsole
    }
    catch { Add-SummaryWarning ('gpupdate failed: {0}' -f $_.Exception.Message) }
}

function Invoke-WindowsUpdateScanTest {
    <# Runs a real update search through the Windows Update Agent API to prove a source is reachable. #>
    Write-Log -Message 'Searching for updates through the Windows Update Agent (can take several minutes)...'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $ok = ($result.ResultCode -eq 2 -or $result.ResultCode -eq 3)
        $script:Summary.ScanResult = if ($ok) { ('Succeeded - {0} applicable update(s) found' -f $result.Updates.Count) } else { ('Result code {0}' -f $result.ResultCode) }
        Write-Log -Message ('Test scan: {0}' -f $script:Summary.ScanResult) -Level $(if ($ok) { 'SUCCESS' } else { 'WARN' })
    }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $code = '0x{0:X8}' -f $ex.HResult
        $hint = if ($script:WUErrorHints.ContainsKey($code)) { $script:WUErrorHints[$code] } else { $ex.Message }
        $script:Summary.ScanResult = ('Failed {0} - {1}' -f $code, $hint)
        Add-SummaryWarning ('Test scan failed: {0} - {1}' -f $code, $hint)
    }
}

function Invoke-RepairStep {
    param([int]$Number, [string]$Title, [scriptblock]$Body)
    Write-Host ''
    Write-Host (' Step {0}/10 - {1}' -f $Number, $Title) -ForegroundColor Cyan
    Write-Log -Message ('Step {0}: {1}' -f $Number, $Title) -NoConsole
    try { & $Body }
    catch { Add-Failure -Target ('Step {0} ({1})' -f $Number, $Title) -Reason $_.Exception.Message }
}

function Repair-WindowsUpdate {
    <# Option 6: the complete sequence. All questions are asked up front, then it runs unattended. #>
    [CmdletBinding()]
    param()
    Write-Section 'Complete Windows Update repair'
    $initial = Get-WindowsUpdateAudit

    Write-Host ''
    Write-Host '  Planned sequence: backup -> remove blocking policies -> restore policy defaults ->' -ForegroundColor White
    Write-Host '  reset components -> verify services -> Group Policy refresh -> re-detect -> final audit.' -ForegroundColor White
    if ($initial.Management.IsManaged -and -not (Confirm-ManagedDeviceChange -Management $initial.Management)) {
        $script:Summary.Cancelled = $true; return
    }
    if (-not (Read-YesNo -Prompt '  Run the complete repair now?' -Default 'N')) {
        Write-Log -Message 'Cancelled by user. No changes made.' -Level WARN
        $script:Summary.Cancelled = $true; return
    }
    $fixHosts = $false
    if (@($initial.Findings | Where-Object { $_.Action -and $_.Action.Type -eq 'Hosts' }).Count -gt 0) {
        $fixHosts = Read-YesNo -Prompt '  Comment out hosts-file lines that redirect Windows Update?' -Default 'Y'
    }
    $runSfc  = Read-YesNo -Prompt '  Include DISM /RestoreHealth + SFC (adds 10-30+ minutes)?' -Default 'N'
    $runScan = Read-YesNo -Prompt '  Run a test scan for updates at the end?' -Default 'Y'

    Invoke-RepairStep 1 'Audit current configuration' { Write-Log -Message ('Initial status: {0}' -f $initial.Readiness) }
    # Backup-WindowsUpdatePolicies records the folder in the summary; no folder means it failed.
    Invoke-RepairStep 2 'Backup registry configuration' { $null = Backup-WindowsUpdatePolicies -Label 'CompleteRepair' }
    if (-not $script:Summary.BackupDir) {
        Write-Log -Message 'Backup failed - the repair was stopped before any change was made.' -Level ERROR
        return
    }
    Invoke-RepairStep 3 'Remove restrictive Windows Update policies' { Remove-BlockingPolicies -Unattended -SkipBackup -FixHosts $fixHosts }
    Invoke-RepairStep 4 'Restore Windows Update policy defaults' { Reset-WindowsUpdatePolicies -Mode Defaults -Unattended -SkipBackup }
    Invoke-RepairStep 5 'Reset Windows Update components' { Reset-WindowsUpdateComponents -Unattended -SkipBackup -RunSystemRepair:$runSfc }
    Invoke-RepairStep 6 'Verify required services' { $null = Test-WindowsUpdateServices -Repair -StartRequired }
    Invoke-RepairStep 7 'Group Policy refresh' { Invoke-GroupPolicyRefresh }
    Invoke-RepairStep 8 'Re-detect Windows Update configuration' {
        Restart-UpdateAgent
        if ($runScan) { Invoke-WindowsUpdateScanTest } else { Write-Log -Message 'Test scan skipped by user.' }
    }
    Invoke-RepairStep 9 'Final audit' { $null = Get-WindowsUpdateAudit }
    Invoke-RepairStep 10 'Report' { Write-Log -Message 'See the summary below.' }
}

#endregion

#region ---------------------------------------------------------------- Summary, menu, entry point

function Show-OperationSummary {
    $s = $script:Summary
    $status = 'UNKNOWN'
    try { $status = (Get-WindowsUpdateAudit -Quiet).Readiness }
    catch { Write-Log -Message ('Final status check failed: {0}' -f $_.Exception.Message) -Level WARN }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    if ($s.Cancelled) { Write-Host (' {0} - cancelled' -f $s.Title) -ForegroundColor Yellow }
    else { Write-Host (' {0} - complete' -f $s.Title) -ForegroundColor Cyan }
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('Policies removed:         {0}' -f $s.PoliciesRemoved)
    Write-Host ('Policies reset:           {0}' -f $s.PoliciesReset)
    Write-Host ('Services repaired:        {0}' -f $s.ServicesRepaired)
    if ($s.Restored -gt 0) { Write-Host ('Settings restored:        {0}' -f $s.Restored) }
    Write-Host ('Components reset:         {0}' -f $s.ComponentsReset)
    Write-Host ('Registry backup:          {0}' -f $(if ($s.BackupDir) { $s.BackupDir } else { '(none needed)' }))
    Write-Host ('Log file:                 {0}' -f $script:LogFile)
    if ($s.ScanResult) { Write-Host ('Test scan:                {0}' -f $s.ScanResult) }
    Write-Host ''
    $c = if ($status -like 'READY*') { 'Green' } else { 'Red' }
    Write-Host ('Windows Update status:    {0}' -f $status) -ForegroundColor $c

    if ($s.Failures.Count -gt 0) {
        Write-Host ''
        Write-Host 'Could not modify:' -ForegroundColor Red
        foreach ($f in $s.Failures) {
            Write-Host ('  {0}' -f $f.Target) -ForegroundColor Red
            Write-Host ('  Reason: {0}' -f $f.Reason) -ForegroundColor DarkYellow
        }
    }
    if ($s.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach ($w in $s.Warnings) { Write-Host ('  {0}' -f $w) -ForegroundColor Yellow }
    }
    if (($s.PoliciesRemoved + $s.PoliciesReset) -gt 0) {
        Write-Host ''
        Write-Host 'Tip: open Settings > Windows Update and click "Check for updates". A restart' -ForegroundColor DarkGray
        Write-Host 'may be needed before the Settings page stops showing "managed by your organization".' -ForegroundColor DarkGray
    }
    Write-Log -Message ('Summary [{0}]: removed={1} reset={2} services={3} components={4} failures={5} status={6}' -f `
        $s.Title, $s.PoliciesRemoved, $s.PoliciesReset, $s.ServicesRepaired, $s.ComponentsReset, $s.Failures.Count, $status) -NoConsole
}

function Show-Menu {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host (' Windows Update Policy Repair v{0}' -f $script:ToolVersion) -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host (' {0} {1} - build {2}' -f $script:OSInfo.Name, $script:OSInfo.DisplayVersion, $script:OSInfo.FullBuild) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '1. Audit Windows Update policies'
    Write-Host '2. Remove blocking/restrictive policies'
    Write-Host '3. Restore Windows Update policies to OEM defaults'
    Write-Host '4. Reset Windows Update components'
    Write-Host '5. Restore ALL Windows Update policies'
    Write-Host '6. Run complete Windows Update repair'
    Write-Host '7. Back up current Windows Update configuration'
    Write-Host '8. Restore Windows Update configuration from a backup'
    Write-Host '9. Exit'
    Write-Host ''
    return ([string](Read-Host 'Select an option')).Trim()
}

function Invoke-MenuAction {
    param([string]$Title, [scriptblock]$Action, [switch]$NoSummary)
    New-OperationSummary -Title $Title
    Write-Log -Message ('=== {0} started ===' -f $Title) -NoConsole
    try { & $Action }
    catch {
        Add-Failure -Target $Title -Reason ('Unexpected error: {0}' -f $_.Exception.Message)
        Write-Log -Message $_.ScriptStackTrace -Level DEBUG
    }
    if (-not $NoSummary) { Show-OperationSummary }
    Write-Log -Message ('=== {0} finished ===' -f $Title) -NoConsole
}

function Initialize-Session {
    $script:BaseDir = Join-Path $env:ProgramData 'WindowsUpdatePolicyRepair'
    $script:SessionDir = Join-Path $script:BaseDir (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $script:SessionDir -Force -ErrorAction Stop | Out-Null
    $script:LogFile = Join-Path $script:SessionDir 'WindowsUpdateRepair.log'
    $script:OSInfo = Get-WindowsVersionInfo
    Initialize-PolicyCatalog
    New-OperationSummary -Title 'Session'
    Write-Log -Message ('{0} {1} started by {2} on {3}' -f $script:ToolName, $script:ToolVersion, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $env:COMPUTERNAME) -NoConsole
    Write-Log -Message ('OS: {0} {1} {2} build {3}; PowerShell {4}' -f $script:OSInfo.Name, $script:OSInfo.Edition, $script:OSInfo.DisplayVersion, $script:OSInfo.FullBuild, $PSVersionTable.PSVersion) -NoConsole
}

function Start-WindowsUpdateRepairTool {
    # 1) Elevation is required for every read of protected keys and every change.
    if (-not (Test-IsAdministrator)) {
        Write-Host 'This script must be run as Administrator.' -ForegroundColor Red
        if ($PSCommandPath -and (Read-YesNo -Prompt 'Relaunch elevated now?' -Default 'Y')) {
            try {
                $exe = (Get-Process -Id $PID).Path
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) -ErrorAction Stop
            }
            catch { Write-Host ('Elevation failed: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        }
        return
    }
    # 2) A 32-bit host on 64-bit Windows sees redirected registry views; relaunch as 64-bit.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $ps64 = Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if ($PSCommandPath -and (Test-Path -LiteralPath $ps64)) {
            Write-Host 'Relaunching in 64-bit PowerShell...' -ForegroundColor Yellow
            Start-Process -FilePath $ps64 -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) -Wait -NoNewWindow
        }
        else { Write-Host 'Please run this script from 64-bit PowerShell.' -ForegroundColor Red }
        return
    }
    try { Initialize-Session }
    catch { Write-Host ('Initialization failed: {0}' -f $_.Exception.Message) -ForegroundColor Red; return }

    if (-not $script:OSInfo.IsSupported) {
        Write-Host ('Unsupported Windows build {0}. Windows 10 or 11 is required.' -f $script:OSInfo.FullBuild) -ForegroundColor Red
        return
    }
    if ($script:OSInfo.IsServer) {
        Write-Host ('Detected {0}. This tool targets Windows 10/11 client editions.' -f $script:OSInfo.Name) -ForegroundColor Yellow
        if (-not (Read-YesNo -Prompt 'Continue anyway?' -Default 'N')) { return }
    }
    try { [Console]::TreatControlCAsInput = $false } catch { Write-Log -Message 'Console Ctrl+C mode unavailable in this host.' -Level DEBUG }

    Write-Host ''
    Write-Host ('Session folder: {0}' -f $script:SessionDir) -ForegroundColor DarkGray
    Write-Host 'Press Ctrl+C at any time to stop; services are restarted if a reset is interrupted.' -ForegroundColor DarkGray

    try {
        $exit = $false
        do {
            switch (Show-Menu) {
                '1' { Invoke-MenuAction -Title 'Windows Update Audit' -NoSummary -Action { $null = Get-WindowsUpdateAudit } }
                '2' { Invoke-MenuAction -Title 'Remove Blocking Policies' -Action { Remove-BlockingPolicies } }
                '3' { Invoke-MenuAction -Title 'Restore OEM Default Policies' -Action { Reset-WindowsUpdatePolicies -Mode Defaults } }
                '4' { Invoke-MenuAction -Title 'Windows Update Component Reset' -Action { Reset-WindowsUpdateComponents } }
                '5' { Invoke-MenuAction -Title 'Restore ALL Windows Update Policies' -Action { Reset-WindowsUpdatePolicies -Mode All } }
                '6' { Invoke-MenuAction -Title 'Windows Update Repair' -Action { Repair-WindowsUpdate } }
                '7' { Invoke-MenuAction -Title 'Configuration Backup' -Action { Backup-CurrentConfiguration } }
                '8' { Invoke-MenuAction -Title 'Configuration Restore' -Action { Restore-WindowsUpdateConfiguration } }
                '9' { $exit = $true }
                default { Write-Host 'Invalid selection. Enter a number from 1 to 9.' -ForegroundColor Yellow }
            }
            if (-not $exit) { $null = Read-Host "`nPress Enter to return to the menu" }
        } until ($exit)
    }
    finally {
        Write-Log -Message 'Session ended.' -NoConsole
        Write-Host ('Log and backups: {0}' -f $script:SessionDir) -ForegroundColor DarkGray
    }
}

# Run only when executed, not when dot-sourced (allows testing individual functions).
if ($MyInvocation.InvocationName -ne '.') { Start-WindowsUpdateRepairTool }

#endregion
