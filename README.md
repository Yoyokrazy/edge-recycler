# Edge Recycler

A tiny macOS menu-bar app that keeps **Microsoft Edge** from slowly eating all
your RAM. It watches Edge's real memory use, learns your normal baseline, and
gracefully **quits + reopens Edge — restoring your tabs** — when it bloats or
hangs. One self-contained Swift/AppKit binary: no dependencies, ~20 MB resident.

## Why

A long-running Edge session (dozens of tabs, up for a day) can climb past 5 GB
and push a 16 GB Mac deep into swap — causing UI hangs, memory-pressure kills,
and crashes. The fix is boring but effective: restart Edge periodically. This
makes that automatic and safe, without losing your tabs.

## What it does

- **Menu-bar dot + GB.** A colored dot (🟢 healthy / 🟡 heavy / 🔴 restart
  recommended) with the current GB. Click for a memory sparkline, process count,
  and share of total RAM.
- **Smart restart threshold.** Learns a rolling **baseline** (median) of your
  usage and, in **Auto** mode, sets the restart level relative to it — so "too
  high" is relative to *your* habits. Or pick a fixed GB value. Only nudges when
  Edge stays above the threshold for a sustained period (default 10 min), so
  momentary spikes don't bug you.
- **Hang detection.** Independently watches for Edge becoming **"Not
  Responding"** (the beachball state) and prompts to restart.
- **Recycle** — on demand (*Recycle Edge Now*), on a **daily 8 AM** prompt, or
  from a high-memory / hang **notification**. Always a graceful `SIGTERM` +
  relaunch with `--restore-last-session`; **never force-kills** unless you
  confirm **Force Quit & Reopen** for a truly stuck Edge.
- **Configurable from the menu** — *Restart when above ▸*, *Sustained for ▸*, and
  *Recalibrate Baseline…*.

## Install

Requires **macOS 13+** and the **Xcode command-line tools** (`xcode-select
--install` for `swiftc`). No Xcode project or Apple Developer account — it builds
from source and ad-hoc signs locally, so Gatekeeper won't block it.

```bash
git clone https://github.com/Yoyokrazy/edge-recycler.git
cd edge-recycler
./install.sh
```

`install.sh` builds the app, installs it to `~/Applications/Edge Recycler.app`,
and registers a per-user LaunchAgent so it starts at login. Everything stays
under your home directory — no `sudo`, nothing system-wide. `./uninstall.sh`
removes it all (your Edge is untouched).

**First launch:** click the menu-bar icon once and choose **Allow** on the
Notifications prompt (it's requested on first interaction, not at launch — see
below). The "App Background Activity" notice macOS shows is just confirming the
login item; leave it enabled.

## Configuration

Read at runtime from `defaults`; the common ones also have menu controls.

| Key              | Meaning                                              | Default  |
| ---------------- | ---------------------------------------------------- | -------- |
| `thresholdMode`  | `auto` (learned) or `manual` (fixed `manualHighGB`)  | `auto`   |
| `manualHighGB`   | Restart threshold in manual mode (GB)                | `5.5`    |
| `autoMarginGB`   | Auto threshold = baseline + this (GB)                | `2.0`    |
| `autoFloorGB` / `autoCeilGB` | Clamp range for the auto threshold (GB)  | `4.5` / `12.0` |
| `defaultHighGB`  | Threshold used until a baseline exists (GB)          | `5.5`    |
| `sustainMinutes` | Minutes Edge must stay ≥ threshold before alerting   | `10`     |
| `triggerHour` / `triggerMinute` | Time of the daily prompt              | `8` / `0`|
| `pollSeconds`    | How often to sample Edge memory                      | `60`     |
| `notifyCooldown` | Min seconds between notifications                    | `3600`   |
| `calibrationSamples` | Samples before the baseline is trusted           | `60`     |
| `maxStoredSamples`   | Rolling cap on persisted samples (~3.5 days)     | `5000`   |
| `hangDetection`  | Detect & alert when Edge is "Not Responding" (`-bool`)| `true`  |

```bash
defaults write com.edgerecycler.app manualHighGB -float 6.0
launchctl kickstart -k "gui/$(id -u)/com.edgerecycler.agent"   # apply
```

Defaults suit a 16 GB Mac; on more RAM raise `autoCeilGB` / `manualHighGB`.

> The **bundle ID** `com.edgerecycler.app` is the `defaults` domain; the
> **launchd label** `com.edgerecycler.agent` is for `launchctl`. Forking under
> your own name means changing both (in `Info.plist`, the LaunchAgent plist, and
> the scripts).

## How it works

- **Memory:** sums `ri_phys_footprint` across the Edge process tree via
  `proc_pid_rusage` — the same figure Activity Monitor shows, and an external
  kernel query, so it stays accurate **even when Edge is hung**. (Teams' embedded
  Edge WebView is correctly excluded.)
- **Baseline:** each poll is appended to `~/Library/Application
  Support/EdgeRecycler/state.json` (rolling window); the threshold tracks the
  median. The chart's dashed-red line is the threshold, dotted-gray is the
  baseline, and the x-axis spans at least the sustained duration.
- **Recycling:** `SIGTERM` (like ⌘Q, so the session is saved — no "didn't shut
  down properly" bubble) → wait for a clean exit → relaunch with session restore.
  A hung Edge that ignores `SIGTERM` can be ended with user-confirmed Force Quit.
- **Hang detection:** reads the private `CGSEventIsAppUnresponsive` (what Activity
  Monitor uses), resolved via `dlsym` so a missing symbol degrades gracefully. A
  freshly-launched Edge is ignored for 45 s (cold start reads as unresponsive),
  and rising hangs are re-confirmed before alerting.
- **Notifications:** requested **in context** on your first menu interaction,
  never at launch. A background `LSUIElement` app that asks at launch gets the
  prompt auto-dismissed and recorded as *denied* forever — so we wait until the
  app is active. If it ends up denied, the menu links to System Settings.

## Troubleshooting

- **No icon?** `pgrep -x EdgeRecycler`; start with
  `launchctl kickstart -k "gui/$(id -u)/com.edgerecycler.agent"`.
- **No notifications?** Open the menu once (triggers the prompt) and **Allow**; if
  the *Notifications:* line says off, click it to open Settings. Auth state is
  logged to `~/Library/Logs/edge-recycle.diag.log`.
- **"Couldn't close Edge"?** A page had a "Leave site?" prompt blocking the quit —
  handle it and recycle again, or use Force Quit.

## License

[MIT](LICENSE) — © 2026 Michael Lively. Personal project, no warranty; it only
ever sends Edge a normal quit signal and reopens it.
