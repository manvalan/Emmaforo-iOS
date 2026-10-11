import EmmaForoShared
import SwiftUI
import UIKit

enum EmmaForoSession {
    static func install() {
        guard LampSession.send == nil else { return }
        LampSession.send = { command, blink, level in
            let radio = EmmaForoBluetooth.shared
            radio.prepareForCommand()
            let task = UIApplication.shared.beginBackgroundTask(withName: "emmaforo-lamp") {}
            defer {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
            // Bluetooth only: the lamp no longer answers on the home network.
            return await radio.sendLamp(command: command, blink: blink, level: level)
        }
    }
}

final class EmmaForoDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        EmmaForoSession.install()
        return true
    }
}

@main
struct EmmaForoApp: App {
    @UIApplicationDelegateAdaptor(EmmaForoDelegate.self) private var delegate

    init() {
        EmmaForoSession.install()
        EmmaForoBluetooth.shared.connect()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
