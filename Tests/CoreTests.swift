// ============================================================================
// EdgeRecyclerCore unit tests
// ----------------------------------------------------------------------------
// A dependency-free test runner (no XCTest / SwiftPM) matching the project's
// "one self-contained binary, simple swiftc build" style. `./test.sh` compiles
// this together with Sources/EdgeRecyclerCore.swift and runs it; it exits
// non-zero if any check fails, so CI can gate on it.
// ============================================================================

import Foundation

@main
struct CoreTests {
    static var checks = 0
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("  FAIL: \(message)") }
    }

    static func eq(_ got: Double, _ want: Double, _ message: String, tol: Double = 1e-9) {
        check(abs(got - want) <= tol, "\(message) — got \(got), want \(want)")
    }

    static func main() {
        testResolvedHighGB()
        testWarnGB()
        testMemState()
        testMedian()
        testPressure()
        testRamSharePercent()
        testEdgeIsSystemCulprit()

        let passed = checks - failures
        print("\n\(passed)/\(checks) checks passed")
        if failures > 0 {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
        print("OK")
    }

    // MARK: resolvedHighGB

    static func testResolvedHighGB() {
        print("resolvedHighGB")
        func high(_ mode: String, manual: Double = 5.5, baseline: Double? = nil,
                  margin: Double = 2.0, floor: Double = 4.5, ceil: Double = 12.0,
                  def: Double = 5.5) -> Double {
            Thresholds.resolvedHighGB(mode: mode, manualHighGB: manual, baseline: baseline,
                                      autoMarginGB: margin, autoFloorGB: floor,
                                      autoCeilGB: ceil, defaultHighGB: def)
        }

        // manual mode returns the user's value…
        eq(high("manual", manual: 6.0), 6.0, "manual passes through")
        // …but is clamped to [1, 64] and rejects non-finite / non-positive.
        eq(high("manual", manual: 999), 64.0, "manual clamps to ceil 64")
        eq(high("manual", manual: 0.5), 1.0, "manual clamps up to floor 1")
        eq(high("manual", manual: 0), 5.5, "manual 0 → bulletproof fallback 5.5")
        eq(high("manual", manual: -3), 5.5, "manual negative → fallback 5.5")
        eq(high("manual", manual: .nan), 5.5, "manual NaN → fallback 5.5")
        eq(high("manual", manual: .infinity), 5.5, "manual inf → fallback 5.5")

        // auto mode = baseline + margin, clamped to [floor, ceil].
        eq(high("auto", baseline: 4.0), 6.0, "auto baseline+margin within range")
        eq(high("auto", baseline: 1.0), 4.5, "auto clamps up to floor")
        eq(high("auto", baseline: 20.0), 12.0, "auto clamps down to ceil")
        // auto without a baseline falls back to the default (then [1,64] clamp).
        eq(high("auto", baseline: nil, def: 5.5), 5.5, "auto no-baseline → default")
        eq(high("auto", baseline: nil, def: 100), 64.0, "auto no-baseline default clamps to 64")
    }

    // MARK: warnGB

    static func testWarnGB() {
        print("warnGB")
        eq(Thresholds.warnGB(high: 5.5), 4.5, "warn = high-1 when comfortably above floor")
        eq(Thresholds.warnGB(high: 3.5), 3.0, "warn holds a 3.0 floor")
        // Must stay strictly below high even when high is small.
        for h in [1.0, 2.0, 3.0, 3.5, 5.5, 12.0, 64.0] {
            check(Thresholds.warnGB(high: h) < h, "warn strictly below high=\(h)")
        }
    }

    // MARK: memState

    static func testMemState() {
        print("memState")
        func s(_ gb: Double) -> MemState { Thresholds.memState(gb: gb, warn: 4.5, high: 5.5) }
        check(s(2.0) == .green,  "below warn → green")
        check(s(4.49) == .green, "just below warn → green")
        check(s(4.5) == .yellow, "at warn → yellow (inclusive)")
        check(s(5.0) == .yellow, "between warn and high → yellow")
        check(s(5.5) == .red,    "at high → red (inclusive)")
        check(s(9.0) == .red,    "above high → red")
    }

    // MARK: median

    static func testMedian() {
        print("median")
        check(Stats.median([]) == nil, "empty → nil")
        eq(Stats.median([5])!, 5.0, "single element")
        eq(Stats.median([3, 1, 2])!, 2.0, "odd count, unsorted")
        eq(Stats.median([1, 2, 3, 4])!, 2.5, "even count averages the middle two")
        check(Stats.median([1, 2], minCount: 3) == nil, "below minCount → nil")
        eq(Stats.median([1, 2, 3], minCount: 3)!, 2.0, "exactly minCount → value")
    }

    // MARK: pressure

    static func testPressure() {
        print("pressure")
        check(SystemHealth.pressure(fromRaw: 4) == .critical, "raw 4 → critical")
        check(SystemHealth.pressure(fromRaw: 2) == .warn,     "raw 2 → warn")
        check(SystemHealth.pressure(fromRaw: 1) == .normal,   "raw 1 → normal")
        // Unknown / unexpected values fail safe to normal (never nag on garbage).
        check(SystemHealth.pressure(fromRaw: 0) == .normal,   "raw 0 → normal")
        check(SystemHealth.pressure(fromRaw: 3) == .normal,   "raw 3 → normal")
        check(SystemHealth.pressure(fromRaw: 99) == .normal,  "raw 99 → normal")
    }

    // MARK: ramSharePercent

    static func testRamSharePercent() {
        print("ramSharePercent")
        let total = 16.0 * 1_073_741_824.0
        check(SystemHealth.ramSharePercent(usedBytes: 8.0 * 1_073_741_824.0, totalBytes: total) == 50,
              "8/16 GB → 50%")
        // Committed memory can exceed installed RAM — must clamp, never show >100.
        check(SystemHealth.ramSharePercent(usedBytes: 19.0 * 1_073_741_824.0, totalBytes: total) == 100,
              "19/16 GB clamps to 100%")
        check(SystemHealth.ramSharePercent(usedBytes: total, totalBytes: total) == 100, "exactly full → 100%")
        // Degenerate inputs → 0 (no divide-by-zero, no negatives, no NaN).
        check(SystemHealth.ramSharePercent(usedBytes: 5.0, totalBytes: 0) == 0, "zero total → 0")
        check(SystemHealth.ramSharePercent(usedBytes: 0, totalBytes: total) == 0, "zero used → 0")
        check(SystemHealth.ramSharePercent(usedBytes: -5.0, totalBytes: total) == 0, "negative used → 0")
        check(SystemHealth.ramSharePercent(usedBytes: .nan, totalBytes: total) == 0, "NaN used → 0")
    }

    // MARK: edgeIsSystemCulprit

    static func testEdgeIsSystemCulprit() {
        print("edgeIsSystemCulprit")
        let floor = 512.0 * 1_048_576.0   // 512 MB
        func culprit(_ p: MemPressure, swap: Double = 0, share: Double = 0.5,
                     minShare: Double = 0.35, swapFloor: Double = floor) -> Bool {
            SystemHealth.edgeIsSystemCulprit(pressure: p, swapGrewBytes: swap, edgeShare: share,
                                             minEdgeShare: minShare, swapGrowthFloor: swapFloor)
        }
        // Below the culprit share → never blamed, even under critical pressure.
        check(culprit(.critical, share: 0.20) == false, "small Edge share → not culprit even if critical")
        check(culprit(.warn, share: 0.34, minShare: 0.35) == false, "just under min share → not culprit")
        // Kernel pressure with a dominant Edge → culprit.
        check(culprit(.critical) == true, "critical + dominant Edge → culprit")
        check(culprit(.warn) == true,     "warn + dominant Edge → culprit")
        check(culprit(.warn, share: 0.35, minShare: 0.35) == true, "share exactly at min → culprit")
        // Normal pressure but actively paging (swap grew past the floor) → culprit.
        check(culprit(.normal, swap: floor) == true, "normal + swap grew ≥ floor → culprit")
        check(culprit(.normal, swap: floor - 1) == false, "normal + swap grew < floor → not culprit")
        check(culprit(.normal, swap: 0) == false, "normal + no swap growth → not culprit")
        // A zero/disabled swap floor must not fire on zero growth.
        check(culprit(.normal, swap: 0, swapFloor: 0) == false, "normal + zero floor → not culprit")
    }
}
