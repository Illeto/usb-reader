import Foundation

// ANSI styling, enabled only on interactive terminals (and honoring NO_COLOR).
enum Style {
    static let enabled = isatty(1) != 0
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    private static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { wrap("1", s) }
    static func dim(_ s: String) -> String { wrap("2", s) }
    static func green(_ s: String) -> String { wrap("32", s) }
    static func yellow(_ s: String) -> String { wrap("33", s) }
    static func cyan(_ s: String) -> String { wrap("36", s) }
}
