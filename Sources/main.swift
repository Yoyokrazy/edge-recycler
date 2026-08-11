import AppKit
import Foundation
import Darwin
import UserNotifications

// ============================================================================
// Edge Recycler
// ----------------------------------------------------------------------------
// A menu-bar app that keeps Microsoft Edge from slowly eating all your RAM.
//
//  * Polls Edge's real memory use (summed phys_footprint across its whole
//    process tree — the same number Activity Monitor's "Memory" column shows).
//  * Click the menu-bar icon to see current usage + a sparkline of recent
//    history, and to "Recycle Edge Now" on demand.
//  * Once a day at 8:00 AM (or the soonest the Mac is awake after that, and
//    only while Edge is running) it asks: Restart Now / Delay 1 Hour / Skip.
//  * If memory stays above the "high" threshold for a sustained period (not a
//    momentary spike) it posts a native macOS notification with a "Restart Edge
//    Now" button (rate-limited so it never spams).
//  * Recycling = graceful SIGTERM (like Cmd-Q, so tabs are saved and there's
//    no "didn't shut down properly" bubble) then relaunch with
//    --restore-last-session. It NEVER force-kills.
//
// Tunable at runtime without recompiling, e.g.:
//    defaults write com.edgerecycler.app highGB        -float 6.0
//    defaults write com.edgerecycler.app sustainMinutes -int 15
//    defaults write com.edgerecycler.app triggerHour   -int 8
// ============================================================================

// MARK: - Config

enum Config {
    static var triggerHour: Int  { intDefault("triggerHour", 8) }
    static var triggerMinute: Int { intDefault("triggerMinute", 0) }
    static var pollSeconds: Double { doubleDefault("pollSeconds", 60) }
    static var warnGB: Double { doubleDefault("warnGB", 4.0) }
    static var highGB: Double { doubleDefault("highGB", 5.5) }
    /// How long Edge must stay continuously at/above highGB before we alert.
    /// Filters out momentary spikes (e.g. loading a heavy page).
    static var sustainMinutes: Double { doubleDefault("sustainMinutes", 10) }
    static var notifyCooldown: Double { doubleDefault("notifyCooldown", 3600) }
    static var historyCount: Int { intDefault("historyCount", 120) }
    static var chartTopGB: Double { doubleDefault("chartTopGB", 8.0) }

    static func intDefault(_ k: String, _ d: Int) -> Int {
        UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.integer(forKey: k) : d
    }
    static func doubleDefault(_ k: String, _ d: Double) -> Double {
        UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.double(forKey: k) : d
    }
}

enum MemState { case green, yellow, red }

// MARK: - Process / memory sampling (libproc)

struct EdgeSnapshot {
    var bytes: UInt64 = 0
    var procs: Int = 0
    var mainPid: pid_t? = nil
    var gb: Double { Double(bytes) / 1_073_741_824.0 }
}

enum Sampler {
    /// Enumerate every process belonging to the Microsoft Edge *browser* bundle
    /// (Teams' embedded WebView lives under a different .app path and is excluded)
    /// and sum each one's phys_footprint.
    static func snapshot() -> EdgeSnapshot {
        var snap = EdgeSnapshot()
        let maxPids = 8192
        var pids = [pid_t](repeating: 0, count: maxPids)
        let cnt = proc_listallpids(&pids, Int32(maxPids * MemoryLayout<pid_t>.size))
        if cnt <= 0 { return snap }

        var pathBuf = [CChar](repeating: 0, count: 4096)
        for i in 0..<Int(cnt) {
            let pid = pids[i]
            if pid <= 0 { continue }
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if len <= 0 { continue }
            let path = String(cString: pathBuf)
            guard path.contains("/Microsoft Edge.app/") else { continue }

            // The root browser process is the bare executable, not a Helper.
            if path.hasSuffix("/Contents/MacOS/Microsoft Edge") {
                snap.mainPid = pid
            }

            var info = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, rp)
                }
            }
            if rc == 0 {
                snap.bytes += info.ri_phys_footprint
                snap.procs += 1
            }
        }
        return snap
    }

    static func loadAvg1() -> Double {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l[0]
    }
}

// MARK: - Sparkline chart

