import Foundation

// The git short hash the "Stamp build hash" build phase writes into
// Info.plist; "dev" outside a stamped bundle (previews, tests). Joins report
// it so version skew across a meeting's participants shows up in HQ's logs.
enum HQBuildInfo {
    static let hash: String =
        (Bundle.main.object(forInfoDictionaryKey: "HQBuildHash") as? String) ?? "dev"
}
