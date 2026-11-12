import XCTest
@testable import VagrantCore

private struct StubChecker: ReleaseChecking {
    let result: Result<GitHubRelease, Error>
    func latestRelease() async throws -> GitHubRelease { try result.get() }
}

private struct ExplodingChecker: ReleaseChecking {
    func latestRelease() async throws -> GitHubRelease {
        XCTFail("checker should not be called")
        throw UpdateError.badResponse(-1)
    }
}

/// Returns a different result on each successive call, so a test can tell whether a
/// second `checkForUpdates` actually reached the network call or was short-circuited.
private actor SequencedChecker: ReleaseChecking {
    private var calls = 0
    private let results: [Result<GitHubRelease, Error>]

    init(_ results: [Result<GitHubRelease, Error>]) { self.results = results }

    func latestRelease() async throws -> GitHubRelease {
        defer { calls += 1 }
        return try results[min(calls, results.count - 1)].get()
    }
}

private func makeRelease(tag: String, assets: String? = nil) -> GitHubRelease {
    let assets = assets ?? #"[{"name": "VagrantBar.\#(tag).dmg", "browser_download_url": "https://example.com/VagrantBar.\#(tag).dmg"}]"#
    let json = """
    {"tag_name": "\(tag)", "name": "\(tag)", "body": "",
     "html_url": "https://github.com/kloostermanw/vagrant-bar/releases/tag/\(tag)",
     "assets": \(assets)}
    """
    return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "UpdateServiceTests-\(UUID().uuidString)")!
}

