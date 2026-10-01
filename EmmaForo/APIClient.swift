import EmmaForoShared
import Foundation

struct EmmaForoNetwork: Identifiable, Decodable {
    let ssid: String
    let rssi: Int

    var id: String { ssid }
}

struct EmmaForoBattery: Decodable {
    let percentage: Int
    let voltage_mv: Int
    let charging: Bool
    let charge_status: Int?
    let fault: Int?
    let estimated: Bool?
}

struct EmmaForoBoardInfo: Decodable {
    let name: String
    let wifi: String
    let wifi_saved: Bool
    let password_saved: Bool
    let safe: Bool
    let paused: Bool
    let gentle: Bool
    let colors: Int
    let serial: String
    let firmware: String
    let preset: String
    let percentage: Int
    let voltage_mv: Int
    let charging: Bool
    let charge_status: Int
    let fault: Int
    let estimated: Bool
}

enum EmmaForoLink {
    static func send(command: String, blink: Bool, level: Int) async -> Bool {
        let saved = LampSnapshot.stationURL
        var candidates = [saved, "http://emmaforo.local"]
        if saved == "http://emmaforo.local" { candidates = ["http://emmaforo.local"] }
        var seen = Set<String>()
        for endpoint in candidates where !endpoint.isEmpty && seen.insert(endpoint).inserted {
            if await EmmaForoAPI.send(endpoint: endpoint, command: command, blink: blink, brightness: level) {
                LampSnapshot.saveStation(endpoint)
                return true
            }
        }
        return false
    }

    static func resolve() async -> String {
        let saved = LampSnapshot.stationURL
        var candidates = [saved, "http://emmaforo.local"]
        if saved == "http://emmaforo.local" { candidates = ["http://emmaforo.local"] }
        var seen = Set<String>()
        for endpoint in candidates where !endpoint.isEmpty && seen.insert(endpoint).inserted {
            if await EmmaForoAPI.ping(endpoint: endpoint) {
                LampSnapshot.saveStation(endpoint)
                return endpoint
            }
        }
        return ""
    }
}

struct EmmaForoAPI {
    static func send(endpoint: String, command: String, blink: Bool, led: Int? = nil,
                     intervalMilliseconds: Int = 1000, brightness: Int = 255,
                     timeout: TimeInterval = 4) async -> Bool {
        var components = URLComponents(string: "\(endpoint)/api/led")
        var query = [URLQueryItem(name: "command", value: command),
                     URLQueryItem(name: "blink", value: blink ? "true" : "false"),
                     URLQueryItem(name: "interval", value: String(intervalMilliseconds)),
                     URLQueryItem(name: "level", value: String(min(max(brightness, 0), 255)))]
        if let led { query.append(URLQueryItem(name: "led", value: String(led))) }
        components?.queryItems = query
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200..<300).contains(statusCode)
        } catch {
            return false
        }
    }

    static func ping(endpoint: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 500 < 500
        } catch { return false }
    }

    static func battery(endpoint: String) async -> EmmaForoBattery? {
        guard let url = URL(string: "\(endpoint)/api/battery") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(EmmaForoBattery.self, from: data)
        } catch {
            return nil
        }
    }

    static func info(endpoint: String) async -> EmmaForoBoardInfo? {
        guard let url = URL(string: "\(endpoint)/api/info") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(EmmaForoBoardInfo.self, from: data)
        } catch {
            return nil
        }
    }

    static func setCurrent(endpoint: String, gentle: Bool) async -> Bool {
        guard let url = URL(string: "\(endpoint)/api/current") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "gentle=\(gentle ? "1" : "0")".data(using: .utf8)
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200..<300).contains(statusCode)
        } catch {
            return false
        }
    }

    static func scanNetworks(endpoint: String) async -> [EmmaForoNetwork] {
        guard let url = URL(string: "\(endpoint)/api/scan") else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try JSONDecoder().decode([EmmaForoNetwork].self, from: data)
        } catch {
            return []
        }
    }
}
