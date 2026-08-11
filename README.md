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
- **High-memory notification.** If Edge stays **at or above the *high* threshold
  for a sustained period** (10 minutes by default — not a momentary spike), it
  posts a **native macOS notification** with a **Restart Edge Now** button.
  Rate-limited to at most once an hour so it never spams. A brief spike from
  loading a heavy page won't trigger it; only genuinely stuck-high memory does.
- **Native notifications, done right.** Permission is requested **in context**
  the first time you open the menu — never at launch — so the macOS *Allow*
  prompt appears and sticks. The menu shows notification status and, if you've
  turned them off, links straight to System Settings. (See
  [The notification permission model](#the-notification-permission-model).)
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

## Prerequisites

- **macOS 13 or later**, Apple Silicon or Intel.
- **Microsoft Edge** installed at `/Applications/Microsoft Edge.app`.
- **Xcode command-line tools** for `swiftc` + `codesign`
  (`xcode-select --install` if you don't have them). No full Xcode or Apple
  Developer account needed — the app is built from source and ad-hoc signed
  locally, so Gatekeeper won't block it.

## Install

```bash
git clone https://github.com/Yoyokrazy/edge-recycler.git
cd edge-recycler
./install.sh
```

This builds the app, copies it to `~/Applications/Edge Recycler.app`, and
registers a per-user **LaunchAgent** so it starts at login. Everything it
touches is under your home directory (`~/Applications`, `~/Library/LaunchAgents`,
`~/Library/Logs`) — nothing system-wide, no `sudo`.

First launch:

- macOS shows an **"App Background Activity"** notification saying *"Edge
  Recycler.app can run in the background."* That's expected — it's macOS
  confirming the login item registered. Leave it enabled (manageable under
  **System Settings → General → Login Items & Extensions**).
- **Click the menu-bar recycle icon once.** The first time you open (and close)
  the menu, macOS shows the **Notifications permission** prompt — choose
  **Allow** so high-memory and daily alerts appear as banners. This is
  deliberately requested on your first interaction, not at launch (see below).
  You can re-check anytime with *Send Test Notification*, and the menu's
  *Notifications:* line always shows the current state.

### Build only (no install)

```bash
./build.sh                       # prints the built .app path (in $TMPDIR)
open "$(./build.sh | tail -1)"
```

### Uninstall

```bash
./uninstall.sh
```

Your Edge, its tabs, and its settings are never touched.

## The notification permission model

This one's worth understanding, because getting it wrong makes notifications
silently never work:

- macOS shows the notification-permission popup **only once**, when an app's
  status is *not determined*, and **only records a real choice if the prompt is
  shown while the app is active**. Once the status is *denied*, calling
  `requestAuthorization` again **never prompts** — the user must flip the switch
  in System Settings.
- A menu-bar (`LSUIElement`) app launched at login by `launchd` is **not the
  active app**. If it requests permission at launch, macOS shows the prompt to a
  non-active app, instantly auto-dismisses it, and records **denied** — so
  notifications are dead forever, with no visible prompt. (We hit exactly this.)
- **The fix (per Apple's guidance):** never request at launch. Request **in
  context**, on an explicit user interaction, with the app activated — here,
  right after you first open the menu. Then the prompt shows and your choice
  sticks. If you ever end up *denied*, the menu's *Notifications:* item links
  straight to System Settings to turn it back on.

---

## Configuration

Thresholds and timing are read at runtime from `defaults`, so you can tune them
without recompiling. Defaults in parentheses:

| Key              | Meaning                                             | Default |
| ---------------- | --------------------------------------------------- | ------- |
| `warnGB`         | Yellow "Heavy" threshold (GB)                       | `4.0`   |
| `highGB`         | Red threshold (GB)                                  | `5.5`   |
| `sustainMinutes` | Minutes Edge must stay ≥ `highGB` before alerting   | `10`    |
| `triggerHour`    | Hour of the daily prompt (0–23)                     | `8`     |
| `triggerMinute`  | Minute of the daily prompt                          | `0`     |
| `pollSeconds`    | How often to sample Edge memory                     | `60`    |
| `notifyCooldown` | Min seconds between high-memory notifications       | `3600`  |
| `historyCount`   | Samples kept in the sparkline (120 × 60s ≈ 2 h)     | `120`   |
| `chartTopGB`     | Top of the sparkline's y-axis (GB)                  | `8.0`   |

Examples:

```bash
defaults write com.edgerecycler.app highGB         -float 6.0
defaults write com.edgerecycler.app sustainMinutes -int   15
defaults write com.edgerecycler.app triggerHour    -int   7
# then restart the app (or log out/in):
launchctl kickstart -k "gui/$(id -u)/com.edgerecycler.agent"
```

The thresholds above are calibrated for a 16 GB machine. If you have more RAM,
raise `warnGB`/`highGB` accordingly. Raise `sustainMinutes` if you want the app
to tolerate longer high-memory stretches before nudging you.

> **Two identifiers, on purpose:** the app's **bundle ID** is
> `com.edgerecycler.app` (this is the `defaults` domain and what macOS keys
> notification permission on). The **launchd label** for the login agent is
> `com.edgerecycler.agent` (used with `launchctl`). They're intentionally
> distinct. Forking under your own name? Change `CFBundleIdentifier` in
> `Resources/Info.plist`, the `Label` in `LaunchAgents/*.plist` (and match the
> filename), and `LABEL` in `install.sh` / `uninstall.sh`.

---

## Project layout

```
edge-recycler/
├── Sources/main.swift        # the whole app (sampling, chart, menu, notifications)
├── Resources/Info.plist      # bundle metadata (LSUIElement = menu-bar only)
├── LaunchAgents/…plist       # login-agent template (__APP_PATH__ filled at install)
├── build.sh                  # compile + bundle + ad-hoc sign → $TMPDIR (prints path)
├── install.sh                # build + install to ~/Applications + load agent
├── uninstall.sh              # unload agent + remove app
└── README.md
```

The app is built into `$TMPDIR` (not the repo) on purpose: a second `.app` with
the same bundle ID sitting in a Spotlight/LaunchServices-scanned tree (like
`~/Documents`) makes macOS route notifications to the wrong copy and silently
breaks them.

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
  `launchctl kickstart -k "gui/$(id -u)/com.edgerecycler.agent"`.
- **No notifications / "Send Test Notification" does nothing?** First open the
  menu once (that's what triggers the permission prompt) and click **Allow**. If
  the menu's *Notifications:* line says **off**, click it (or go to **System
  Settings → Notifications → Edge Recycler**) and turn **Allow Notifications**
  on. macOS only shows the one-time prompt when status is "not determined"; once
  "denied", the Settings toggle is the only way back. The app logs the auth
  status it sees to `~/Library/Logs/edge-recycle.diag.log`.
- **"Couldn't close Edge" alert.** A page had an unsaved-changes / "Leave site?"
  prompt that blocked the graceful quit. Deal with the page, then recycle again.
  The app intentionally never forces the kill.
- **Logs:** `~/Library/Logs/edge-recycle.out.log`, `…err.log`, and
  `…diag.log` (notification diagnostics).

## Notes / limitations

- Ad-hoc code-signed (personal use). Gatekeeper won't complain since you build
  it locally; there's no notarization.
- The daily prompt is a soft nudge — it only appears while Edge is running and
  is snoozeable. A manual *Recycle Edge Now* counts as that day's cycle.
- Personal project; no warranty. It only ever sends Edge a normal quit signal
  and reopens it.

## License

[MIT](LICENSE) — © 2026 Michael Lively. Free to use, fork, and modify.
