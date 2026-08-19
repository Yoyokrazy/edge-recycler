// ============================================================================
// EdgeRecyclerCore
// ----------------------------------------------------------------------------
// Pure, AppKit-free logic extracted from the app so it can be unit-tested
// without a running NSApplication, UserDefaults, or the process/kernel APIs.
// Everything here is a deterministic function of its inputs. The app (main.swift)
// calls these; the test runner (Tests/CoreTests.swift) exercises them directly.
// Compiled into the same single binary — no external dependencies.
// ============================================================================

/// Memory health bands shown as the colored menu-bar dot.
enum MemState { case green, yellow, red }

/// Restart-threshold + warn-level math.
enum Thresholds {
    /// The GB level at which a sustained stay triggers a restart prompt.
    ///
    /// - `manual` mode uses the user's fixed value.
    /// - `auto` mode uses `baseline + margin`, clamped to `[floor, ceil]`.
    /// - Until a baseline exists, a safe default is used.
    ///
    /// The result is always finite and clamped to `[1, 64]` GB regardless of the
    /// (user-editable) inputs, so a garbage default can never produce a nonsense
    /// or unsafe threshold. Non-finite / non-positive raw values fall back to 5.5.
    static func resolvedHighGB(mode: String,
                               manualHighGB: Double,
                               baseline: Double?,
                               autoMarginGB: Double,
                               autoFloorGB: Double,
                               autoCeilGB: Double,
                               defaultHighGB: Double) -> Double {
        let raw: Double
        if mode == "manual" {
            raw = manualHighGB
        } else if let b = baseline {
            raw = min(max(b + autoMarginGB, autoFloorGB), autoCeilGB)
        } else {
            raw = defaultHighGB
        }
        guard raw.isFinite, raw > 0 else { return 5.5 }   // bulletproof fallback
        return min(max(raw, 1.0), 64.0)
    }

    /// Yellow "heavy" level, guaranteed strictly below `high` so the bands never
    /// overlap or invert (even for a small `high`).
    static func warnGB(high: Double) -> Double {
        min(max(high - 1.0, 3.0), high - 0.1)
    }

    /// Classify a GB reading against the warn/high bands.
    static func memState(gb: Double, warn: Double, high: Double) -> MemState {
        gb >= high ? .red : (gb >= warn ? .yellow : .green)
    }
}

/// macOS memory-pressure level, mirroring the kernel's
/// `kern.memorystatus_vm_pressure_level` (raw 1 = normal, 2 = warn, 4 =
/// critical). This is the signal that actually precedes the swap-thrash and UI
/// hangs this app exists to prevent — the kernel raises it as free memory runs
/// low, *before* an absolute GB number means anything on its own.
enum MemPressure { case normal, warn, critical }

/// System-wide memory-health logic. Pure and unit-tested: the app feeds in the
/// raw kernel readings (see `SystemSampler`) and these functions decide what to
/// show and when Edge is the thing worth restarting.
enum SystemHealth {
    /// Map the kernel's raw `vm_pressure_level` to a `MemPressure`. Unknown or
    /// unexpected values are treated as `normal` (fail safe: never nag on a
    /// value we don't understand).
    static func pressure(fromRaw raw: Int32) -> MemPressure {
        switch raw {
        case 4: return .critical
        case 2: return .warn
        default: return .normal   // 1 (normal) or anything unexpected
        }
    }

    /// Edge's share of installed RAM as a whole-number percent, **clamped to
    /// `[0, 100]`**. Summed `phys_footprint` counts compressed and swapped-out
    /// pages, so it can exceed installed RAM; without this clamp the UI could
    /// show a nonsensical ">100% of your memory".
    static func ramSharePercent(usedBytes: Double, totalBytes: Double) -> Int {
        guard totalBytes > 0, usedBytes > 0 else { return 0 }
        let pct = usedBytes / totalBytes * 100.0
        guard pct.isFinite else { return 0 }
        return Int(min(max(pct, 0.0), 100.0).rounded())
    }

    /// Should we recommend recycling Edge on *system* grounds — i.e. the Mac is
    /// actually short on memory right now — rather than purely because Edge's
    /// absolute footprint crossed a GB threshold?
    ///
    /// True only when the machine is under real memory duress **and** Edge is a
    /// large enough share of RAM to plausibly be the cause, so we never nag you
    /// to restart Edge when some *other* app is the memory hog:
    ///
    /// - `critical` kernel pressure → duress.
    /// - `warn` kernel pressure → duress.
    /// - otherwise, swap that grew by at least `swapGrowthFloor` bytes over the
    ///   observation window → the machine is actively paging to disk even if the
    ///   pressure level hasn't flipped yet.
    ///
    /// - Parameters:
    ///   - pressure:        kernel memory-pressure level
    ///   - swapGrewBytes:   increase in swap-used over the sustained window
    ///   - edgeShare:       Edge footprint ÷ installed RAM, in `[0, 1]`
    ///   - minEdgeShare:    Edge must be at least this share to be blamed
    ///   - swapGrowthFloor: swap growth (bytes) counting as "actively paging"
    static func edgeIsSystemCulprit(pressure: MemPressure,
                                    swapGrewBytes: Double,
                                    edgeShare: Double,
                                    minEdgeShare: Double,
                                    swapGrowthFloor: Double) -> Bool {
        guard edgeShare >= minEdgeShare else { return false }
        switch pressure {
        case .critical, .warn:
            return true
        case .normal:
            return swapGrewBytes >= swapGrowthFloor && swapGrowthFloor > 0
        }
    }
}

/// Small statistics helpers over sampled memory readings.
enum Stats {
    /// Median of `values`, or `nil` if fewer than `minCount` (at least 1) are
    /// present — mirroring "don't trust a baseline until calibrated". For an even
    /// count it averages the two middle values.
    static func median(_ values: [Double], minCount: Int = 1) -> Double? {
        let need = max(minCount, 1)          // never index into an empty array
        guard values.count >= need else { return nil }
        let v = values.sorted()
        let m = v.count / 2
        return v.count % 2 == 0 ? (v[m - 1] + v[m]) / 2 : v[m]
    }
}
