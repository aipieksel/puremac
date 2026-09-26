import Foundation

@main struct NormalizationBenchmark {
    static func original(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
    static func main() {
        let seeds = ["com.example.App-Helper_2.0", "Google Chrome Canary", "İ_Σ.É-ß", "你好.应用", "日本語_アプリ", "العربية-تطبيق", "e\u{301} .\u{301}-\u{FE0F}_", "🧑🏽‍💻.app", "", " ._-", "line\nbreak\t", "A\u{00A0}B"]
        var fixtures = seeds
        for i in 0..<10000 {
            fixtures.append(seeds[i % seeds.count] + String(i) + seeds[(i * 7 + 3) % seeds.count])
        }
        for value in fixtures {
            if original(value) != value.normalizedForMatching() {
                print("Changed normalization: \(value.debugDescription); original: \(original(value).debugDescription); new: \(value.normalizedForMatching().debugDescription)")
                exit(1)
            }
        }
        for (label, inputs) in [("mixed Unicode", fixtures), ("ASCII identifiers", (0..<10012).map { "com.example.My-App_Helper.v\($0)" })] {
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var checksum = 0
        for pass in 0..<6 {
            for new in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let start = ContinuousClock.now
                for value in inputs {
                    checksum += (new ? value.normalizedForMatching() : original(value)).utf8.count
                }
                let duration = start.duration(to: .now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                if pass > 0 {
                    if new { newTimes.append(seconds) } else { oldTimes.append(seconds) }
                }
            }
        }
        print("PASS: \(fixtures.count) ASCII/Unicode cases match prior behavior; \(label) checksum \(checksum)")
        print("Original median seconds: \(oldTimes.sorted()[2]); revised median seconds: \(newTimes.sorted()[2])")
        }
    }
}
