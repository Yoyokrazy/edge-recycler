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
