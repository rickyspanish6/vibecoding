# Scripts

Standalone scripts that don't need a project of their own.

| Script | What it does |
| --- | --- |
| [Repair-WindowsUpdatePolicies-v1.2.0.ps1](Repair-WindowsUpdatePolicies-v1.2.0.ps1) | Audits, backs up, repairs and restores Windows Update policies on Windows 10/11 |

Scripts carry their version in the file name; the latest version replaces the
previous file.

---

## Repair-WindowsUpdatePolicies · v1.2.0

An interactive PowerShell tool that finds whatever is stopping or restricting
Windows Update and puts it back to how a clean Windows install behaves: policies
set through Group Policy, registry tweaks, "update blocker" tools, a dead WSUS
server, a pause that never ends, disabled services. It audits before it changes
anything, backs up before every change, and logs everything.

```
========================================
 Windows Update Policy Repair v1.2.0
========================================
 Windows 11 24H2 - build 26100.4652

1. Audit Windows Update policies
2. Remove blocking/restrictive policies
3. Restore Windows Update policies to OEM defaults
4. Reset Windows Update components
5. Restore ALL Windows Update policies
6. Run complete Windows Update repair
7. Back up current Windows Update configuration
8. Restore Windows Update configuration from a backup
9. Exit

Select an option:
```

The menu comes back after every operation until you pick **Exit**.

### Run it

Open PowerShell **as Administrator** in the folder with the script:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-WindowsUpdatePolicies-v1.2.0.ps1
```

If you start it without admin rights it offers to relaunch itself elevated. It
works in Windows PowerShell 5.1 (built into Windows) and PowerShell 7, and needs
no extra modules.

**Start with option 1.** It changes nothing and shows you exactly what the other
options would act on.

### The options

**1 · Audit** — a read-only report of everything that affects Windows Update.
Each item is labelled:

| Label | Meaning |
| --- | --- |
| `DEFAULT / NORMAL` | Same as a clean install |
| `CUSTOM POLICY` | Set by someone, but not stopping updates (marked *restrictive* if it delays them) |
| `POTENTIALLY BLOCKING` | Likely stops Windows Update from working |
| `ORGANIZATION MANAGED` | Comes from a domain, MDM (Intune) or ConfigMgr |

It covers the Windows Update and Automatic Updates policies, WSUS (and whether
the server actually answers), Windows Update for Business deferrals, pauses and
target release version, restart and notification policies, Delivery
Optimization, user-level policies, Local Group Policy files, MDM policies (both
the merged values and each enrollment's own store), Windows Update's cached copy
of Group Policy, the Settings-app pause, the update services (start type and
whether they still point at the right program), scan tasks, update programs
blocked through Image File Execution Options, firewall rules blocking update
traffic, the hosts file, the WinHTTP proxy, which update source Windows is
really using, and the policy state Windows Update itself evaluated. Each audit is
also saved as a text file.

**2 · Remove blocking/restrictive policies** — removes only what blocks or
delays updates: automatic updates turned off, access to Windows Update removed,
active pauses, deferrals, a pinned feature version, a WSUS server that's missing
or unreachable, disabled update services and scan tasks, a policy cache still
holding blocking values, update programs blocked by a `Debugger` value, and
local firewall rules blocking update traffic (disabled, not deleted). Hosts-file
entries that redirect Windows Update are commented out if you agree.

**3 · Restore policies to OEM defaults** — removes every documented Windows
Update policy value, blocking or not, so Group Policy shows everything as
*Not configured*, and clears Windows Update's cached copy of Group Policy.

**4 · Reset Windows Update components** — stops the update services, renames
`SoftwareDistribution` and `catroot2` (Windows rebuilds both), and starts the
services again. Optionally clears failed BITS downloads and runs
`DISM /RestoreHealth` + `sfc /scannow`. Installed updates are not removed, but
the update history list in Settings starts over.

**5 · Restore ALL Windows Update policies** — everything option 3 does, plus
Delivery Optimization download limits, user-level and legacy policies, unknown
values left in the Windows Update policy keys, leftover MDM values from a
removed enrollment (in the merged store *and* the enrollment's own store, so
they don't come back), the Settings-app pause, and empty policy keys. Shows a
warning and makes a full backup first.

**6 · Complete repair** — asks its questions up front, then runs on its own:
audit → backup → option 2 → option 3 → option 4 → check services →
`gpupdate /force` → test scan for updates → final audit → summary.

**7 · Back up current configuration** — saves every setting this tool manages,
with an optional description, without changing anything. Use it before
experimenting, or to keep a known-good state.

**8 · Restore from a backup** — lists every backup on this PC (manual ones and
the automatic ones taken before each repair), shows exactly what would change,
and puts the configuration back as it was. See
[Backup and restore](#backup-and-restore).

Every operation ends with a summary:

```
Policies removed:         12
Policies reset:           4
Services repaired:        3
Components reset:         Yes
Registry backup:          C:\ProgramData\WindowsUpdatePolicyRepair\...
Log file:                 C:\ProgramData\WindowsUpdatePolicyRepair\...

Windows Update status:    READY

Could not modify:
  HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update\DeferFeatureUpdatesPeriodInDays
  Reason: Managed by organization (MDM) - change it in the MDM console
