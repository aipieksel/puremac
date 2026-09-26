import Foundation
let home = FileManager.default.homeDirectoryForCurrentUser.path
// Spy on the expensive sizing boundary while exercising real bundle loading.
enum FileSizeCalculator {
    static var calls = 0
    static func size(of url: URL) -> Int64? { calls += 1; return 1234 }
}
@main struct AppDiscoveryChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PureMac-Discovery-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        func bundle(_ name: String, id: String?) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            let contents = url.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            var info = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
            if let id { info["CFBundleIdentifier"] = id }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let protected = try bundle("Xcode Fixture", id: "com.apple.dt.Xcode")
        precondition(AppInfoFetcher.shared.fetchApp(at: protected) == nil)
        precondition(FileSizeCalculator.calls == 0, "Protected bundle was sized")
        let ordinary = try bundle("Ordinary Fixture", id: "test.puremac.fixture")
        let app = AppInfoFetcher.shared.fetchApp(at: ordinary)!
        precondition(app.size == 1234 && app.bundleIdentifier == "test.puremac.fixture")
        precondition(FileSizeCalculator.calls == 1)
        let fallback = try bundle("No Identifier", id: nil)
        precondition(AppInfoFetcher.shared.fetchApp(at: fallback)?.bundleIdentifier == "No Identifier")
        precondition(FileSizeCalculator.calls == 2)
        print("PASS: protected apps skipped before sizing; accepted apps and identifier fallback preserved")
    }
}
