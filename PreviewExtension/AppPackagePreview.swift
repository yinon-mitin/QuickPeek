import AppKit
import QuickPeekFormats
import QuickPeekInfo
import SwiftUI

/// Preview of an .ipa, .apk or Xcode archive: icon, name and version, then the details
/// (identity, minimum OS, permissions, provisioning profile, archive).
struct AppPackagePreview: View {
    let package: AppPackage
    let info: FileInfo

    static let extensions: Set<String> = ["ipa", "apk", "xcarchive"]

    /// The summary without the name, which is the title already: "Version 2.3 (45) · iOS 16.0+".
    private var subtitle: String {
        let rest = info.summary.hasPrefix(package.name) ? String(info.summary.dropFirst(package.name.count)) : info.summary
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.first?.isNumber == true ? "Version " + trimmed : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "· "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AppIconView(package: package, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(subtitle).foregroundStyle(.secondary)
                    if let identifier = package.identifier {
                        Text(identifier).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                // General (name, size, dates) is shown by Finder already; the rest is the package.
                InfoSectionsView(sections: info.sections.filter { $0.title != "General" })
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The package's own icon; iOS icons get the system's rounded-square mask.
struct AppIconView: View {
    let package: AppPackage
    let size: CGFloat

    var body: some View {
        if let data = package.iconData, let image = NSImage(data: data) {
            let icon = Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            if package.platform == .android || package.platform == .macOS {
                icon.frame(width: size, height: size)
            } else {
                icon.frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            }
        } else {
            Image(systemName: package.platform == .android ? "apps.iphone" : "app.dashed")
                .font(.system(size: size * 0.7, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
