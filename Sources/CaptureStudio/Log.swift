import os

/// Unified logging. Inspect with:
///   log stream --predicate 'subsystem == "dev.wadjakorn.capture-studio"' --level debug
///   log show --last 10m --predicate 'subsystem == "dev.wadjakorn.capture-studio"'
enum Log {
    private static let subsystem = "dev.wadjakorn.capture-studio"

    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let studio = Logger(subsystem: subsystem, category: "studio")
}
