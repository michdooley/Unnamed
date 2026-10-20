/// Counts of how often things are drawn, which the debug build's perf runs
/// (`-perf`) log for each scenario. Does nothing in release builds.
enum Perf {
    #if DEBUG
    static var counts: [String: Int] = [:]
    #endif

    static func count(_ name: String) {
        #if DEBUG
        counts[name, default: 0] += 1
        #endif
    }
}
