import Foundation
import Security

public enum AppPackageError: Error, Equatable {
    case noApplication
    case unreadableInfo
}

/// An application package: an .ipa, Xcode archive, .app bundle or Android .apk.
public struct AppPackage: Sendable {
    public enum Platform: String, Sendable {
        case iOS, iPadOS, macOS, tvOS, watchOS, visionOS, android = "Android"
    }

    public var platform: Platform
    public var name: String
    public var identifier: String?
    public var version: String?
    public var build: String?
    public var minimumOS: String?
    public var targetOS: String?
    public var devices: [String] = []
    /// PNG or ICNS data of the largest icon the package carries as a plain file.
    public var iconData: Data?
    public var provisioning: ProvisioningProfile?
    public var archiveScheme: String?
    public var archiveDate: Date?
    public var signingIdentity: String?
    public var builtWith: String?
    public var permissions: [String] = []
    public var nativeABIs: [String] = []

    public static func read(url: URL) throws -> AppPackage {
        switch url.pathExtension.lowercased() {
        case "ipa": return try readIPA(url)
        case "xcarchive": return try readXcodeArchive(url)
        case "apk": return try AndroidPackage.read(url)
        default: return try readBundle(url)
        }
    }

    // MARK: - Bundles on disk

    static func readBundle(_ url: URL) throws -> AppPackage {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let isMac = FileManager.default.fileExists(atPath: contents.path)
        let root = isMac ? contents : url
        guard let info = plist(try? Data(contentsOf: root.appendingPathComponent("Info.plist"))) else {
            throw AppPackageError.unreadableInfo
        }
        var package = describe(info: info, fallbackName: url.deletingPathExtension().lastPathComponent)

        if isMac {
            package.platform = .macOS
            if let iconName = info["CFBundleIconFile"] as? String {
                let file = iconName.hasSuffix(".icns") ? iconName : iconName + ".icns"
                package.iconData = try? Data(contentsOf: contents.appendingPathComponent("Resources/\(file)"))
            }
            package.provisioning = (try? Data(contentsOf: contents.appendingPathComponent("embedded.provisionprofile")))
                .flatMap { try? ProvisioningProfile.decode($0) }
        } else {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let sizes = files.map { file in
                (file, (try? url.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            if let best = largestIcon(among: sizes, names: iconNames(info)) {
                package.iconData = try? Data(contentsOf: url.appendingPathComponent(best))
            }
            package.provisioning = (try? Data(contentsOf: url.appendingPathComponent("embedded.mobileprovision")))
                .flatMap { try? ProvisioningProfile.decode($0) }
        }
        return package
    }

    static func readXcodeArchive(_ url: URL) throws -> AppPackage {
        guard let info = plist(try? Data(contentsOf: url.appendingPathComponent("Info.plist"))),
              let properties = info["ApplicationProperties"] as? [String: Any],
              let path = properties["ApplicationPath"] as? String else {
            throw AppPackageError.noApplication
        }
        var package = try readBundle(url.appendingPathComponent("Products").appendingPathComponent(path))
        package.archiveScheme = info["SchemeName"] as? String
        package.archiveDate = info["CreationDate"] as? Date
        package.signingIdentity = properties["SigningIdentity"] as? String
        return package
    }

    // MARK: - IPA

    static func readIPA(_ url: URL) throws -> AppPackage {
        let listing = try ArchiveListing.read(url: url, maxEntries: 100_000, timeLimit: 3)
        let infoPath = listing.entries.map(\.path).first { path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard let infoPath else { throw AppPackageError.noApplication }
        let appPath = String(infoPath.dropLast("Info.plist".count))
        guard let info = plist(try ArchiveListing.data(ofEntry: infoPath, in: url)) else { throw AppPackageError.unreadableInfo }

        let appName = String(appPath.split(separator: "/")[1].dropLast(4))
        var package = describe(info: info, fallbackName: appName)
        let files = listing.entries.compactMap { entry -> (String, Int)? in
            guard entry.path.hasPrefix(appPath), !entry.path.dropFirst(appPath.count).contains("/") else { return nil }
            return (String(entry.path.dropFirst(appPath.count)), Int(entry.size ?? 0))
        }
        if let best = largestIcon(among: files, names: iconNames(info)) {
            package.iconData = try ArchiveListing.data(ofEntry: appPath + best, in: url)
        }
        package.provisioning = try ArchiveListing.data(ofEntry: appPath + "embedded.mobileprovision", in: url)
            .flatMap { try? ProvisioningProfile.decode($0) }
        return package
    }

    // MARK: - Info.plist

    static func describe(info: [String: Any], fallbackName: String) -> AppPackage {
        let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let platform: Platform
        if platforms.contains(where: { $0.hasPrefix("iPhone") }) {
            platform = .iOS
        } else if platforms.contains(where: { $0.hasPrefix("AppleTV") }) {
            platform = .tvOS
        } else if platforms.contains(where: { $0.hasPrefix("Watch") }) {
            platform = .watchOS
        } else if platforms.contains(where: { $0.hasPrefix("XR") }) {
            platform = .visionOS
        } else {
            platform = .macOS
        }
        let families = [1: "iPhone", 2: "iPad", 3: "Apple TV", 4: "Apple Watch", 6: "Mac", 7: "Apple Vision Pro"]
        var package = AppPackage(
            platform: platform,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? fallbackName,
            identifier: info["CFBundleIdentifier"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            minimumOS: info["MinimumOSVersion"] as? String ?? info["LSMinimumSystemVersion"] as? String
        )
        package.devices = (info["UIDeviceFamily"] as? [Int] ?? []).compactMap { families[$0] }
        package.targetOS = info["DTPlatformVersion"] as? String
        if let xcode = info["DTXcode"] as? String, xcode.count >= 3 {
            // "1600" → Xcode 16.0
            let major = Int(xcode.dropLast(2)) ?? 0, minor = Int(String(xcode.dropLast(1).suffix(1))) ?? 0
            package.builtWith = "Xcode \(major).\(minor)"
        }
        return package
    }

    /// Icon base names from CFBundleIcons (iPhone and iPad) and the older keys.
    static func iconNames(_ info: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (info[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            names += primary?["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let file = info["CFBundleIconFile"] as? String { names.append(file) }
        return names.map { $0.hasSuffix(".png") ? String($0.dropLast(4)) : $0 }
    }

    /// The biggest PNG whose name starts with one of `names` — the highest resolution, usually.
    static func largestIcon(among files: [(String, Int)], names: [String]) -> String? {
        files.filter { file, _ in
            file.lowercased().hasSuffix(".png") && names.contains { !$0.isEmpty && file.hasPrefix($0) }
        }.max { $0.1 < $1.1 }?.0
    }

    static func plist(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// A provisioning profile (embedded.mobileprovision / embedded.provisionprofile): a CMS-signed plist.
public struct ProvisioningProfile: Sendable {
    public enum Kind: String, Sendable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case enterprise = "Enterprise (in-house)"
        case appStore = "App Store"
    }

    public struct Entitlement: Sendable, Equatable {
        public var key: String
        public var value: String
    }

    public var name: String
    public var appIDName: String?
    public var teamName: String?
    public var teamIdentifier: String?
    public var uuid: String?
    public var creationDate: Date?
    public var expirationDate: Date?
    public var deviceCount: Int
    public var kind: Kind
    public var entitlements: [Entitlement]

    public func isExpired(at date: Date = Date()) -> Bool {
        expirationDate.map { $0 < date } ?? false
    }

    static func decode(_ data: Data) throws -> ProvisioningProfile {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { throw AppPackageError.unreadableInfo }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        var content: CFData?
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let plist = AppPackage.plist(content as Data?) else {
            throw AppPackageError.unreadableInfo
        }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        return ProvisioningProfile(
            name: plist["Name"] as? String ?? "Provisioning profile",
            appIDName: plist["AppIDName"] as? String,
            teamName: plist["TeamName"] as? String,
            teamIdentifier: (plist["TeamIdentifier"] as? [String])?.first,
            uuid: plist["UUID"] as? String,
            creationDate: plist["CreationDate"] as? Date,
            expirationDate: plist["ExpirationDate"] as? Date,
            deviceCount: devices.count,
            kind: kind(entitlements: entitlements, hasDevices: !devices.isEmpty,
                       provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false),
            entitlements: entitlements.sorted { $0.key < $1.key }.map { Entitlement(key: $0.key, value: describe($0.value)) }
        )
    }

    /// Development profiles allow debugging; ad hoc ones list devices; enterprise ones cover
    /// all devices; the rest are for App Store distribution.
    static func kind(entitlements: [String: Any], hasDevices: Bool, provisionsAllDevices: Bool) -> Kind {
        if entitlements["get-task-allow"] as? Bool == true { return .development }
        if provisionsAllDevices { return .enterprise }
        if hasDevices { return .adHoc }
        return .appStore
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let bool as Bool: bool ? "Yes" : "No"
        case let array as [Any]: array.map(describe).joined(separator: ", ")
        default: "\(value)"
        }
    }
}

/// Placeholder until the Android reader lands.
enum AndroidPackage {
    static func read(_ url: URL) throws -> AppPackage {
        throw AppPackageError.noApplication
    }
}
