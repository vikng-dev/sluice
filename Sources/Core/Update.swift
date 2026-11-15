import Foundation
import Security

/// Why an update was not made.
public struct UpdateError: Error, CustomStringConvertible {
    public let description: String
}

/// A release of Sluice newer than the one running, and the archive of its app.
public struct Release: Sendable, Equatable {
    public let version: String
    let archive: URL
}

/// Sluice updates itself from its releases on GitHub (docs/wire.md). What it downloads replaces the app
/// only when macOS finds it signed by the developer that signed the one running and notarized by
/// Apple: that check, and none of Sluice's own, is what tells a real update.
public enum Update {
    static let latest = URL(string: "https://api.github.com/repos/vikng-dev/sluice/releases/latest")!

    /// Whether `version` comes after `other`, number by number: 1.10.0 is after 1.9.2.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let numbers = [version, other].map { $0.split(separator: ".").map { Int($0) ?? 0 } }
        for index in 0..<max(numbers[0].count, numbers[1].count) {
            let (new, old) = (index < numbers[0].count ? numbers[0][index] : 0, index < numbers[1].count ? numbers[1][index] : 0)
            if new != old { return new > old }
        }
        return false
    }

    /// The release in `answer`, GitHub's account of the latest one, when it is newer than `running`.
    static func release(in answer: Data, newerThan running: String) throws -> Release? {
        struct Latest: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let latest = try JSONDecoder().decode(Latest.self, from: answer)
        let version = String(latest.tag_name.drop { $0 == "v" })
        guard isNewer(version, than: running) else { return nil }
        guard let archive = latest.assets.first(where: { $0.name.hasSuffix("-macos.zip") }) else { throw UpdateError(description: "release \(version) has no app to download") }
        return Release(version: version, archive: archive.browser_download_url)
    }

    /// The latest release, when it is newer than this one.
    public static func newer() async throws -> Release? {
        let (answer, response) = try await URLSession.shared.data(from: latest)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else { throw UpdateError(description: "GitHub did not say what the latest release is") }
        return try release(in: answer, newerThan: Sluice.version)
    }

    /// The team that signed the app at `app`; nil for one that is not signed by a developer, as a build
    /// made here is. Such a copy cannot tell a real update, and does not update itself.
    public static func team(of app: URL) -> String? {
        var code: SecStaticCode?
        var facts: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &facts) == errSecSuccess else { return nil }
        return (facts as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Throws unless macOS finds the app at `app` whole, signed with `team`'s Developer ID and notarized.
    static func verify(_ app: URL, signedBy team: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        // Apple's own form for "a Developer ID of this team" (TN3127), and its notarization.
        let wanted = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and notarized"
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        if status == errSecSuccess { status = SecRequirementCreateWithString(wanted as CFString, [], &requirement) }
        if status == errSecSuccess, let code {
            status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement)
        }
        guard status == errSecSuccess else {
            throw UpdateError(description: "the download is not a Sluice signed by its developer and notarized by Apple (\(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")), so it was not installed")
        }
    }

    /// Downloads `release` and puts its app in place of the one at `app`, which the running copy then
    /// hands over to. Nothing is replaced unless the download is that release, verified.
    public static func install(_ release: Release, over app: URL, signedBy team: String) async throws {
        let files = FileManager.default
        // On the app's own volume, so that it is replaced in one move.
        let room = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: room) }
        let (downloaded, response) = try await URLSession.shared.download(from: release.archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(description: "release \(release.version) could not be downloaded") }
        let archive = room.appending(path: "Sluice.zip")
        try files.moveItem(at: downloaded, to: archive)
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, room.path]
        try unpack.run()
        unpack.waitUntilExit()
        let new = room.appending(path: app.lastPathComponent)
        guard unpack.terminationStatus == 0, let bundle = Bundle(url: new) else { throw UpdateError(description: "release \(release.version) could not be unpacked") }
        try verify(new, signedBy: team)
        guard bundle.bundleIdentifier == Sluice.id, bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError(description: "the download is not Sluice \(release.version), so it was not installed")
        }
        _ = try files.replaceItemAt(app, withItemAt: new)
    }
}
