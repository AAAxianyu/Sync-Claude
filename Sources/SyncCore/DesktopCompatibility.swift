import Foundation

/// Installed Desktop builds are allowed by default. Operations validate the data they use.
public enum DesktopCompatibility {
    public static func supports(_ version: String) -> Bool {
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "未安装"
    }
}
