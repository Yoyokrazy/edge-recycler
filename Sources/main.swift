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
//    defaults write com.edgerecycler.app thresholdMode  -string manual
//    defaults write com.edgerecycler.app manualHighGB   -float 6.0
//    defaults write com.edgerecycler.app sustainMinutes -int 15
// ============================================================================

// MARK: - Config

enum Config {
    static var triggerHour: Int  { intDefault("triggerHour", 8) }
    static var triggerMinute: Int { intDefault("triggerMinute", 0) }
    static var pollSeconds: Double { doubleDefault("pollSeconds", 60) }

    // Restart-threshold model. In "auto" mode the threshold is learned from a
    // rolling baseline (median) of observed usage; in "manual" mode the user
    // picks an absolute GB value.
    static var thresholdMode: String { UserDefaults.standard.string(forKey: "thresholdMode") ?? "auto" }
    static var manualHighGB: Double { doubleDefault("manualHighGB", 5.5) }
    static var autoMarginGB: Double { doubleDefault("autoMarginGB", 2.0) }   // auto threshold = baseline + margin
    static var autoFloorGB: Double { doubleDefault("autoFloorGB", 4.5) }     // …clamped to this range
    static var autoCeilGB: Double { doubleDefault("autoCeilGB", 12.0) }
    static var defaultHighGB: Double { doubleDefault("defaultHighGB", 5.5) } // used until a baseline exists

    /// Edge must stay at/above the threshold this long before we alert.
    static var sustainMinutes: Double { doubleDefault("sustainMinutes", 10) }
    static var notifyCooldown: Double { doubleDefault("notifyCooldown", 3600) }

    static var chartTopGB: Double { doubleDefault("chartTopGB", 8.0) }

    static var calibrationSamples: Int { intDefault("calibrationSamples", 60) } // ~1h before baseline is trusted
    static var maxStoredSamples: Int { intDefault("maxStoredSamples", 5000) }    // ~3.5 days at 60s

    /// Detect and alert when Edge is "Not Responding" (hung). On by default.
    static var hangDetection: Bool { boolDefault("hangDetection", true) }

    static func intDefault(_ k: String, _ d: Int) -> Int {
        UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.integer(forKey: k) : d
    }
    static func doubleDefault(_ k: String, _ d: Double) -> Double {
        UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.double(forKey: k) : d
    }
    static func boolDefault(_ k: String, _ d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.bool(forKey: k) : d
    }
    static func set(_ k: String, _ v: Double) { UserDefaults.standard.set(v, forKey: k) }
    static func set(_ k: String, _ v: String) { UserDefaults.standard.set(v, forKey: k) }
}

// MARK: - Persistent sample store (baseline learning)

struct Sample: Codable { let t: Double; let gb: Double }

