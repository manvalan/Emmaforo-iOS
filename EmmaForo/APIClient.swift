import EmmaForoShared
import Foundation

struct EmmaForoNetwork: Identifiable, Decodable {
    let ssid: String
    let rssi: Int

    var id: String { ssid }
}
