# SearchParty Watchdog

A menu bar app that watches `/usr/libexec/searchpartyd` (the Find My daemon) and
kills it when it runs away with your CPU or memory. No dock icon, no window.

```
  ◦))                   ← menu bar: the icon alone, white until it warms to red

  ┌──────────────────────────────────┐
  │  SearchParty Watchdog       1.1  │
  │     0.5%           712 MB        │
  │      CPU           MEMORY        │
  │    ▰▰▱▱▱▱▱        ▰▰▰▰▰▱▱        │
  ├──────────────────────────────────┤
  │  Force Kill searchpartyd     ⌘K  │
  │  Auto-Kill When Over Limit       │
  │  Kill Without Password           │
  │  Limits                       ▸  │
  ├──────────────────────────────────┤
  │  Open Activity Monitor           │
  │  Copy Stats                  ⌘C  │
  ├──────────────────────────────────┤
  │  About SearchParty Watchdog      │
  │  Read Me                     ⌘?  │
  ├──────────────────────────────────┤
  │  Launch at Login                 │
  │  Quit SearchParty Watchdog   ⌘Q  │
  └──────────────────────────────────┘
```

The bars are scaled against your configured limits, so a full bar means "at the
limit" — that's the whole readout. Everything is coloured by how close it is to
its limit: green while there's headroom, warming through amber and orange, red at
the limit.

The menu bar carries no number — just the icon, in the menu bar's own white while
there is headroom, warming through amber to red as either limit is approached.
Memory drives it as much as CPU, so a memory runaway colours it on its own. The
icon dims when searchpartyd is not running at all.

**About** shows the version and build. **Read Me** opens this file in a window —
it ships inside the app bundle, so it works from the installed copy with no
dependency on this repo. **Copy Stats** puts the current sample and the limits it
is judged against on the clipboard, as one line worth pasting into a bug report.

## Build & install

```bash
./build.sh
```

Needs only the Xcode Command Line Tools. It compiles, ad-hoc signs, and installs
to `~/Applications/SearchParty Watchdog.app`. Set `INSTALL_DIR=/Applications` to
put it elsewhere. Then open it and turn on **Launch at Login**.

## Killing without a password

`searchpartyd` runs as root, so ending it needs elevation. Turn on **Kill Without
Password** in the menu: macOS asks for your admin password once, and after that
neither the killswitch nor auto-kill ever prompts again.

It works by adding a single line to `/etc/sudoers.d/searchpartyd-watchdog`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pkill -9 -xf /usr/libexec/searchpartyd
```

That grants exactly one command — no wildcard anywhere in it. `-xf` means the
target's entire command line must equal `/usr/libexec/searchpartyd`, so the rule
cannot be turned against any other process. The practical effect is that anything
running as you can restart the Find My daemon without a password, and nothing
else gains privileges.

Audit it before you enable it:

```bash
"$HOME/Applications/SearchParty Watchdog.app/Contents/MacOS/SearchPartyWatchdog" --print-rule
```

That prints the rule, the kill command, and the exact script that will run as
root. The script validates the line with `visudo -cf` before installing it and
re-validates the whole config afterwards, rolling back if anything is wrong — a
malformed sudoers file can lock you out of `sudo` entirely, so it never leaves
one behind. Untick the same menu item to remove it, or:

```bash
sudo rm /etc/sudoers.d/searchpartyd-watchdog
```

**Without the rule**, everything still works — you just get the standard macOS
password dialog on each kill, and auto-kill is labelled "(will ask)" in the menu.
Note that dialog is password-only; Touch ID isn't offered for it, which is part
of why the sudoers rule is the better answer.

**launchd restarts the daemon within seconds**, and that restart is the point:
the fresh process starts with a normal memory footprint instead of the
multi-gigabyte one.

## Auto-kill

Off by default. Once on, the daemon is killed when it stays above **either** the
CPU or the memory limit continuously for the sustain period. Defaults: 200% CPU,
1 GB, 30 seconds. The memory steps run 250 MB to 1.5 GB — the screenshot that
prompted this app showed ~712 MB at idle, so anything past a gigabyte is
genuinely "something is wrong", and 2 GB or 3 GB steps would be dead options on a
16 GB machine.

After a kill it won't fire again for 2 minutes. If you haven't enabled the
sudoers rule and you dismiss the password dialog on an automatic kill, it backs
off for 15 minutes rather than nagging.

## What 100% CPU means

The CPU figure is CPU-seconds burned per wall second, times 100 — the same scale
`ps` and Activity Monitor use. **100% is one core fully occupied, not the whole
machine.** A threaded process can go past it, up to 100% × the number of logical
cores: 1000% on a 10-core M5. Measured against a synthetic load on one:

```
  1 thread       89.7%
  4 threads     388.9%
  8 threads     789.2%
```

So searchpartyd sitting at 100% is one pinned core, which is the *start* of the
problem rather than the end of it. The CPU limits are therefore whole cores —
100%, 200%, 400%, 600%, 800% — derived from the core count, so a smaller machine
is offered a shorter list. The menu labels the scale so it can't be misread.

## Sharing it

```bash
./package.sh
```

Produces `dist/SearchParty Watchdog <version>.dmg` — a single ~1 MB file to
AirDrop or email. The recipient opens it and drags one icon onto Applications,
like any other Mac app. The disk image carries a Read Me First covering the
first-launch step below.

**The first launch on someone else's Mac will be blocked.** Not a bug: the app
is signed ad-hoc, because notarizing it needs a paid Apple Developer ID, and
Gatekeeper rejects anything that isn't notarized. `spctl -a -t exec` on the
bundle says `rejected`, and that is expected. To get past it:

> System Settings → Privacy & Security → scroll to Security → **Open Anyway**

Control-clicking the app and choosing Open no longer works — macOS 15 removed
that shortcut. The Settings route is the only click-through path now. From a
terminal, `xattr -dr com.apple.quarantine "/Applications/SearchParty Watchdog.app"`
does the same thing in one step.

Only the first launch is affected; macOS remembers the decision.

If you'd rather send a plain zip than a disk image:

```bash
ditto -c -k --keepParent ~/Applications/"SearchParty Watchdog.app" ~/Desktop/SearchPartyWatchdog.zip
```

## Checking the numbers

```bash
"$HOME/Applications/SearchParty Watchdog.app/Contents/MacOS/SearchPartyWatchdog" --probe
```

Prints one sample and exits. Pass an executable path to watch something else:
`--probe /usr/libexec/searchpartyuseragent`.

## How it reads the stats

Via `ps`, sampled every 2 seconds. The obvious APIs (`proc_pid_rusage`,
`proc_pidinfo`) return `EPERM` for a root-owned process when the caller is
unprivileged, so `ps` is the only way to get these numbers without running the
whole app as root.

CPU is computed from the delta in cumulative CPU time between samples, so it is
an instantaneous percentage of one core — the same thing Activity Monitor shows,
and it can exceed 100% on a multi-threaded spike. `ps -o %cpu` is deliberately
*not* used: it reports a lifetime average, which would hide exactly the spikes
this app exists to catch. Memory is RSS, matching Activity Monitor's "Real
Memory Size".