```

### How it restores "defaults"

A Windows Update policy is *Not configured* when its registry value doesn't
exist. So the script restores defaults by **deleting** individual policy values;
it never writes a guessed value like `NoAutoUpdate = 0`, and never deletes a
whole registry tree. It only touches values from a list of ~130 documented policy
names (checked against Microsoft's Policy CSP and Windows Update documentation),
plus a few legacy ones that are only ever deleted, never created. Anything else
in shared keys is left alone.

**Local Group Policy.** Settings made in `gpedit.msc` are also stored in
`C:\Windows\System32\GroupPolicy\...\Registry.pol`. Deleting only the registry
value doesn't stick, because the next Group Policy refresh writes it back. The
script removes the matching Windows Update entries from those files too, and
keeps every other setting in them byte-for-byte.

### Backup and restore

Every backup folder contains a `snapshot.json`: an exact record of every setting
this tool manages — policy values, Local Group Policy entries, MDM policy
stores, the policy cache, the Settings-app pause, service start types, scan
tasks, update-related firewall rules and hosts lines.

A restore (option 8) compares that record with the PC as it is now and changes
only the differences:

- values added since the backup are **removed**, values changed or removed since
  are **written back** — so you return to exactly the saved state, which a plain
  `reg import` can't do (it never deletes values added later);
- in Local Group Policy files only the Windows Update entries are restored;
  every other policy in them is kept;
- settings the tool doesn't manage are never touched.

You see the full list of changes before confirming, and the current state is
backed up first, so a restore can itself be undone with option 8.

Backups are made automatically before options 2–6 and before a restore, so you
can always go back to how things were before a repair. A backup taken on another
PC can be applied too (you're warned first), by choosing **P** and entering its
folder path.

A restore can put back a *blocking* configuration if that's what the backup
contains, including a disabled service; the plan says so before you confirm.

### Safety

- **Backups first.** Every key it might touch is exported with `reg export`,
  and the `Registry.pol` files and hosts file are copied, before anything is
  changed. If the backup fails, nothing is changed.
- **Organization-managed PCs.** If the PC is domain-joined, Entra ID-joined,
  MDM-enrolled or has a ConfigMgr client, you have to type `YES` before any
  change. Those policies will usually come back at the next refresh. Policies
  delivered by MDM are never modified; change them in Intune (or your MDM).
- **Protected services** such as the Windows Update Medic Service refuse changes
  even from administrators. The script reports "Access denied" instead of
  working around it. It only ever changes a service that's **Disabled**, and
  never disables one.
- **Nothing is deleted outright** except policy values: cache folders are
  renamed to `*.bak-<date>`, hosts lines are commented out. Old cache backups
  are only removed if you say so.
- **Safe to run again.** A second run finds nothing to change.
- **Ctrl+C** stops at any time; if a component reset is interrupted, the
  services are restarted anyway.
- Security features, update signing and certificate checks are never touched.

### Where things go

```
C:\ProgramData\WindowsUpdatePolicyRepair\<yyyyMMdd-HHmmss>\
  WindowsUpdateRepair.log        every change, with the old value
  Audit-<time>.txt               each audit report
  Backup-<operation>-<time>\
    Registry\*.reg               exported keys
    Files\...                    Registry.pol files, hosts and firewall policy, as they were
    snapshot.json                exact state, used by option 8
    RESTORE-README.txt
```

To undo, use option 8. The `.reg` files and copied files are still there for a
manual restore (`reg import <file>`, copy the files back under
`C:\Windows\System32\`, then `gpupdate /force`). Renamed cache folders can be
renamed back once the services are stopped.

### Still "managed by your organisation"?

If Settings still says *Windows Update settings are managed by your
organisation* after a repair:

1. **Restart Windows.** The Settings page and the update service only re-read
   policy on restart.
2. **Run option 1 again** and look for anything still marked
   `POTENTIALLY BLOCKING` or `ORGANIZATION MANAGED`. The *Effective policy
   state* section shows what Windows Update itself thinks is in force, even
   when the source is unclear.
3. **Check "Could not modify"** in the last summary. `Managed by organization`
   means an active domain or MDM enrollment owns that setting. If this PC should
   not be managed, remove it under **Settings > Accounts > Access work or
   school**, then run option 5 again.
4. **Altered service registration** (a service pointing at the wrong program)
   is reported but not fixed automatically. An in-place upgrade (run Windows
   Setup from the Windows 11 ISO and keep apps and files) repairs it.

### Limitations

- User-level policies are only checked for users who are signed in (their
  registry hive has to be loaded).
- The WinHTTP proxy is reported but not changed, since it may be needed on your
  network. If it's stale, run `netsh winhttp reset proxy`.
- If an update restart is pending, the component reset is skipped (option 6) or
  needs confirmation (option 4). Restart first.
- Altered service registrations are only reported (see above).
- Firewall rules delivered by Group Policy can't be changed locally; they're
  listed under "Could not modify".
- A restore only covers users who are signed in, and firewall rules that still
  exist (rules are enabled/disabled, never recreated).
- Backups made with v1.0/v1.1 have no `snapshot.json`; restore them manually
  from their `.reg` files.
- Windows Server runs, but it's built and tested for Windows 10/11 client
  editions.

### Version history

| Version | Changes |
| --- | --- |
| 1.2.0 | Back up (option 7) and restore (option 8) the exact Windows Update configuration; version in the file name |
| 1.1.0 | Catches policies that survived a repair: MDM provider stores, Windows Update policy cache, blocked update programs (IFEO), firewall rules, altered service registrations |
| 1.0.0 | First version: audit, remove blocking policies, restore defaults, reset components, complete repair |
