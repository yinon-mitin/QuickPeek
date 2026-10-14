import Foundation
import QuickPeekFormats
import UniformTypeIdentifiers

/// Details of app packages: .ipa, .apk and Xcode archives (macOS .app bundles go to AppInfo).
enum PackageInfo: InfoReader {
    static let extensions: Set<String> = ["ipa", "apk", "xcarchive"]

    static func canRead(_ type: UTType, url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL, format: InfoFormat) throws -> (sections: [InfoSection], summary: String?) {
        let package = try AppPackage.read(url: url)
        var sections = [InfoSection("Application", symbol: package.platform == .android ? "apps.iphone" : "app", items: items(package, format: format))]
        if let profile = package.provisioning {
            sections.append(InfoSection("Provisioning", symbol: "checkmark.seal", items: profileItems(profile, format: format)))
        }
        if package.archiveScheme != nil || package.signingIdentity != nil {
            var archive: [InfoItem] = []
            if let scheme = package.archiveScheme { archive.append(InfoItem("Scheme", scheme)) }
            if let date = package.archiveDate { archive.append(InfoItem("Archived", format.date(date))) }
            if let identity = package.signingIdentity { archive.append(InfoItem("Signing identity", identity)) }
            sections.append(InfoSection("Xcode archive", symbol: "archivebox", items: archive))
        }
        return (sections, summary(package))
    }

    static func summary(_ package: AppPackage) -> String {
        var version = package.version ?? ""
        if let build = package.build, build != version { version += version.isEmpty ? build : " (\(build))" }
        let name = version.isEmpty ? package.name : "\(package.name) \(version)"
        let minimum = package.minimumOS.map { minimum in
            package.platform == .android ? minimum.components(separatedBy: " (").first.map { $0 + "+" } ?? minimum
                                         : "\(package.platform.rawValue) \(minimum)+"
        }
        return [name, minimum].compactMap { $0 }.joined(separator: " · ")
    }

    static func items(_ package: AppPackage, format: InfoFormat) -> [InfoItem] {
        var items = [InfoItem("Name", package.name), InfoItem("Platform", package.platform.rawValue)]
        if let identifier = package.identifier {
            items.append(InfoItem(package.platform == .android ? "Package" : "Bundle ID", identifier))
        }
        if let version = package.version { items.append(InfoItem("Version", version)) }
        if let build = package.build { items.append(InfoItem(package.platform == .android ? "Version code" : "Build", build)) }
        // Android versions already read "Android 8.0 (API 26)"; Apple ones are bare numbers.
        let platformPrefix = package.platform == .android ? "" : "\(package.platform.rawValue) "
        if let minimum = package.minimumOS { items.append(InfoItem("Minimum OS", platformPrefix + minimum)) }
        if let target = package.targetOS { items.append(InfoItem(package.platform == .android ? "Target SDK" : "SDK", platformPrefix + target)) }
        if !package.devices.isEmpty { items.append(InfoItem("Devices", package.devices.joined(separator: ", "))) }
        if let builtWith = package.builtWith { items.append(InfoItem("Built with", builtWith)) }
        if !package.nativeABIs.isEmpty { items.append(InfoItem("Native code", package.nativeABIs.joined(separator: ", "))) }
        for (index, permission) in package.permissions.enumerated() {
            items.append(InfoItem(index == 0 ? "Permissions" : "", permission.replacingOccurrences(of: "android.permission.", with: "")))
        }
        return items
    }

    static func profileItems(_ profile: ProvisioningProfile, format: InfoFormat) -> [InfoItem] {
        var items = [InfoItem("Profile", profile.name), InfoItem("Type", profile.kind.rawValue)]
        if let team = profile.teamName {
            items.append(InfoItem("Team", profile.teamIdentifier.map { "\(team) (\($0))" } ?? team))
        }
        if let expires = profile.expirationDate {
            items.append(InfoItem("Expires", format.date(expires) + (profile.isExpired() ? " — expired" : "")))
        }
        if profile.deviceCount > 0 { items.append(InfoItem("Devices", format.number(profile.deviceCount))) }
        for (index, entitlement) in profile.entitlements.enumerated() {
            items.append(InfoItem(index == 0 ? "Entitlements" : "", "\(entitlement.key) = \(entitlement.value)"))
        }
        return items
    }
}
