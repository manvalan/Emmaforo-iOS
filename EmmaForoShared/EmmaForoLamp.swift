import Foundation

public enum LampSnapshot {
    public static let suiteID = "group.com.emmaforo.remote"

    private static var store: UserDefaults {
        UserDefaults(suiteName: suiteID) ?? .standard
    }

    public static var isOn: Bool { store.bool(forKey: "lampOn") }
    public static var color: String { store.string(forKey: "lampColor") ?? "" }
    public static var blink: Bool { store.bool(forKey: "lampBlink") }
    public static var level: Int {
        guard store.object(forKey: "lampLevel") != nil else { return 255 }
        return min(max(store.integer(forKey: "lampLevel"), 0), 255)
    }

    public static var token: Int { store.integer(forKey: "lampToken") }
    public static var stationURL: String { store.string(forKey: "stationURL") ?? "" }

    public static func saveStation(_ url: String) {
        store.set(url, forKey: "stationURL")
    }

    public static func save(on: Bool, color: String, blink: Bool, level: Int) {
        store.set(on, forKey: "lampOn")
        store.set(color, forKey: "lampColor")
        store.set(blink, forKey: "lampBlink")
        store.set(level, forKey: "lampLevel")
        store.set(token + 1, forKey: "lampToken")
        store.synchronize()
    }
}
