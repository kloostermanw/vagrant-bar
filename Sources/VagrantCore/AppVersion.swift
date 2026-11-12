import Foundation

/// A dot-separated numeric version, compared component by component.
/// Tolerant of a leading `v`/`V` and of a missing trailing component
/// (`"1.2"` equals `"1.2.0"`). Non-numeric components parse as `0`.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }
        components = trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func component(at index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = lhs.component(at: i)
            let r = rhs.component(at: i)
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func isNewer(than other: AppVersion) -> Bool { self > other }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// The running app's version, from `CFBundleShortVersionString`.
    public static var current: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
