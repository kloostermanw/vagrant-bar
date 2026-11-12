import XCTest
@testable import VagrantCore

final class GitHubReleaseTests: XCTestCase {
    private func decode(_ json: String) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecodesTagNotesAndDmgAsset() throws {
        let release = try decode("""
        {
          "tag_name": "v1.2.0",
          "name": "Release 1.2.0",
          "body": "Bug fixes.",
          "html_url": "https://github.com/kloostermanw/vagrant-bar/releases/tag/v1.2.0",
          "assets": [
            {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
            {"name": "VagrantBar.v1.2.0.dmg", "browser_download_url": "https://example.com/VagrantBar.v1.2.0.dmg"}
          ]
        }
        """)
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.name, "Release 1.2.0")
        XCTAssertEqual(release.body, "Bug fixes.")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/kloostermanw/vagrant-bar/releases/tag/v1.2.0"))
        XCTAssertEqual(release.version, AppVersion("1.2.0"))
        XCTAssertEqual(release.dmgAsset?.name, "VagrantBar.v1.2.0.dmg")
        XCTAssertEqual(release.dmgAsset?.downloadURL, URL(string: "https://example.com/VagrantBar.v1.2.0.dmg"))
    }

    func testDmgAssetNilWhenNoDmgPresentAndNullFieldsDefault() throws {
        let release = try decode("""
        {
          "tag_name": "1.3.0",
          "name": null,
          "body": null,
          "html_url": "https://github.com/kloostermanw/vagrant-bar/releases/tag/1.3.0",
          "assets": []
        }
        """)
        XCTAssertNil(release.dmgAsset)
        XCTAssertEqual(release.name, "1.3.0")
        XCTAssertEqual(release.body, "")
    }
}