final class SparklineView: NSView {
    var samples: [Double] = []
    var warn = Config.warnGB
    var high = Config.highGB

    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 66) }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 10, dy: 10)
        let scale = max(Config.chartTopGB, high * 1.15)
        func y(_ v: Double) -> CGFloat { b.minY + CGFloat(min(v, scale) / scale) * b.height }
        func x(_ i: Int, _ n: Int) -> CGFloat {
            n <= 1 ? b.minX : b.minX + CGFloat(i) / CGFloat(n - 1) * b.width
        }

        // baseline
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: b.minX, y: b.minY))
        ctx.addLine(to: CGPoint(x: b.maxX, y: b.minY))
        ctx.strokePath()

        // high-threshold dashed line
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: b.minX, y: y(high)))
        ctx.addLine(to: CGPoint(x: b.maxX, y: y(high)))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        guard samples.count > 1 else {
            // draw a single dot if we only have one reading
            if let v = samples.last {
                let c = colorFor(v)
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: b.maxX - 2, y: y(v) - 2, width: 4, height: 4))
            }
            return
        }

        let n = samples.count
        let line = CGMutablePath()
        for (i, v) in samples.enumerated() {
            let p = CGPoint(x: x(i, n), y: y(v))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }

        let latest = samples.last!
        let col = colorFor(latest)

        // fill under the curve
        let fill = line.mutableCopy()!
        fill.addLine(to: CGPoint(x: x(n - 1, n), y: b.minY))
        fill.addLine(to: CGPoint(x: b.minX, y: b.minY))
        fill.closeSubpath()
        ctx.addPath(fill)
        ctx.setFillColor(col.withAlphaComponent(0.15).cgColor)
        ctx.fillPath()

        // the line
        ctx.addPath(line)
        ctx.setStrokeColor(col.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }

    func colorFor(_ v: Double) -> NSColor {
        v >= high ? .systemRed : (v >= warn ? .systemOrange : .systemGreen)
    }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    var history: [Double] = []
    var current = EdgeSnapshot()
    var lastRecycled: Date?
    var lastNotified: Date?
    var redSince: Date?           // when Edge first went (and stayed) at/above highGB
    var isPrompting = false
    var isRecycling = false
    var didRequestAuth = false    // request notification permission only once, in-context

    let sparkline = SparklineView()
    var headerItem = NSMenuItem()
    var contextItem = NSMenuItem()
    var recycleItem = NSMenuItem()
    var lastItem = NSMenuItem()
    var notifyItem = NSMenuItem()

    var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    let kLastFiredDay = "lastFiredDay"
    let kSnoozeUntil  = "snoozeUntil"

    // Lightweight file logger for diagnosing notification/authorization issues.
    func diag(_ msg: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/edge-recycle.diag.log")
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func authStatusString(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    // ---- lifecycle -------------------------------------------------------

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        setupNotifications()
        seedInitialFireDayIfNeeded()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil)

        let t = Timer(timeInterval: Config.pollSeconds, target: self,
                      selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// If the app starts *after* today's trigger time (e.g. a mid-day install or
    /// a morning login past 8 AM with a freshly-launched Edge), don't ambush the
    /// user with a prompt the instant it launches — mark today as already
    /// handled. The genuine "asleep at 8 AM, wake at 9 AM" case still fires,
    /// because that's a wake event on an already-running app (which was seeded on
    /// a previous day).
    func seedInitialFireDayIfNeeded() {
        UserDefaults.standard.removeObject(forKey: kSnoozeUntil)
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = Config.triggerHour; comps.minute = Config.triggerMinute; comps.second = 0
        guard let trigger = cal.date(from: comps) else { return }
        if now >= trigger && UserDefaults.standard.string(forKey: kLastFiredDay) != dayKey(now) {
            UserDefaults.standard.set(dayKey(now), forKey: kLastFiredDay)
        }
    }

    // ---- menu ------------------------------------------------------------

    func buildMenu() {
        menu.delegate = self

        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let chartItem = NSMenuItem()
        sparkline.frame = NSRect(x: 0, y: 0, width: 240, height: 66)
        chartItem.view = sparkline
        menu.addItem(chartItem)

        contextItem.isEnabled = false
        menu.addItem(contextItem)

        menu.addItem(.separator())

        recycleItem = NSMenuItem(title: "Recycle Edge Now",
                                 action: #selector(recycleNow), keyEquivalent: "r")
        recycleItem.target = self
        menu.addItem(recycleItem)

        let sched = NSMenuItem(title: schedLabel(), action: nil, keyEquivalent: "")
        sched.isEnabled = false
        menu.addItem(sched)

        lastItem = NSMenuItem(title: "Last recycled: never", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        menu.addItem(lastItem)

        menu.addItem(.separator())

        let test = NSMenuItem(title: "Send Test Notification",
                              action: #selector(sendTestNotification), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        notifyItem = NSMenuItem(title: "Notifications: \u{2026}",
                              action: #selector(notificationsMenuAction), keyEquivalent: "")
        notifyItem.target = self
        menu.addItem(notifyItem)

        let quit = NSMenuItem(title: "Quit Edge Recycler",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshNotifyItem()
        refreshUI()
    }

    func schedLabel() -> String {
        let h = Config.triggerHour
        let disp = (h % 12 == 0) ? 12 : h % 12
        return String(format: "Daily check at %d:%02d %@", disp, Config.triggerMinute,
                      h < 12 ? "AM" : "PM")
    }

    func state(_ gb: Double) -> MemState {
        gb >= Config.highGB ? .red : (gb >= Config.warnGB ? .yellow : .green)
    }

    func refreshUI() {
        let gb = current.gb
        let st = state(gb)
        let word = (st == .red) ? "Restart recommended" : (st == .yellow ? "Heavy" : "Healthy")
        let color: NSColor = (st == .red) ? .systemRed : (st == .yellow ? .systemOrange : .systemGreen)

        // header with colored status dot
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "\u{25CF} ",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12)]))
        let title = current.mainPid == nil
            ? "Edge not running"
            : String(format: "Edge memory: %.2f GB \u{2014} %@", gb, word)
        head.append(NSAttributedString(string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor]))
        headerItem.attributedTitle = head

        contextItem.title = String(format: "%d Edge processes  \u{00B7}  load %.1f",
                                    current.procs, Sampler.loadAvg1())

        sparkline.samples = history
        sparkline.warn = Config.warnGB
        sparkline.high = Config.highGB
        sparkline.needsDisplay = true

        recycleItem.title = isRecycling ? "Recycling\u{2026}" : "Recycle Edge Now"
        recycleItem.action = isRecycling ? nil : #selector(recycleNow)

        if let d = lastRecycled {
            let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
            lastItem.title = "Last recycled: \(f.string(from: d))"
        }

        updateBarButton(st, gb: gb)
    }

    func updateBarButton(_ st: MemState, gb: Double) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let color: NSColor
        switch st {
        case .green:  symbol = "circle.fill";   color = .systemGreen
        case .yellow: symbol = "triangle.fill"; color = .systemYellow
        case .red:    symbol = "square.fill";   color = .systemRed
        }

        // Render the shape + number as one attributed string so we can vertically
        // center the symbol on the text's cap height. (Letting NSButton lay out a
        // separate image + title leaves the symbol looking low / the digits high,
        // because each is centered by different metrics.)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()

        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Edge memory status") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let img = base.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                let att = NSTextAttachment()
                att.image = img
                let h = img.size.height, w = img.size.width
                att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
                result.append(NSAttributedString(attachment: att))
            }
        }

        // show the number in the bar only when things are elevated
        if !(st == .green || current.mainPid == nil) {
            result.append(NSAttributedString(
                string: String(format: "  %.1f GB", gb),
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        button.image = nil
        button.attributedTitle = result
    }

    func menuWillOpen(_ menu: NSMenu) {
        sampleNow()   // make sure the dropdown shows a fresh reading
        refreshUI()
        refreshNotifyItem()
    }

    func menuDidClose(_ menu: NSMenu) {
        // Request notification permission the first time the user interacts with
        // the menu — but only AFTER it closes, so we're out of the menu's modal
        // tracking loop and the app can activate for the prompt to stick (per
        // Apple: request in-context while active, never at launch/background).
        requestAuthInContextIfNeeded()
    }

    // ---- polling + schedule ---------------------------------------------

    @objc func onWake() { tick() }

    func sampleNow() {
        current = Sampler.snapshot()
        // Maintain the sustained-high streak here (not only in checkHighMemory),
        // so every sample path — timer, menu open, post-recycle — keeps redSince
        // consistent. A dropped/low sample or a missing Edge always resets it,
        // which prevents a stale streak from firing an immediate alert.
        if current.mainPid != nil {
            history.append(current.gb)
            if history.count > Config.historyCount { history.removeFirst(history.count - Config.historyCount) }
            if state(current.gb) == .red {
                if redSince == nil { redSince = Date() }
            } else {
                redSince = nil
            }
        } else {
            redSince = nil
        }
    }

    @objc func tick() {
        sampleNow()
        refreshUI()
        checkHighMemory()
        checkSchedule()
    }

    func checkHighMemory() {
        // redSince is maintained by sampleNow(). Alert only once Edge has been
        // continuously at/above highGB for sustainMinutes, respecting cooldown,
        // and only mark lastNotified when the notification actually posts.
        guard current.mainPid != nil, let since = redSince else { return }
        let now = Date()
        guard now.timeIntervalSince(since) >= Config.sustainMinutes * 60 else { return }
        if let last = lastNotified, now.timeIntervalSince(last) < Config.notifyCooldown { return }
        let mins = Int(now.timeIntervalSince(since) / 60)
        let gb = current.gb
        postHighMemoryNotification(gb: gb, sustainedMinutes: mins) { ok in
            if ok { self.lastNotified = Date() }   // completion is delivered on main
        }
    }

    func checkSchedule() {
        if isPrompting || isRecycling { return }
        let now = Date()
        let snooze = UserDefaults.standard.double(forKey: kSnoozeUntil)
        if snooze > 0 && now.timeIntervalSince1970 < snooze { return }

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = Config.triggerHour; comps.minute = Config.triggerMinute; comps.second = 0
        guard let trigger = cal.date(from: comps), now >= trigger else { return }
        if UserDefaults.standard.string(forKey: kLastFiredDay) == dayKey(now) { return }
        if current.mainPid == nil { return }   // only nag while Edge is running

        promptDaily()
    }

    func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    func markFiredToday() {
        UserDefaults.standard.set(dayKey(Date()), forKey: kLastFiredDay)
        UserDefaults.standard.removeObject(forKey: kSnoozeUntil)
    }

    func promptDaily() {
        isPrompting = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Recycle Microsoft Edge?"
        a.informativeText = String(format:
            "Edge is using %.1f GB. Restarting releases that memory and your tabs reopen automatically. Close and reopen now?",
            current.gb)
        a.addButton(withTitle: "Restart Now")
        a.addButton(withTitle: "Delay 1 Hour")
        a.addButton(withTitle: "Skip Today")
        let r = a.runModal()
        isPrompting = false
        switch r {
        case .alertFirstButtonReturn:  markFiredToday(); recycleEdge()
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: kSnoozeUntil)
        default: markFiredToday()
        }
    }

    // ---- actions ---------------------------------------------------------

    @objc func recycleNow() {
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = Config.triggerHour; comps.minute = Config.triggerMinute; comps.second = 0
        if let trigger = cal.date(from: comps), now >= trigger, current.mainPid != nil {
            markFiredToday()   // a manual recycle counts as today's cycle
        }
        recycleEdge()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    func recycleEdge() {
        if isRecycling { return }
        isRecycling = true
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async {
            let snap = Sampler.snapshot()
            if let pid = snap.mainPid {
                kill(pid, SIGTERM)
                var exited = false
                for _ in 0..<25 {
                    if Sampler.snapshot().mainPid == nil { exited = true; break }
                    Thread.sleep(forTimeInterval: 1)
                }
                if !exited {
                    DispatchQueue.main.async {
                        self.isRecycling = false
                        self.refreshUI()
                        self.showBusyAlert()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Microsoft Edge", "--args", "--restore-last-session"]
            try? p.run(); p.waitUntilExit()

            DispatchQueue.main.async {
                self.lastRecycled = Date()
                self.isRecycling = false
                self.redSince = nil          // fresh Edge — start the streak clock over
                self.history.removeAll()
                self.sampleNow()
                self.refreshUI()
            }
        }
    }

    func showBusyAlert() {
        let a = NSAlert()
        a.messageText = "Couldn't close Edge"
        a.informativeText = "Edge didn't quit within 25 seconds \u{2014} a page may be showing a \u{201C}Leave site?\u{201D} prompt. Nothing was forced; try again in a moment."
        a.runModal()
    }

    // ---- notifications (native UserNotifications) ------------------------
    //
    // Permission model (per Apple's "Asking permission to use notifications"):
    //   * We NEVER call requestAuthorization at launch. A background LSUIElement
    //     agent isn't frontmost, so the system prompt would be auto-dismissed and
    //     permanently recorded as "denied" — after which no request ever prompts
    //     again. That's the bug we hit originally.
    //   * Instead we request exactly once, in-context, when the user opens the
    //     menu (an explicit interaction) with the app activated, so the prompt
    //     shows and sticks. Delivery then uses native Notification Center banners.

    func setupNotifications() {
        guard hasBundle else { diag("no bundle id; notifications unavailable"); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: "RECYCLE",
                        title: "Restart Edge Now", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "EDGE_HIGH",
                        actions: [action], intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
        center.getNotificationSettings { s in
            self.diag("launch settings: auth=\(self.authStatusString(s.authorizationStatus))")
        }
    }

    /// Request permission once, in-context, while the app is active so the system
    /// prompt actually appears and its result is recorded. All state (didRequestAuth)
    /// is touched only on the main queue to avoid races between callers
    /// (menuDidClose, Send Test, the Notifications item). `then` always runs on main.
    func requestAuthInContextIfNeeded(_ then: (() -> Void)? = nil) {
        guard hasBundle else { then?(); return }
        DispatchQueue.main.async {
            if self.didRequestAuth { then?(); return }   // already asked this session
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { s in
                DispatchQueue.main.async {
                    if self.didRequestAuth { then?(); return }
                    guard s.authorizationStatus == .notDetermined else { then?(); return }
                    self.didRequestAuth = true
                    NSApp.activate(ignoringOtherApps: true)
                    center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                        self.diag("in-context requestAuthorization -> granted=\(granted) err=\(err?.localizedDescription ?? "nil")")
                        DispatchQueue.main.async { self.refreshNotifyItem(); then?() }
                    }
                }
            }
        }
    }

    /// Post a native notification if authorized. `completion(success)` is always
    /// invoked on the main queue so callers can update state (e.g. lastNotified)
    /// only when a notification actually posted.
    func notify(title: String, body: String, offerRecycle: Bool, completion: ((Bool) -> Void)? = nil) {
        guard hasBundle else { DispatchQueue.main.async { completion?(false) }; return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                self.diag("notify skipped: not authorized (\(self.authStatusString(s.authorizationStatus)))")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            if offerRecycle { c.categoryIdentifier = "EDGE_HIGH" }
            c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                if let err = err { self.diag("notify add() error: \(err.localizedDescription)") }
                DispatchQueue.main.async { completion?(err == nil) }
            }
        }
    }

    func postHighMemoryNotification(gb: Double, sustainedMinutes: Int, completion: ((Bool) -> Void)? = nil) {
        notify(title: "Edge is using a lot of memory",
               body: String(format: "Edge has been above %.1f GB for %d min (now %.1f GB). Restart to free it up?",
                            Config.highGB, sustainedMinutes, gb),
               offerRecycle: true, completion: completion)
    }

    @objc func sendTestNotification() {
        let gbNow = current.gb   // capture on main before going async
        requestAuthInContextIfNeeded {
            guard self.hasBundle else { return }
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async {
                    switch s.authorizationStatus {
                    case .denied:
                        self.offerOpenSettings()
                    case .authorized, .provisional:
                        self.notify(title: "Edge Recycler",
                                    body: String(format: "Test notification. Edge is at %.2f GB right now.", gbNow),
                                    offerRecycle: false)
                    default:
                        break   // notDetermined: the Allow prompt is up; nothing to do yet
                    }
                }
            }
        }
    }

    /// Menu item that reflects notification state and does the right thing:
    /// request (notDetermined), open Settings (denied), or send a test (authorized).
    @objc func notificationsMenuAction() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                switch s.authorizationStatus {
                case .notDetermined: self.requestAuthInContextIfNeeded()
                case .denied:        self.offerOpenSettings()
                default:             self.sendTestNotification()
                }
            }
        }
    }

    func refreshNotifyItem() {
        guard hasBundle else {
            DispatchQueue.main.async { self.notifyItem.title = "Notifications: unavailable" }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let label: String
            switch s.authorizationStatus {
            case .authorized:    label = "Notifications: on"
            case .provisional:   label = "Notifications: quiet (tap to enable banners)"
            case .denied:        label = "Notifications: off \u{2014} open Settings\u{2026}"
            case .notDetermined: label = "Enable Notifications\u{2026}"
            default:             label = "Notifications: \u{2026}"
            }
            DispatchQueue.main.async { self.notifyItem.title = label }
        }
    }

    func offerOpenSettings() {
        let a = NSAlert()
        a.messageText = "Notifications are turned off"
        a.informativeText = "Edge Recycler's notifications are disabled in System Settings. Turn on \u{201C}Allow Notifications\u{201D} for Edge Recycler to get high-memory and daily restart alerts."
        a.addButton(withTitle: "Open Notification Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openNotificationSettings() }
    }

    @objc func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // present banners even though we're an accessory app
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "RECYCLE" ||
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.recycleEdge() }
        }
        completionHandler()
    }
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let controller = AppController()
app.delegate = controller
app.run()
