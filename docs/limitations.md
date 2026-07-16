# Honest limitations

macOS is not Windows. Some of what Task Manager shows on Windows genuinely cannot be
obtained here. Rather than invent those numbers, the app leaves them empty and says why.

Everything on this page is a real constraint, not a missing feature waiting on a to-do list.

---

## Per-process GPU is always 0

macOS exposes no per-process GPU utilisation through any public API. Activity Monitor
doesn't show it either — check for yourself.

Whole-GPU utilisation **is** real, read from each accelerator's `PerformanceStatistics`
in the IORegistry, and the Performance tab's GPU graph is live. Only the per-row column
in Processes stays at 0.

## System processes need a one-time password

Unprivileged `proc_pidinfo` returns nothing for processes you don't own. On a typical Mac
that hides roughly **120 of ~620 processes**, including `WindowServer` and `kernel_task`.

The app ships a small helper, `tmhelper`, **unprivileged**, and offers to install it
setuid-root behind a single macOS authorisation prompt.

**You can decline.** Everything else works; those processes just report as idle.

### What the helper actually does

About 150 lines. Installed at `/Library/Application Support/TaskManager/tmhelper`,
owned `root:wheel`, mode `4755`.

It answers exactly two questions:

- `SAMPLE` — dump CPU/memory/disk/fd counts for every pid
- `KILL <pid> <TERM|KILL|STOP|CONT>` — signal one process

It never execs anything. It never interprets a path. It rejects any signal outside that
list, and it refuses to run at all unless the calling user is an admin — so the setuid
bit alone doesn't let a standard user on a shared Mac touch root processes.

This is the same mechanism `/bin/ps` and `/usr/bin/top` have used for decades. Check:

```
$ ls -l /bin/ps
-rwsr-xr-x  1 root  wheel  /bin/ps
     ↑ that 's' is setuid
```

Install once. The setuid bit lives on disk, so it survives reboots and app updates. You
are never asked again.

## Startup impact says "Not measured"

Windows times how long each startup item takes. macOS measures nothing comparable and
publishes no equivalent. The column exists for layout parity and is honest about being empty.

## Set affinity is disabled

Windows lets you pin a process to specific cores. macOS has no CPU affinity API at all —
the scheduler owns that decision. The menu item is shown **disabled with a tooltip**
rather than hidden, so you know it exists and why it can't work here.

## "Metered network" is always 0

macOS offers no documented way to know whether the active interface is a metered hotspot
or a cellular link. Guessing from the interface name would be a fabrication.

## App history starts when you first run the app

Windows reads this from a long-running system metering service. macOS keeps no such
ledger, so the app integrates its own samples and persists them to
`~/Library/Application Support/TaskManager/app-history.json`.

History therefore begins at first launch, and gaps while the app was closed are skipped
rather than interpolated.

## Some services show no PID

`launchctl list` only reports the caller's domain. System daemons that launchd won't
disclose to an unprivileged caller are still listed — sourced from their plists — with no
PID. Windows would show these as "Stopped", and so does this.

## "Last BIOS time" is boot time instead

Macs have no BIOS and publish no firmware hand-off duration. The closest honest figure is
when the kernel booted, so that's what's shown, relabelled.

## Handles are file descriptors

macOS has no equivalent of a Windows handle. The open file-descriptor count
(`PROC_PIDLISTFDS`) is the honest analogue, and it's what the column reports.

## Not notarized

`build.sh` ad-hoc signs the bundle. That's enough to give macOS a stable identity to
attach permission grants to, so you aren't re-prompted on every launch — but it is not a
distributable Developer ID signature, which costs $99/year.

This is why macOS shows "could not verify" on first launch, and why you right-click → Open
once.

---

## Things that bit us

### The mach timebase

`proc_taskinfo`'s CPU totals are in **mach absolute time units, not nanoseconds** — despite
essentially every source online saying nanoseconds.

The distinction is invisible on Intel, where the timebase is 1:1. On Apple Silicon it's
**125/3 ≈ 41.67**.

Without the conversion, a process pinning a full core reports **2.4% CPU**. The whole
Processes tab read zero and looked plausible while doing it. Caught by pinning a core with
a `while True: pass` loop and comparing against `ps`.

```
burner at 99.9% (per ps)
raw delta: 47,928,786 units over 2.01s
  as nanoseconds → 2.4%    ✗
  × 125/3        → 99.4%   ✓
```

### CPU normalisation

Windows normalises CPU across all cores, so the column maxes at 100%. Activity Monitor
does not — it reports per-core, so a busy process can read 800% on an 8-core Mac.

This app follows **Windows**. If a number here disagrees with Activity Monitor by roughly
your core count, that's why, and it's deliberate.

### Fixed-width columns

Every table is an `HStack` of fixed-width columns, matching the Windows layout exactly.
Fixed-width columns cannot shrink — so at the default 1024pt window the table wanted 932pt
against a content pane of ~814pt, and the whole layout slid sideways, pushing the sidebar
off the left edge. Tables now scroll horizontally instead, as Windows does.

### Hang detection

`NSRunningApplication.isResponsive` is not public API — Activity Monitor uses a private
CoreGraphics call. "Not responding" is instead inferred from an Accessibility probe with a
short timeout.

A process that *cannot* answer (sandboxed, say) means **we cannot tell** — which is
deliberately not treated as "not responding".

### APFS hides the physical disk

The root mount reports `disk3s3s1`, a synthesized APFS container. The physical disk is
`disk0`. Neither a volume-name comparison nor a `/dev/` prefix test bridges that, and a
depth-first IORegistry walk stops at the synthesized media. Resolving it needs a
breadth-first walk over *all* parents:

```
disk3s3s1 → disk3s3 → AppleAPFSContainer → AppleAPFSMedia(disk3)
          → AppleAPFSContainerScheme → disk0s2 → IOGUIDPartitionScheme → disk0 ✓
```
