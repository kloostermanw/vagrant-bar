import Foundation
import os

/// Checks GitHub for a newer VagrantBar release and downloads its `.dmg`.
/// UI-agnostic: the app observes `state` through `onStateChange`.
@MainActor
public final class UpdateService {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading
        case downloaded(URL)
        case failed(message: String)
    }

    /// Downloads a URL to a temporary file and returns that file's location.
    public typealias Downloader = @Sendable (URL) async throws -> URL

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((State) -> Void)?

    public let currentVersion: AppVersion
    /// Minimum time between background checks.
    public let throttle: TimeInterval

    private let checker: ReleaseChecking
    private let defaults: UserDefaults
    private let now: () -> Date
    private let downloadsDirectory: () throws -> URL
    private let downloader: Downloader
    private let reveal: (URL) -> Void

    private let lastCheckKey = "UpdateService.lastCheck"
    private let skippedTagKey = "UpdateService.skippedTag"

    private static let logger = Logger(subsystem: "dev.local.vagrantbar", category: "updates")

    public init(
        checker: ReleaseChecking = GitHubReleaseService(),
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion = .current,
        throttle: TimeInterval = 2 * 60 * 60,
        now: @escaping () -> Date = Date.init,
        downloadsDirectory: @escaping () throws -> URL = UpdateService.userDownloadsDirectory,
        downloader: @escaping Downloader = { try await UpdateService.urlSessionDownload($0) },
        reveal: @escaping (URL) -> Void = { _ in }
    ) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.throttle = throttle
        self.now = now
        self.downloadsDirectory = downloadsDirectory
        self.downloader = downloader
        self.reveal = reveal
    }

    /// Background checks (`userInitiated: false`) are throttled, never replace an
    /// update that is already being shown, stay quiet about a skipped tag, and only
    /// log failures. Manual checks always hit the network and report every outcome.
    public func checkForUpdates(userInitiated: Bool) async {
        if !userInitiated {
            switch state {
            case .available, .downloading, .downloaded:
                return
            default:
                break
            }
            if let last = defaults.object(forKey: lastCheckKey) as? Date,
               now().timeIntervalSince(last) < throttle {
                return
            }
        }

        state = .checking
        do {
            let release = try await checker.latestRelease()
            defaults.set(now(), forKey: lastCheckKey)
            guard release.version.isNewer(than: currentVersion) else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            if !userInitiated, defaults.string(forKey: skippedTagKey) == release.tagName {
                state = .idle
                return
            }
            state = .available(release)
        } catch {
            if userInitiated {
                state = .failed(message: error.localizedDescription)
            } else {
                Self.logger.error("Background update check failed: \(error.localizedDescription, privacy: .public)")
                state = .idle
            }
        }
    }

    /// Downloads the release's `.dmg` into the Downloads folder and reveals it.
    public func download(_ release: GitHubRelease) async {
        guard let asset = release.dmgAsset else {
            state = .failed(message: "The latest release has no .dmg download.")
            return
        }
        state = .downloading
        do {
            let tempURL = try await downloader(asset.downloadURL)
            let dest = Self.uniqueDestination(in: try downloadsDirectory(), fileName: asset.name)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            state = .downloaded(dest)
            reveal(dest)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Silences background checks for this release's tag.
    public func skip(_ release: GitHubRelease) {
        defaults.set(release.tagName, forKey: skippedTagKey)
        state = .idle
    }

    public func dismiss() {
        if case .downloading = state { return }
        state = .idle
    }

    // MARK: - Defaults

    public nonisolated static func userDownloadsDirectory() throws -> URL {
        try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    public nonisolated static func urlSessionDownload(_ url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw UpdateError.badResponse(status)
        }
        return tempURL
    }

    /// Avoids clobbering an existing file by suffixing " (1)", " (2)", etc.
    private static func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
