import AppKit
import Foundation
import Testing
@testable import QuickPeekFormats

func appFixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/apps"))
}

@Suite("AppPackage: Apple")
struct ApplePackageTests {
    @Test("IPA and Xcode archive: identity, versions and platform", arguments: ["Demo.ipa", "Demo.xcarchive"])
    func identity(file: String) throws {
        let package = try AppPackage.read(url: appFixture(file))
        #expect(package.platform == .iOS)
        #expect(package.name == "Demo")
        #expect(package.identifier == "com.example.demo")
        #expect(package.version == "2.3")
        #expect(package.build == "45")
        #expect(package.minimumOS == "16.0")
        #expect(package.devices == ["iPhone", "iPad"])
    }

    @Test("The largest icon file is chosen and decodes", arguments: ["Demo.ipa", "Demo.xcarchive"])
    func icon(file: String) throws {
        let package = try AppPackage.read(url: appFixture(file))
        let data = try #require(package.iconData)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 180)
    }

    @Test("Embedded provisioning profile")
    func provisioning() throws {
        let profile = try #require(try AppPackage.read(url: appFixture("Demo.ipa")).provisioning)
        #expect(profile.name == "Demo Ad Hoc")
        #expect(profile.teamName == "Example Team")
        #expect(profile.teamIdentifier == "ABCDE12345")
        #expect(profile.kind == .adHoc)
        #expect(profile.deviceCount == 3)
        #expect(profile.expirationDate == ISO8601DateFormatter().date(from: "2027-01-02T15:30:00Z"))
        #expect(profile.isExpired(at: ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")!))
        #expect(!profile.isExpired(at: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!))
        #expect(profile.entitlements.contains { $0.key == "aps-environment" && $0.value == "production" })
    }

    @Test("Profile kinds follow Apple's rules", arguments: [
        (["get-task-allow": true], false, false, ProvisioningProfile.Kind.development),
        (["get-task-allow": false], true, false, .adHoc),
        (["get-task-allow": false], false, true, .enterprise),
        (["get-task-allow": false], false, false, .appStore),
    ])
    func kinds(entitlements: [String: Bool], hasDevices: Bool, allDevices: Bool, kind: ProvisioningProfile.Kind) {
        #expect(ProvisioningProfile.kind(entitlements: entitlements, hasDevices: hasDevices, provisionsAllDevices: allDevices) == kind)
    }

    @Test("Xcode archive details")
    func archive() throws {
        let package = try AppPackage.read(url: appFixture("Demo.xcarchive"))
        #expect(package.archiveScheme == "Demo-Release")
        #expect(package.signingIdentity == "Apple Distribution: Example Team (ABCDE12345)")
    }

    @Test("A macOS app bundle")
    func macApp() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let package = try AppPackage.read(url: url)
        #expect(package.platform == .macOS)
        #expect(package.identifier == "com.apple.calculator")
        #expect(package.minimumOS != nil)
    }
}
