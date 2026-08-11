# Edge Recycler

A tiny macOS menu-bar app that keeps **Microsoft Edge** from slowly eating all
your RAM. It watches Edge's real memory use, shows it in a dropdown with a
sparkline, warns you (native notification) when it gets too high, and can
gracefully **quit + reopen Edge** — restoring all your tabs — on a click or on a
daily schedule.

Built as a single self-contained Swift/AppKit binary. No Xcode project, no
dependencies, ~110 KB, ~20 MB resident.

---

## Why this exists

On a 16 GB Mac, a long-running Edge session (dozens of tabs, up for a day) can
climb to **5+ GB** and, combined with VS Code / Teams / etc., push the machine
deep into swap. That causes UI hangs ("Not Responding"), memory-pressure
(jetsam) kills, and eventually crashes. The fix is boring but effective:
**restart Edge periodically** so it releases accumulated memory. This app makes
that automatic and safe, without you losing your tabs.

## What it does

- **Menu-bar readout.** Click the recycle icon to see Edge's current memory
  (summed `phys_footprint` across the whole Edge process tree — the same number
  Activity Monitor's *Memory* column shows), a **sparkline of recent history**,
  a color status (🟢 Healthy / 🟠 Heavy / 🔴 Restart recommended), process count,
  and system load.
- **At-a-glance bar.** The menu-bar icon stays quiet when healthy; it shows the
  GB number when memory is elevated and turns into a red ⚠️ when it's high.
- **Manual recycle.** *Recycle Edge Now* quits and reopens Edge on demand.
- **Daily prompt.** At **8:00 AM** (or the soonest the Mac is awake after that,
  and only while Edge is running) it asks: **Restart Now / Delay 1 Hour / Skip
  Today**. To avoid ambushing you, if the app *starts* after the trigger time
  (a mid-day install, or a morning login past 8 AM with a freshly-launched
  Edge), it skips today and resumes on the next scheduled day — use *Recycle
  Edge Now* if you want it immediately.
- **High-memory notification.** If Edge crosses the *high* threshold it posts a
  native notification with a **Restart Edge Now** button. Rate-limited to at
  most once an hour so it never spams.
- **Graceful, never destructive.** Recycling sends `SIGTERM` (exactly what
  ⌘Q / Activity Monitor's *Quit* do), so Edge saves its session and you get **no
  "Edge didn't shut down properly" bubble**. It relaunches with
  `--restore-last-session` to bring every tab back. It **never force-kills** — if
  a page is blocking the quit (e.g. a "Leave site?" prompt) it backs off and
  leaves everything as-is.

## How recycling works (and why it's safe)

```
SIGTERM → Edge's normal end-session path → tabs/session saved to disk
        → wait up to 25s for a clean exit (never kill -9)
        → open -a "Microsoft Edge" --args --restore-last-session
```

`--restore-last-session` forces the previous window/tab set to reopen regardless
of your Edge "On startup" setting, so you don't need to change anything in Edge.
(If you'd like Edge to always restore on its own, you can still set
`edge://settings/onStartup` → "Continue where you left off" — but it isn't
required.)

---

## Install

Requires the Xcode command-line tools (`swiftc`, `codesign` — already present if
you develop on this Mac).

```bash
cd edge-recycler
./install.sh
```

This builds the app, copies it to `~/Applications/Edge Recycler.app`, and
registers a per-user **LaunchAgent** so it starts at login.

First launch:

- macOS shows an **"App Background Activity"** notification saying *"Edge
  Recycler.app can run in the background."* That's expected — it's macOS
  confirming the login item registered. Leave it enabled (manageable under
  **System Settings → General → Login Items & Extensions**).
- You'll get a **Notifications permission** prompt — choose **Allow** so the
  high-memory alerts can appear. (Verify anytime with *Send Test Notification*
  in the menu.)

### Build only (no install)

```bash
./build.sh
open "build/Edge Recycler.app"
```

### Uninstall

```bash
./uninstall.sh
```

Your Edge, its tabs, and its settings are never touched.

---

## Configuration

Thresholds and timing are read at runtime from `defaults`, so you can tune them
without recompiling. Defaults in parentheses:

| Key              | Meaning                                         | Default |
| ---------------- | ----------------------------------------------- | ------- |
| `warnGB`         | Yellow "Heavy" threshold (GB)                   | `4.0`   |
| `highGB`         | Red threshold → notification (GB)               | `5.5`   |
| `triggerHour`    | Hour of the daily prompt (0–23)                 | `8`     |
| `triggerMinute`  | Minute of the daily prompt                      | `0`     |
| `pollSeconds`    | How often to sample Edge memory                 | `60`    |
| `notifyCooldown` | Min seconds between high-memory notifications   | `3600`  |
| `historyCount`   | Samples kept in the sparkline                   | `60`    |
| `chartTopGB`     | Top of the sparkline's y-axis (GB)              | `8.0`   |

Examples:

```bash
defaults write com.milively.edge-recycler highGB      -float 6.0
defaults write com.milively.edge-recycler triggerHour -int   7
# then restart the app (or log out/in):
launchctl kickstart -k "gui/$(id -u)/com.milively.edge-recycler"
```

The thresholds above are calibrated for a 16 GB machine. If you have more RAM,
raise `warnGB`/`highGB` accordingly.

---

## Project layout

```
edge-recycler/
├── Sources/main.swift        # the whole app (sampling, chart, menu, notifications)
├── Resources/Info.plist      # bundle metadata (LSUIElement = menu-bar only)
├── LaunchAgents/…plist       # login-agent template (__APP_PATH__ filled at install)
├── build.sh                  # compile + bundle + ad-hoc sign → build/
├── install.sh                # build + install to ~/Applications + load agent
├── uninstall.sh              # unload agent + remove app
└── README.md
```

## How memory is measured

`Sampler.snapshot()` enumerates every process via `proc_listallpids`, keeps the
ones whose executable path is inside `…/Microsoft Edge.app/…` (which correctly
**excludes** Microsoft Teams' embedded WebView, even though it uses the Edge
framework), and sums each process's `ri_phys_footprint` from
`proc_pid_rusage(RUSAGE_INFO_V2)`. That's the memory-pressure-relevant figure
macOS itself uses, so it lines up with Activity Monitor.

## Troubleshooting

- **No menu-bar icon?** Check it's running: `pgrep -x EdgeRecycler`. Start it
  with `open "$HOME/Applications/Edge Recycler.app"`, or
  `launchctl kickstart -k "gui/$(id -u)/com.milively.edge-recycler"`.
- **No notifications?** Confirm permission under **System Settings →
  Notifications → Edge Recycler**, then use *Send Test Notification*.
- **"Couldn't close Edge" alert.** A page had an unsaved-changes / "Leave site?"
  prompt that blocked the graceful quit. Deal with the page, then recycle again.
  The app intentionally never forces the kill.
- **Logs:** `~/Library/Logs/edge-recycle.out.log` and `…err.log`.

## Notes / limitations

- Ad-hoc code-signed (personal use). Gatekeeper won't complain since you build
  it locally; there's no notarization.
- The daily prompt is a soft nudge — it only appears while Edge is running and
  is snoozeable. A manual *Recycle Edge Now* counts as that day's cycle.
- Personal project; no warranty. It only ever sends Edge a normal quit signal
  and reopens it.
