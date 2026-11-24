import UIKit

@MainActor
enum AppIcon {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for entry: TargetInventoryEntry, scale: CGFloat) -> UIImage? {
        guard let bundleID = entry.iconBundleID ?? entry.bundleID else { return nil }
        let key = "\(bundleID):\(entry.iconBundlePath ?? ""):\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image = bundleIcon(at: entry.iconBundlePath, matching: bundleID)
            ?? FLInstalledApplicationIcon(bundleID, scale)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func bundleIcon(at path: String?, matching bundleID: String) -> UIImage? {
        guard let path, let bundle = Bundle(path: path), bundle.bundleIdentifier == bundleID else { return nil }
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
            ?? bundle.object(forInfoDictionaryKey: "CFBundleIconFiles") as? [String] ?? []
        let iconName = primary?["CFBundleIconName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        for name in files.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) { return image }
        }
        return iconName.flatMap { UIImage(named: $0, in: bundle, compatibleWith: nil) }
    }
}
