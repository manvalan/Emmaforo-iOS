import AppIntents
import EmmaForoShared
import Foundation
import WidgetKit

public extension Notification.Name {
    public static let emmaforoLampChanged = Notification.Name("emmaforo.lamp.changed")
}

public struct EmmaForoIntentsPackage: AppIntentsPackage {}

public enum LampSession {
    public static var send: ((String, Bool, Int) async -> Bool)?

    public static func deliver(command: String, blink: Bool, level: Int) async -> Bool {
        if send == nil {
            for _ in 0..<120 where send == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let send else { return false }
        return await send(command, blink, level)
    }
}

public struct LampIntent: AppIntent {
    public static var title: LocalizedStringResource = "Imposta luce"
    public static var openAppWhenRun: Bool { false }
    public static var isDiscoverable: Bool { false }

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    @available(iOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Colore")
    public var color: String

    public init() { color = "" }

    public init(color: String) { self.color = color }

    public func perform() async throws -> some IntentResult {
        let previous = (LampSnapshot.isOn, LampSnapshot.color, LampSnapshot.blink, LampSnapshot.level)
        let level = previous.3
        let blink = previous.2
        let turningOff = previous.0 && previous.1 == color
        if turningOff {
            LampSnapshot.save(on: false, color: "", blink: blink, level: level)
        } else {
            LampSnapshot.save(on: true, color: color, blink: blink, level: level)
        }
        let savedToken = LampSnapshot.token
        let command = turningOff ? "spento" : color
        let blinkToSend = turningOff ? false : blink
        WidgetCenter.shared.reloadTimelines(ofKind: "EmmaForoWidget")
        NotificationCenter.default.post(name: .emmaforoLampChanged, object: nil)
        Task {
            let ok = await LampSession.deliver(command: command, blink: blinkToSend, level: level)
            if !ok, LampSnapshot.token == savedToken {
                LampSnapshot.save(on: previous.0, color: previous.1, blink: previous.2, level: previous.3)
                WidgetCenter.shared.reloadTimelines(ofKind: "EmmaForoWidget")
                NotificationCenter.default.post(name: .emmaforoLampChanged, object: nil)
            }
        }
        return .result()
    }
}

public struct BlinkIntent: AppIntent {
    public static var title: LocalizedStringResource = "Lampeggio"
    public static var openAppWhenRun: Bool { false }
    public static var isDiscoverable: Bool { false }

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    @available(iOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public init() {}

    public func perform() async throws -> some IntentResult {
        let previousBlink = LampSnapshot.blink
        let blink = !previousBlink
        let level = LampSnapshot.level
        let color = LampSnapshot.color
        let on = LampSnapshot.isOn && !color.isEmpty
        LampSnapshot.save(on: on, color: on ? color : "", blink: blink, level: level)
        let savedToken = LampSnapshot.token
        WidgetCenter.shared.reloadTimelines(ofKind: "EmmaForoWidget")
        NotificationCenter.default.post(name: .emmaforoLampChanged, object: nil)
        guard on else { return .result() }
        Task {
            let ok = await LampSession.deliver(command: color, blink: blink, level: level)
            if !ok, LampSnapshot.token == savedToken {
                LampSnapshot.save(on: true, color: color, blink: previousBlink, level: level)
                WidgetCenter.shared.reloadTimelines(ofKind: "EmmaForoWidget")
                NotificationCenter.default.post(name: .emmaforoLampChanged, object: nil)
            }
        }
        return .result()
    }
}