/// Persists memory samples across launches so we can learn a baseline (median)
/// usage level and derive a sensible restart threshold. Stored as JSON under
/// ~/Library/Application Support/EdgeRecycler/state.json.
final class Store {
    static let shared = Store()
    private(set) var samples: [Sample] = []
    private(set) var installDate = Date().timeIntervalSince1970
    private(set) var existedAtLoad = false
    private var loaded = false

    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EdgeRecycler", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    private struct Persisted: Codable { var installDate: Double; var samples: [Sample] }

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            existedAtLoad = true
            installDate = p.installDate
            samples = p.samples
        } else {
            installDate = Date().timeIntervalSince1970
            save()
        }
    }

    func append(gb: Double) {
        samples.append(Sample(t: Date().timeIntervalSince1970, gb: gb))
        if samples.count > Config.maxStoredSamples {
            samples.removeFirst(samples.count - Config.maxStoredSamples)
        }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(Persisted(installDate: installDate, samples: samples)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Median GB across stored samples, or nil if we don't yet have `min` of them.
    func baseline(min: Int) -> Double? {
        let need = Swift.max(min, 1)          // never index into an empty array
        guard samples.count >= need else { return nil }
        let v = samples.map { $0.gb }.sorted()
        let m = v.count / 2
        return v.count % 2 == 0 ? (v[m - 1] + v[m]) / 2 : v[m]
    }

    /// Discard learned history so the baseline is re-learned from scratch.
    func reset() {
        samples.removeAll()
        installDate = Date().timeIntervalSince1970
        save()
    }

    var calibrated: Bool { samples.count >= Config.calibrationSamples }
}

enum MemState { case green, yellow, red }

// MARK: - Process / memory sampling (libproc)

struct EdgeSnapshot {
    var bytes: UInt64 = 0
    var procs: Int = 0
    var mainPid: pid_t? = nil
    var mainStart: UInt64 = 0   // main process start time (mach abstime) — identity
    var gb: Double { Double(bytes) / 1_073_741_824.0 }
}

enum Sampler {
    /// Bundle identifier of the Microsoft Edge (stable) browser app.
    static let edgeBundleID = "com.microsoft.edgemac"

    /// All live pids, sized from the current process count (with headroom) and
    /// retried once. A fixed-size buffer or a transient `proc_listallpids` hiccup
    /// could otherwise yield a short/empty list — which reads as "Edge not
    /// running" even while Edge is very much alive.
    private static func allPids() -> [pid_t] {
        for _ in 0..<2 {
            var cap = Int(proc_listallpids(nil, 0))   // current pid count (+ slack)
            if cap <= 0 { cap = 8192 }
            cap += 64                                 // headroom for churn between calls
            var pids = [pid_t](repeating: 0, count: cap)
            let n = proc_listallpids(&pids, Int32(cap * MemoryLayout<pid_t>.size))
            if n > 0 { return Array(pids.prefix(min(Int(n), cap))) }
        }
        return []
    }

    /// phys_footprint + start time (mach abstime) for one pid, or nil if the
    /// kernel query fails.
    private static func rusage(_ pid: pid_t) -> (bytes: UInt64, start: UInt64)? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rp)
            }
        }
        return rc == 0 ? (info.ri_phys_footprint, info.ri_proc_start_abstime) : nil
    }

    /// The Edge browser's pid as macOS's Process Manager reports it — a reliable,
    /// independent "is Edge running" signal that doesn't depend on the libproc
    /// path scan resolving every pid. Consulted only as a fallback, so it costs
    /// nothing on the common path.
    static func edgeAppPid() -> pid_t? {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == edgeBundleID && !app.isTerminated {
            let pid = app.processIdentifier
            if pid > 0 { return pid }
        }
        return nil
    }

    /// Enumerate every process belonging to the Microsoft Edge *browser* bundle
    /// (Teams' embedded WebView lives under a different .app path and is excluded)
    /// and sum each one's phys_footprint.
    static func snapshot() -> EdgeSnapshot {
        var snap = EdgeSnapshot()
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in allPids() {
            if pid <= 0 { continue }
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if len <= 0 { continue }
            let path = String(cString: pathBuf)
            guard path.contains("/Microsoft Edge.app/") else { continue }

            // The root browser process is the bare executable, not a Helper.
            let isMain = path.hasSuffix("/Contents/MacOS/Microsoft Edge")
            if isMain { snap.mainPid = pid }

            if let r = rusage(pid) {
                snap.bytes += r.bytes
                snap.procs += 1
                if isMain { snap.mainStart = r.start }
            }
        }

        // Resilience: if the path scan didn't pin the main browser process but
        // macOS still lists Edge as a running app, trust that. Guards against a
        // transient libproc miss flipping the UI to "Edge not running" while Edge
        // is alive. mainPid == nil here means the main process wasn't counted, so
        // adding its footprint can't double-count.
        if snap.mainPid == nil, let wsPid = edgeAppPid(), isAlive(wsPid) {
            snap.mainPid = wsPid
            if let r = rusage(wsPid) {
                snap.mainStart = r.start
                snap.bytes += r.bytes
                snap.procs += 1
            }
        }
        return snap
    }

    /// True if the given pid currently exists (signal 0 probes without sending).
    static func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }
}

// MARK: - Responsiveness ("Not Responding" detection)

/// Detects the same "Not Responding" state that the Dock, Activity Monitor, and
/// Force Quit show. macOS flags an app unresponsive when its main thread stops
/// servicing its event port past a timeout (deadlock, sync I/O, sync IPC wait).
///
/// We read that flag via the private CoreGraphics/SkyLight function
/// `CGSEventIsAppUnresponsive` (what Activity Monitor uses) — resolved at runtime
/// with dlsym so a missing symbol degrades gracefully instead of failing to
/// launch. It has a built-in time threshold, so it won't trip on brief blips.
enum Responsiveness {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias IsUnrespFn = @convention(c) (Int32, UnsafeRawPointer) -> Bool
    private typealias GetProcFn  = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static func global<T>(_ name: String, _ t: T.Type) -> T? {
        guard let h = dlopen(nil, RTLD_NOW), let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }
    private static func appServices<T>(_ name: String, _ t: T.Type) -> T? {
        let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        guard let h, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }

    private static let mainConn = global("CGSMainConnectionID", MainConnFn.self)
    private static let isUnresp = global("CGSEventIsAppUnresponsive", IsUnrespFn.self)
    private static let getProc  = appServices("GetProcessForPID", GetProcFn.self)

    static var available: Bool { mainConn != nil && isUnresp != nil && getProc != nil }

