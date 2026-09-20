import Foundation

/// Locally retained picker options, independent of the currently selected load.
public enum CustomLoadWeights {
    private static func valid(_ values: [Double]) -> [Double] {
        Array(Set(values.filter { $0.isFinite && $0 > 0 && $0 <= 999 })).sorted()
    }

    private static func decode(_ saved: String) -> [Double] {
        (try? JSONDecoder().decode([Double].self, from: Data(saved.utf8))) ?? []
    }

    public static func rows(presets: [Double], saved: String, current: Double) -> [Double] {
        valid(presets + decode(saved) + [current])
    }

    public static func adding(_ value: Double, to saved: String) -> String {
        guard let data = try? JSONEncoder().encode(valid(decode(saved) + [value])) else { return saved }
        return String(decoding: data, as: UTF8.self)
    }
}