@MainActor
final class UpdateServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Checking

    func testReportsAvailableWhenReleaseNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.1.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: true)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.1.0")))
    }

    func testReportsUpToDateWhenNotNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.0.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: true)
        XCTAssertEqual(service.state, .upToDate)
    }

    func testBackgroundCheckStaysIdleWhenNotNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.0.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .idle)
    }

    func testBackgroundCheckDoesNotDisturbAvailableState() async {
        let now = Date(timeIntervalSince1970: 10_000)
        // The second result (not newer) would flip state to .idle if the background check
        // ran; throttle 0 makes sure the throttle isn't what blocks it.
        let service = UpdateService(
            checker: SequencedChecker([.success(makeRelease(tag: "v1.1.0")), .success(makeRelease(tag: "v1.0.0"))]),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0"),
            throttle: 0,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: true)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.1.0")))

        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.1.0")))
    }

    func testBackgroundCheckThrottled() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        defaults.set(now.addingTimeInterval(-60), forKey: "UpdateService.lastCheck")
        let service = UpdateService(
            checker: ExplodingChecker(),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 7200,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .idle)
    }

    func testBackgroundCheckRunsOnceThrottleElapsed() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        defaults.set(now.addingTimeInterval(-7201), forKey: "UpdateService.lastCheck")
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.1.0"))),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 7200,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.1.0")))
        XCTAssertEqual(defaults.object(forKey: "UpdateService.lastCheck") as? Date, now)
    }

    func testUserInitiatedIgnoresThrottle() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        defaults.set(now.addingTimeInterval(-60), forKey: "UpdateService.lastCheck")
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v2.0.0"))),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 7200,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: true)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v2.0.0")))
    }

    func testSkippedVersionSuppressedInBackgroundButShownWhenManual() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.1.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        service.skip(makeRelease(tag: "v1.1.0"))
        XCTAssertEqual(service.state, .idle)

        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .idle)

        await service.checkForUpdates(userInitiated: true)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.1.0")))
    }

    func testSkipOnlySilencesThatTag() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.2.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        service.skip(makeRelease(tag: "v1.1.0"))
        await service.checkForUpdates(userInitiated: false)
        XCTAssertEqual(service.state, .available(makeRelease(tag: "v1.2.0")))
    }

    func testUserInitiatedFailureSurfacesButBackgroundStaysIdle() async {
        let failing = UpdateService(
            checker: StubChecker(result: .failure(UpdateError.badResponse(500))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await failing.checkForUpdates(userInitiated: true)
        XCTAssertEqual(failing.state, .failed(message: UpdateError.badResponse(500).localizedDescription))

        let silent = UpdateService(
            checker: StubChecker(result: .failure(UpdateError.badResponse(500))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await silent.checkForUpdates(userInitiated: false)
        XCTAssertEqual(silent.state, .idle)
    }

    func testOnStateChangeReportsEachTransition() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(makeRelease(tag: "v1.0.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        var seen: [UpdateService.State] = []
        service.onStateChange = { seen.append($0) }
        await service.checkForUpdates(userInitiated: true)
        service.dismiss()
        XCTAssertEqual(seen, [.checking, .upToDate, .idle])
    }

    // MARK: - Downloading

    private func downloadingService(
        downloader: @escaping UpdateService.Downloader,
        revealed: @escaping (URL) -> Void = { _ in }
    ) -> UpdateService {
        UpdateService(
            checker: ExplodingChecker(),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0"),
            downloadsDirectory: { [tempDir] in tempDir! },
            downloader: downloader,
            reveal: revealed
        )
    }

    /// Stands in for URLSession: writes `contents` to a fresh temp file and returns it.
    private func fakeDownloader(_ contents: String = "dmg") -> UpdateService.Downloader {
        { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(contents.utf8).write(to: file)
            return file
        }
    }

    func testDownloadMovesDmgIntoDownloadsAndRevealsIt() async throws {
        var revealed: [URL] = []
        let service = downloadingService(downloader: fakeDownloader(), revealed: { revealed.append($0) })

        await service.download(makeRelease(tag: "v1.1.0"))

        let expected = tempDir.appendingPathComponent("VagrantBar.v1.1.0.dmg")
        XCTAssertEqual(service.state, .downloaded(expected))
        XCTAssertEqual(try String(contentsOf: expected), "dmg")
        XCTAssertEqual(revealed, [expected])
    }

    func testDownloadDoesNotOverwriteExistingFile() async throws {
        try Data("old".utf8).write(to: tempDir.appendingPathComponent("VagrantBar.v1.1.0.dmg"))
        try Data("old".utf8).write(to: tempDir.appendingPathComponent("VagrantBar.v1.1.0 (1).dmg"))
        let service = downloadingService(downloader: fakeDownloader("new"))

        await service.download(makeRelease(tag: "v1.1.0"))

        let expected = tempDir.appendingPathComponent("VagrantBar.v1.1.0 (2).dmg")
        XCTAssertEqual(service.state, .downloaded(expected))
        XCTAssertEqual(try String(contentsOf: expected), "new")
        XCTAssertEqual(try String(contentsOf: tempDir.appendingPathComponent("VagrantBar.v1.1.0.dmg")), "old")
    }

    func testDownloadFailsWhenReleaseHasNoDmg() async {
        let service = downloadingService(downloader: { _ in
            XCTFail("downloader should not be called")
            throw UpdateError.badResponse(-1)
        })
        await service.download(makeRelease(tag: "v1.1.0", assets: "[]"))
        XCTAssertEqual(service.state, .failed(message: "The latest release has no .dmg download."))
    }

    func testDownloadErrorSurfaces() async {
        var revealed: [URL] = []
        let service = downloadingService(
            downloader: { _ in throw UpdateError.badResponse(404) },
            revealed: { revealed.append($0) }
        )
        await service.download(makeRelease(tag: "v1.1.0"))
        XCTAssertEqual(service.state, .failed(message: UpdateError.badResponse(404).localizedDescription))
        XCTAssertEqual(revealed, [])
    }

    // MARK: - GitHub service

    func testGitHubServiceTargetsVagrantBarRepo() {
        XCTAssertEqual(
            GitHubReleaseService.latestReleaseURL,
            URL(string: "https://api.github.com/repos/kloostermanw/vagrant-bar/releases/latest")
        )
    }
}