    /// True if macOS considers the process "Not Responding"; nil if undeterminable
    /// (API unavailable, or no Process-Manager PSN for the pid).
    static func isNotResponding(pid: pid_t) -> Bool? {
        guard let mainConn, let isUnresp, let getProc, pid > 0 else { return nil }
        var psn: (UInt32, UInt32) = (0, 0)
        return withUnsafeMutableBytes(of: &psn) { raw -> Bool? in
            guard let base = raw.baseAddress, getProc(pid, base) == 0 else { return nil }
            return isUnresp(mainConn(), UnsafeRawPointer(base))
        }
    }
}

// MARK: - Sparkline chart

final class SparklineView: NSView {
    var samples: [(t: Double, v: Double)] = []   // timestamped (epoch seconds)
    var windowSeconds: Double = 900               // x-axis span (time-calibrated)
    var maxGapSeconds: Double = 180               // break the line across bigger gaps
    var warn: Double = 4.0
    var high: Double = 5.5
    var baseline: Double? = nil

    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 72) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // redraw when the menu stretches us to fill its width
    }

    private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, align: NSTextAlignment = .left, color: NSColor = .tertiaryLabelColor) {
        let p = NSMutableParagraphStyle(); p.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: color, .paragraphStyle: p]
        let s = NSAttributedString(string: text, attributes: attrs)
        let w: CGFloat = 80
        let ox = align == .right ? x - w : x
        s.draw(in: CGRect(x: ox, y: y, width: w, height: 10))
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 10, dy: 12)
        let scale = max(Config.chartTopGB, high * 1.15)
        let now = Date().timeIntervalSince1970
        func y(_ v: Double) -> CGFloat { b.minY + CGFloat(min(v, scale) / scale) * b.height }
        // right edge = now; left edge = windowSeconds ago
        func x(_ t: Double) -> CGFloat {
            let age = min(max(now - t, 0), windowSeconds)
            return b.maxX - CGFloat(age / windowSeconds) * b.width
        }

        // y-axis reference labels (top = scale max, bottom = 0)
        label(String(format: "%.0f GB", scale), b.minX, b.maxY - 1)
        label("0", b.minX, b.minY - 10)

        // zero line
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: b.minX, y: b.minY)); ctx.addLine(to: CGPoint(x: b.maxX, y: b.minY)); ctx.strokePath()

        // x-axis time span, shown at the right end of the axis
        let mins = windowSeconds / 60.0
        let spanText = mins >= 90 ? String(format: "%.1fh", mins / 60.0) : String(format: "%dmin", Int(mins.rounded()))
        label(spanText, b.maxX, b.minY - 10, align: .right)

        // learned baseline (dotted gray) with label
        if let base = baseline, base > 0 {
            ctx.setLineDash(phase: 0, lengths: [1, 3])
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: b.minX, y: y(base))); ctx.addLine(to: CGPoint(x: b.maxX, y: y(base))); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            label(String(format: "baseline %.1f", base), b.maxX, y(base) + 1, align: .right, color: .secondaryLabelColor)
        }

        // restart threshold (dashed red) with label
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: b.minX, y: y(high))); ctx.addLine(to: CGPoint(x: b.maxX, y: y(high))); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        label(String(format: "restart %.1f", high), b.maxX, y(high) + 1, align: .right, color: .systemRed)

        // only plot samples within the window
        let pts = samples.filter { now - $0.t <= windowSeconds }.sorted { $0.t < $1.t }
        guard pts.count > 1 else {
            if let last = pts.last {
                let c = colorFor(last.v)
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: x(last.t) - 2, y: y(last.v) - 2, width: 4, height: 4))
            }
            return
        }

        let col = colorFor(pts.last!.v)

        // stroke the line, breaking across gaps longer than maxGapSeconds
        let line = CGMutablePath()
        var penDown = false
        for (i, s) in pts.enumerated() {
            let p = CGPoint(x: x(s.t), y: y(s.v))
            if i > 0 && (s.t - pts[i - 1].t) > maxGapSeconds { penDown = false }
            if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
        }
        ctx.addPath(line)
        ctx.setStrokeColor(col.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        // subtle fill under the most recent contiguous segment
        if let first = pts.first, let last = pts.last {
            let fill = CGMutablePath()
            fill.move(to: CGPoint(x: x(first.t), y: b.minY))
            for s in pts { fill.addLine(to: CGPoint(x: x(s.t), y: y(s.v))) }
            fill.addLine(to: CGPoint(x: x(last.t), y: b.minY))
            fill.closeSubpath()
            ctx.addPath(fill)
            ctx.setFillColor(col.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
        }
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

    var history: [(t: Double, v: Double)] = []   // timestamped in-session chart samples
    var current = EdgeSnapshot()
    var lastRecycled: Date?
    var lastNotified: Date?
    var lastHangNotified: Date?
    var notificationPending = false  // guards against duplicate in-flight notifications
    var redSince: Date?           // when Edge first went (and stayed) at/above the threshold
    var isHung = false            // Edge is currently "Not Responding"
    var hangConfirmScheduled = false  // a rising-edge confirm is already pending
    var edgeMainPid: pid_t = 0    // last-seen Edge browser pid (to detect restarts)
    var edgeMainStart: UInt64 = 0 // …and its start time, so PID reuse is detected
    var edgeFirstSeen = Date()    // when the current Edge process was first observed
    var isPrompting = false
    var isRecycling = false
    var didRequestAuth = false    // request notification permission only once, in-context

    let sparkline = SparklineView()
    var headerItem = NSMenuItem()
    var captionItem = NSMenuItem()
    var contextItem = NSMenuItem()
    var recycleItem = NSMenuItem()
    var lastItem = NSMenuItem()
    var notifyItem = NSMenuItem()
    var thresholdMenu = NSMenu()
    var sustainMenu = NSMenu()

    var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    // ---- learned threshold model ----------------------------------------

    /// Rolling median of observed usage, once we have enough samples.
    var baseline: Double? { Store.shared.baseline(min: Config.calibrationSamples) }
    var calibrated: Bool { Store.shared.calibrated }

    /// The GB level at which a sustained stay triggers a restart prompt.
    /// Auto = baseline + margin (clamped); until a baseline exists, a safe default.
    /// Always returns a finite, sanely-bounded value regardless of defaults input.
    var effectiveHigh: Double {
        let raw: Double
        if Config.thresholdMode == "manual" {
            raw = Config.manualHighGB
        } else if let b = baseline {
            raw = min(max(b + Config.autoMarginGB, Config.autoFloorGB), Config.autoCeilGB)
        } else {
            raw = Config.defaultHighGB
        }
        guard raw.isFinite, raw > 0 else { return 5.5 }   // bulletproof fallback
        return min(max(raw, 1.0), 64.0)
    }
    /// Yellow "heavy" level, guaranteed strictly below the restart threshold.
    var effectiveWarn: Double { min(max(effectiveHigh - 1.0, 3.0), effectiveHigh - 0.1) }

    /// The chart's x-axis span. Always covers at least the sustained-restart
    /// duration (with headroom) so you can see the whole "about to be nagged"
    /// window, with a sensible floor so it's never too cramped to read.
    var chartWindowMinutes: Double { max(Config.sustainMinutes * 1.5, 10) }
    var chartWindowSeconds: Double { chartWindowMinutes * 60 }

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
        Store.shared.load()
        diag("hang detection available: \(Responsiveness.available)")
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
        maybeOnboard()
    }

    /// One-time welcome on first install: explain the app and offer to restart
    /// Edge now so baseline learning starts from a clean slate.
    func maybeOnboard() {
        guard !UserDefaults.standard.bool(forKey: "didOnboard") else { return }
        UserDefaults.standard.set(true, forKey: "didOnboard")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Welcome to Edge Recycler"
            a.informativeText = "It watches how much memory Microsoft Edge uses and can restart it — restoring your tabs — when it bloats.\n\nFor about the next hour it will learn your normal usage (a baseline) and then set a smart restart level automatically. You can adjust it anytime from the menu.\n\nStart from a clean slate by restarting Edge now?"
            a.addButton(withTitle: "Restart Edge Now")
            a.addButton(withTitle: "Not Now")
            if a.runModal() == .alertFirstButtonReturn { self.restartForCleanBaseline() }
        }
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
        sparkline.frame = NSRect(x: 0, y: 0, width: 240, height: 72)
        // Let the menu stretch the chart to fill the full content width it
        // computes (including the trailing column it reserves for submenu
        // chevrons), rather than us estimating text widths.
        sparkline.autoresizingMask = [.width]
        chartItem.view = sparkline
        menu.addItem(chartItem)

        captionItem.isEnabled = false
        captionItem.attributedTitle = NSAttributedString(string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: 10)])
        menu.addItem(captionItem)

        contextItem.isEnabled = false
        menu.addItem(contextItem)

        menu.addItem(.separator())

        recycleItem = NSMenuItem(title: "Recycle Edge Now",
                                 action: #selector(recycleNow), keyEquivalent: "")
        recycleItem.target = self
        menu.addItem(recycleItem)

        let redetect = NSMenuItem(title: "Check for Edge Now",
                                  action: #selector(redetectEdge), keyEquivalent: "")
        redetect.target = self
        redetect.toolTip = "Re-scan for Microsoft Edge right now. Use this if the status looks wrong or hasn\u{2019}t caught up yet."
        menu.addItem(redetect)

        // Restart-threshold submenu
        let threshItem = NSMenuItem(title: "Restart when above", action: nil, keyEquivalent: "")
        threshItem.submenu = thresholdMenu
        menu.addItem(threshItem)

        // Sustained-duration submenu
        let sustainItem = NSMenuItem(title: "Sustained for", action: nil, keyEquivalent: "")
        sustainItem.submenu = sustainMenu
        menu.addItem(sustainItem)

        let recal = NSMenuItem(title: "Recalibrate Baseline\u{2026}",
                               action: #selector(recalibrate), keyEquivalent: "")
        recal.target = self
        menu.addItem(recal)

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
        rebuildConfigMenus()
        refreshNotifyItem()
        refreshUI()
    }

    // ---- config submenus -------------------------------------------------

    let thresholdPresets: [Double] = [4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 8.0]
    let sustainPresets: [Double] = [5, 10, 15, 20, 30, 45, 60]

    func rebuildConfigMenus() {
        thresholdMenu.removeAllItems()
        let auto = NSMenuItem(title: String(format: "Auto — learned (%.1f GB)", effectiveHigh),
                              action: #selector(setThresholdAuto), keyEquivalent: "")
        auto.target = self
        auto.state = (Config.thresholdMode == "auto") ? .on : .off
        thresholdMenu.addItem(auto)
        thresholdMenu.addItem(.separator())
        for v in thresholdPresets {
            let it = NSMenuItem(title: String(format: "%.1f GB", v),
                                action: #selector(setThresholdPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = (Config.thresholdMode == "manual" && abs(Config.manualHighGB - v) < 0.001) ? .on : .off
            thresholdMenu.addItem(it)
        }
        thresholdMenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom\u{2026}", action: #selector(setThresholdCustom), keyEquivalent: "")
        custom.target = self
        let isPreset = thresholdPresets.contains { abs($0 - Config.manualHighGB) < 0.001 }
        custom.state = (Config.thresholdMode == "manual" && !isPreset) ? .on : .off
        thresholdMenu.addItem(custom)

        sustainMenu.removeAllItems()
        for m in sustainPresets {
            let it = NSMenuItem(title: "\(Int(m)) min",
                                action: #selector(setSustainPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m
            it.state = (abs(Config.sustainMinutes - m) < 0.001) ? .on : .off
            sustainMenu.addItem(it)
        }
    }

    @objc func setThresholdAuto() { Config.set("thresholdMode", "auto"); afterThresholdChange() }

    @objc func setThresholdPreset(_ item: NSMenuItem) {
        guard let v = item.representedObject as? Double else { return }
        Config.set("thresholdMode", "manual"); Config.set("manualHighGB", v); afterThresholdChange()
    }

    @objc func setThresholdCustom() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Custom restart threshold"
        a.informativeText = "Prompt to restart when Edge stays above this many GB for the sustained duration. Enter a value between 1 and 64."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        tf.stringValue = String(format: "%.1f", effectiveHigh)
        a.accessoryView = tf
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn,
           let v = Double(tf.stringValue.trimmingCharacters(in: .whitespaces)),
           v.isFinite, v >= 1.0, v <= 64.0 {
            Config.set("thresholdMode", "manual"); Config.set("manualHighGB", v); afterThresholdChange()
        }
    }

    @objc func setSustainPreset(_ item: NSMenuItem) {
        guard let m = item.representedObject as? Double else { return }
        Config.set("sustainMinutes", m); afterSustainChange()
    }

    /// Threshold changed → the streak must be re-judged against the new level.
    func afterThresholdChange() {
        redSince = nil
        sampleNow()
        updateStreak()
        rebuildConfigMenus()
        refreshUI()
    }

    /// Only the sustained-duration changed → preserve any ongoing streak so an
    /// already-high Edge isn't given a fresh grace period. updateStreak() keeps
    /// redSince when still red and clears it if Edge has since dropped/exited.
    func afterSustainChange() {
        sampleNow()
        updateStreak()
        rebuildConfigMenus()
        refreshUI()
    }

    /// Clear the learned baseline and restart Edge so learning begins from a
    /// clean slate. Shared by first-run onboarding and recalibration.
    func restartForCleanBaseline() {
        Store.shared.reset()
        redSince = nil
        history.removeAll()
        recycleEdge()          // async; re-samples + refreshes on completion
        rebuildConfigMenus()
        refreshUI()
    }

    /// Let the user throw away the learned baseline and re-learn from scratch —
    /// useful after their usage habits change, or to reset a skewed baseline.
    /// Optionally restarts Edge first so learning starts from a clean slate.
    @objc func recalibrate() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Recalibrate baseline?"
        a.informativeText = "This clears the learned memory history and re-learns your normal usage over about the next hour. While it re-learns, the restart threshold falls back to its default.\n\nRestart Edge now for the cleanest baseline?"
        a.addButton(withTitle: "Restart Edge & Recalibrate")
        a.addButton(withTitle: "Recalibrate Only")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            restartForCleanBaseline()
        case .alertSecondButtonReturn:
            Store.shared.reset()
            afterThresholdChange()
        default:
            break
        }
    }

    func schedLabel() -> String {
        let h = Config.triggerHour
        let disp = (h % 12 == 0) ? 12 : h % 12
        return String(format: "Daily check at %d:%02d %@", disp, Config.triggerMinute,
                      h < 12 ? "AM" : "PM")
    }

    func state(_ gb: Double) -> MemState {
        gb >= effectiveHigh ? .red : (gb >= effectiveWarn ? .yellow : .green)
    }

    func refreshUI() {
        let gb = current.gb
        let memState = state(gb)
        // A hang is the most urgent state — surface it as red regardless of memory.
        let hung = isHung && current.mainPid != nil
        let st: MemState = hung ? .red : memState
        let word = (memState == .red) ? "Restart recommended" : (memState == .yellow ? "Heavy" : "Healthy")
        let color: NSColor = (st == .red) ? .systemRed : (st == .yellow ? .systemOrange : .systemGreen)

        // header with colored status dot
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "\u{25CF} ",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12)]))
        let title: String
        if current.mainPid == nil {
            title = "Edge not running"
        } else if hung {
            title = String(format: "Edge isn\u{2019}t responding \u{2014} %.1f GB", gb)
        } else {
            title = String(format: "Edge memory: %.2f GB \u{2014} %@", gb, word)
        }
        head.append(NSAttributedString(string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor]))
        headerItem.attributedTitle = head

        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let totalGBInt = Int(totalGB.rounded())
        if current.mainPid == nil {
            contextItem.title = totalGB > 0 ? "Your Mac has \(totalGBInt) GB of memory" : ""
        } else {
            let pct = totalGB > 0 ? Int((gb / totalGB * 100).rounded()) : 0
            contextItem.title = String(format: "%d Edge processes  \u{00B7}  %d%% of your %d GB of memory",
                                       current.procs, pct, totalGBInt)
        }
        contextItem.toolTip = "Edge runs one process per tab/site plus helpers (GPU, network, extensions), so the count roughly tracks how much you have open. The percentage is Edge's total memory as a share of your Mac's installed RAM."

        // Caption below the chart: threshold mode + calibration status. (The
        // timeframe and line meanings are labeled directly on the chart now.)
        let modeText = Config.thresholdMode == "auto" ? "auto" : "manual"
        let statusText: String
        if let b = baseline {
            statusText = String(format: "baseline %.1f GB", b)
        } else if current.mainPid == nil {
            statusText = "learning baseline\u{2026}"
        } else {
            let need = max(Config.calibrationSamples - Store.shared.samples.count, 0)
            statusText = "learning baseline (~\(need) min left)"
        }
        captionItem.attributedTitle = NSAttributedString(
            string: String(format: "restart at %.1f GB (%@)  \u{00B7}  %@", effectiveHigh, modeText, statusText),
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.secondaryLabelColor])

        sparkline.samples = history
        sparkline.windowSeconds = chartWindowSeconds
        sparkline.maxGapSeconds = max(Config.pollSeconds * 2.5, 150)
        sparkline.warn = effectiveWarn
        sparkline.high = effectiveHigh
        sparkline.baseline = baseline
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
        // Always a filled circle; only the color conveys state.
        let color: NSColor
        switch st {
        case .green:  color = .systemGreen
        case .yellow: color = .systemYellow
        case .red:    color = .systemRed
        }

        // Render the circle + number as one attributed string so we can vertically
        // center the glyph on the text's cap height. (Letting NSButton lay out a
        // separate image + title leaves the dot looking low / the digits high,
        // because each is centered by different metrics.)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()

        if let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Edge memory status") {
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

        // Always show the GB figure next to the dot while Edge is running.
        if current.mainPid != nil {
            result.append(NSAttributedString(
                string: String(format: "  %.1f GB", gb),
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        button.image = nil
        button.attributedTitle = result
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshReading()   // make sure the dropdown shows a fresh reading
    }

    /// Re-sample Edge and refresh everything the menu shows. Shared by the menu's
    /// open handler and the manual "Check for Edge Now" action.
    func refreshReading() {
        sampleNow()
        updateStreak()
        checkResponsiveness()
        rebuildConfigMenus()
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
        if current.mainPid != nil {
            let now = Date().timeIntervalSince1970
            history.append((now, current.gb))
            // Keep a little more than the visible window so the line reaches the
            // left edge; drop anything older, and hard-cap count as a safety net.
            let cutoff = now - chartWindowSeconds - Config.pollSeconds
            history.removeAll { $0.t < cutoff }
            if history.count > 2000 { history.removeFirst(history.count - 2000) }
        }
    }

    /// Evaluate the continuous "at/above threshold" streak. Must be called AFTER
    /// any Store.append that could shift the learned threshold, so the streak is
    /// judged against the same threshold the UI shows. A non-red or absent-Edge
    /// sample always clears the streak, preventing a stale start time from firing.
    func updateStreak() {
        if current.mainPid != nil, state(current.gb) == .red {
            if redSince == nil { redSince = Date() }
        } else {
            redSince = nil
        }
    }

    @objc func tick() {
        sampleNow()
        // Persist one baseline sample per poll — but not while recycling, when
        // Edge memory is transitional and would skew the learned baseline.
        if current.mainPid != nil && !isRecycling { Store.shared.append(gb: current.gb) }
        updateStreak()   // after append, so it uses the freshly-updated threshold
        checkResponsiveness()
        refreshUI()
        checkHighMemory()
        checkSchedule()
    }

    /// Detect Edge's "Not Responding" state and, on a confirmed hang, prompt to
    /// restart. Guards against false positives: a freshly-launched app reads as
    /// unresponsive until it starts pumping its run loop, so we ignore hangs until
    /// the Edge process has been alive a while, and we re-confirm rising edges
    /// after a short delay. Process identity is (pid, start time) so a reused PID
    /// isn't mistaken for the old, already-settled process.
    func checkResponsiveness() {
        guard Config.hangDetection, !isRecycling, let pid = current.mainPid else {
            // Edge disabled/absent → clear hang and re-arm the settle gate so a
            // returning Edge (even with a reused PID) gets the cold-start grace.
            if isHung { isHung = false }
            edgeMainPid = 0; edgeMainStart = 0; hangConfirmScheduled = false
            return
        }
        if pid != edgeMainPid || current.mainStart != edgeMainStart {
            edgeMainPid = pid; edgeMainStart = current.mainStart
            edgeFirstSeen = Date(); isHung = false; hangConfirmScheduled = false
        }
        guard Date().timeIntervalSince(edgeFirstSeen) >= 45 else { return }  // ignore cold-start

        switch Responsiveness.isNotResponding(pid: pid) {
        case .some(true):
            if isHung {
                maybeNotifyHang()                 // still hung — renotify per cooldown
            } else if !hangConfirmScheduled {
                hangConfirmScheduled = true
                let confirmPid = pid
                let confirmStart = current.mainStart
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.hangConfirmScheduled = false
                    guard !self.isRecycling, self.current.mainPid == confirmPid,
                          self.current.mainStart == confirmStart,
                          Responsiveness.isNotResponding(pid: confirmPid) == .some(true) else { return }
                    self.isHung = true
                    self.refreshUI()
                    self.maybeNotifyHang()
                }
            }
        case .some(false):
            isHung = false                        // definitely responsive → clear
        case .none:
            break                                 // indeterminate → preserve current state
        }
    }

    func maybeNotifyHang() {
        let now = Date()
        if let last = lastHangNotified, now.timeIntervalSince(last) < Config.notifyCooldown { return }
        if notificationPending { return }
        notificationPending = true
        notify(title: "Edge isn\u{2019}t responding",
               body: "Edge has stopped responding. Restart it? Your tabs will reopen.",
               offerRecycle: true) { ok in
            self.notificationPending = false
            if ok { self.lastHangNotified = Date() }
        }
    }

    func checkHighMemory() {
        // Alert only once Edge is currently red AND has been continuously so for
        // sustainMinutes, respecting the cooldown, with no notification already in
        // flight. lastNotified is set only when a notification actually posts.
        guard current.mainPid != nil, state(current.gb) == .red, let since = redSince else { return }
        let now = Date()
        guard now.timeIntervalSince(since) >= Config.sustainMinutes * 60 else { return }
        if let last = lastNotified, now.timeIntervalSince(last) < Config.notifyCooldown { return }
        if notificationPending { return }
        notificationPending = true
        let mins = Int(now.timeIntervalSince(since) / 60)
        let gb = current.gb
        postHighMemoryNotification(gb: gb, sustainedMinutes: mins) { ok in
            self.notificationPending = false          // completion is delivered on main
            if ok { self.lastNotified = Date() }
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

    /// Force an immediate, fresh detection pass (the same refresh the menu does on
    /// open) and report what was found — a manual recovery path if a poll ever
    /// misreads Edge's state.
    @objc func redetectEdge() {
        refreshReading()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if let pid = current.mainPid {
            a.messageText = "Edge detected"
            if current.procs > 0 {
                a.informativeText = String(format:
                    "Microsoft Edge is running (pid %d), using %.2f GB across %d process%@.",
                    pid, current.gb, current.procs, current.procs == 1 ? "" : "es")
            } else {
                a.informativeText = String(format:
                    "Microsoft Edge is running (pid %d). Memory usage will refresh on the next check.", pid)
            }
        } else {
            a.messageText = "Edge not detected"
            a.informativeText = String(format:
                "Microsoft Edge doesn\u{2019}t appear to be running right now. If it is open, wait a moment and try again \u{2014} the next automatic check runs within %d seconds.",
                Int(Config.pollSeconds))
        }
        a.runModal()
    }

    func recycleEdge() {
        if isRecycling { return }
        isRecycling = true
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async {
            // Capture the specific process we intend to end, by identity, so we
            // never signal or "wait out" a *different* Edge that started meanwhile.
            let target = Sampler.snapshot().mainPid
            if let pid = target {
                kill(pid, SIGTERM)   // graceful — lets Edge save its session
                var exited = false
                for _ in 0..<25 {
                    if !Sampler.isAlive(pid) { exited = true; break }   // wait on THIS pid
                    Thread.sleep(forTimeInterval: 1)
                }
                if !exited {
                    DispatchQueue.main.async {
                        self.isRecycling = false
                        self.refreshUI()
                        self.showBusyAlert(targetPid: pid)   // offer Force Quit for this pid
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }

            let launched = self.launchEdge()

            DispatchQueue.main.async {
                self.isRecycling = false
                if launched {
                    self.lastRecycled = Date()
                    self.isHung = false          // fresh Edge is responsive again
                    self.redSince = nil          // fresh Edge — start the streak clock over
                    self.edgeMainPid = 0; self.edgeMainStart = 0   // re-arm settle gate
                    self.history.removeAll()
                }
                self.sampleNow()
                self.updateStreak()
                self.refreshUI()
                if !launched {
                    self.showFailedAlert("Couldn\u{2019}t reopen Edge",
                        "Edge was closed but didn\u{2019}t come back. Open it manually from Applications.")
                }
            }
        }
    }

    /// Relaunch Edge with session restore; returns true only once an Edge main
    /// process is actually observed (so we never falsely report success).
    func launchEdge() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Microsoft Edge", "--args", "--restore-last-session"]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        if p.terminationStatus != 0 { return false }   // `open` couldn't find/launch it
        for _ in 0..<20 {                              // confirm a process appears (≤10s)
            if Sampler.snapshot().mainPid != nil { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func showBusyAlert(targetPid: pid_t) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Couldn\u{2019}t close Edge"
        a.informativeText = "Edge didn\u{2019}t quit within 25 seconds \u{2014} it may be unresponsive, or a page may be showing a \u{201C}Leave site?\u{201D} prompt.\n\nForce Quit will end it immediately and reopen it with your tabs. Unsaved changes in a page could be lost."
        a.addButton(withTitle: "Force Quit & Reopen")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Only force-quit if that exact process is still around; otherwise it
        // already exited (or was replaced) — just make sure Edge is running.
        if Sampler.isAlive(targetPid) {
            forceQuitAndRelaunch(pid: targetPid)
        } else if Sampler.snapshot().mainPid == nil {
            recycleEdge()   // nothing to kill; this just relaunches
        }
    }

    /// Force-quit one specific process (by identity) then relaunch Edge.
    func forceQuitAndRelaunch(pid: pid_t) {
        if isRecycling { return }
        isRecycling = true
        refreshUI()
        DispatchQueue.global(qos: .userInitiated).async {
            if Sampler.isAlive(pid) {
                kill(pid, SIGKILL)
                for _ in 0..<20 { if !Sampler.isAlive(pid) { break }; Thread.sleep(forTimeInterval: 0.5) }
            }
            if Sampler.isAlive(pid) {   // SIGKILL should never fail for our own user
                DispatchQueue.main.async {
                    self.isRecycling = false; self.refreshUI()
                    self.showFailedAlert("Force Quit couldn\u{2019}t end Edge",
                        "Edge (pid \(pid)) is still running. Use Force Quit from Activity Monitor.")
                }
                return
            }
            Thread.sleep(forTimeInterval: 1)
            let launched = self.launchEdge()
            DispatchQueue.main.async {
                self.isRecycling = false
                if launched {
                    self.lastRecycled = Date(); self.isHung = false; self.redSince = nil
                    self.edgeMainPid = 0; self.edgeMainStart = 0; self.history.removeAll()
                }
                self.sampleNow(); self.updateStreak(); self.refreshUI()
                if !launched {
                    self.showFailedAlert("Couldn\u{2019}t reopen Edge",
                        "Edge was closed but didn\u{2019}t come back. Open it manually from Applications.")
                }
            }
        }
    }

    func showFailedAlert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
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
                            effectiveHigh, sustainedMinutes, gb),
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
