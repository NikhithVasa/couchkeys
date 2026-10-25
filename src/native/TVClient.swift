import Foundation
import CryptoKit
import Darwin
import Dispatch

actor TVClient {
    private struct DeviceIdentity: Sendable {
        let name: String?
        let model: String?
        let power: String?
        let networkControl: String?
        let developerEnabled: Bool?
    }

    private struct AudioState: Sendable {
        let volume: Int?
        let muted: Bool?
        let unavailableReason: String?
    }

    private struct Catalog: Sendable {
        let apps: [TVApp]
        let observed: ContinuousClock.Instant
    }

    private struct RPCMessage: Sendable {
        let notification: String?
        let challenge: String?
        let operation: String?
        let requestID: String?
        let status: String?
        let statusMessage: String?
        let content: String?
    }

    private let target: TVTarget
    private let session: URLSession
    private let clock = ContinuousClock()
    private var socket: URLSessionWebSocketTask?
    private var requestCounter: UInt64 = 0
    private var catalog: Catalog?
    private var busy = false
    private var closed = false
    private var powerQuietUntil: ContinuousClock.Instant

    init(target: TVTarget = .configured) {
        self.target = target
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: RokuNoRedirects(), delegateQueue: nil)
        powerQuietUntil = ContinuousClock.now
    }

    private static let developerSettingsKeys: [RemoteKey] = [.home, .home, .home, .up, .up, .right, .left, .right, .left, .right]

    func snapshot() async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        return try await buildSnapshot(refreshCatalog: true)
    }

    func press(_ key: RemoteKey) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        _ = try await requireControl(poweredOn: true)

        let before: AudioState?
        switch key {
        case .volumeUp, .volumeDown, .mute:
            before = try await readAudio()
            if key == .mute {
                guard before?.muted != nil else {
                    throw TVFailure.message("The TV did not expose mute state; no mute command was sent.")
                }
            } else if before?.volume == nil {
                throw TVFailure.message("The TV did not expose a valid 0–100 volume; no volume command was sent.")
            }
        default:
            before = nil
        }

        try await httpPost(path: "keypress/\(key.rawValue)")
        do {
            if let before {
                if key == .mute, let muted = before.muted {
                    try await waitForMute(!muted)
                } else if let volume = before.volume {
                    let expected = key == .volumeUp ? min(100, volume + 1) : max(0, volume - 1)
                    try await waitForVolume(expected, previous: volume)
                }
            }
            let result = try await buildSnapshot(refreshCatalog: false)
            if let before {
                if key == .mute, result.muted != before.muted.map({ !$0 }) {
                    throw TVFailure.message("Mute state changed during readback.")
                }
                if key != .mute, let volume = before.volume {
                    let expected = key == .volumeUp ? min(100, volume + 1) : max(0, volume - 1)
                    guard result.volume == expected else {
                        throw TVFailure.message("Volume changed during readback.")
                    }
                }
            }
            return result
        } catch {
            throw uncertain(error, context: "The remote key was sent, but its readback was not confirmed.")
        }
    }

    func openDeveloperSettings(expectedEnabled: Bool) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        let identity = try await requireControl(poweredOn: true)
        guard identity.developerEnabled == expectedEnabled else {
            throw TVFailure.message("Developer-mode state changed or is unavailable. Refresh; no navigation was sent.")
        }
        var accepted = 0
        do {
            for key in Self.developerSettingsKeys {
                try Task.checkCancellation()
                try await httpPost(path: "keypress/\(key.rawValue)")
                accepted += 1
                if accepted < Self.developerSettingsKeys.count {
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            return try await buildSnapshot(refreshCatalog: false)
        } catch {
            throw uncertain(error, context: "Developer-settings navigation stopped after \(accepted) of \(Self.developerSettingsKeys.count) keys. Check the TV before retrying.")
        }
    }

    func sendText(_ text: String) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw TVFailure.message("Enter search text without tabs, newlines or control characters. No text was sent.")
        }
        try await waitForPowerQuiet()
        _ = try await requireControl(poweredOn: true)
        let total = text.unicodeScalars.count
        var accepted = 0
        do {
            for scalar in text.unicodeScalars {
                try Task.checkCancellation()
                let component = try encodedPathComponent(String(scalar))
                try await httpPost(path: "keypress/Lit_\(component)")
                accepted += 1
            }
            return try await buildSnapshot(refreshCatalog: false)
        } catch {
            if accepted > 0 {
                throw TVFailure.unknownOutcome("Text entry stopped after the TV acknowledged \(accepted) of \(total) characters. Check the TV before sending more text. \(explanation(error))")
            }
            throw error
        }
    }

    func setVolume(_ value: Int) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        guard (0...100).contains(value) else {
            throw TVFailure.message("Volume must be between 0 and 100.")
        }
        try await waitForPowerQuiet()
        _ = try await requireControl(poweredOn: true)
        guard var observed = try await readAudio().volume else {
            throw TVFailure.message("The TV did not expose a valid 0–100 volume; no volume command was sent.")
        }
        let maximumPulses = abs(value - observed)
        var pulses = 0
        do {
            while observed != value {
                try Task.checkCancellation()
                guard pulses < maximumPulses else {
                    throw TVFailure.message("Volume progress was inconsistent; adjustment stopped.")
                }
                _ = try await requireControl(poweredOn: true)
                guard try await readAudio().volume == observed else {
                    throw TVFailure.message("Volume changed outside this adjustment; adjustment stopped.")
                }
                let up = value > observed
                let expected = observed + (up ? 1 : -1)
                pulses += 1
                try await httpPost(path: "keypress/\(up ? "VolumeUp" : "VolumeDown")")
                try await waitForVolume(expected, previous: observed)
                observed = expected
            }
            let result = try await buildSnapshot(refreshCatalog: false)
            guard result.volume == value else {
                throw TVFailure.message("The requested volume was not present in the final readback.")
            }
            return result
        } catch {
            if pulses > 0 {
                throw uncertain(error, context: "Volume adjustment stopped after \(pulses) individual command(s).")
            }
            throw error
        }
    }

    func launch(appID: String) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        _ = try await requireControl(poweredOn: true)
        let apps = try await readApps()
        guard apps.contains(where: { $0.id == appID }) else {
            throw TVFailure.message("That app or input is not in the TV's current catalog. No launch was sent.")
        }
        _ = try await requireControl(poweredOn: true)
        let component = try encodedPathComponent(appID)
        try await httpPost(path: "launch/\(component)")
        do {
            let deadline = clock.now.advanced(by: .seconds(8))
            while true {
                if try await readActiveApp(deadline: deadline)?.id == appID { break }
                guard clock.now < deadline else {
                    throw TVFailure.message("The TV did not report the requested app or input within eight seconds.")
                }
                try await pause(until: deadline, interval: .milliseconds(250))
            }
            let result = try await buildSnapshot(refreshCatalog: false)
            guard result.activeApp?.id == appID else {
                throw TVFailure.message("The active app or input changed during readback.")
            }
            return result
        } catch {
            throw uncertain(error, context: "The launch was sent but the requested app or input was not confirmed.")
        }
    }

    func setPicture(name: String, value: String, context: PictureContext) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        _ = try await requireControl(poweredOn: true)
        let before = try await readPicture()
        guard before.context == context else {
            throw TVFailure.message("The TV input or picture mode changed. Refresh; no picture setting was written.")
        }
        let operation: String
        let attributes: String
        if name == "picture_mode" {
            guard before.modes.contains(value) else {
                throw TVFailure.message("That picture mode is not offered for the current signal.")
            }
            operation = "set-pq-picture-mode"
            attributes = "input_mode=\"\(xmlAttribute(context.input))\""
        } else {
            let verifiedFields: Set<String> = ["gamma", "color_temp", "noise_reduction", "color_space"]
            guard verifiedFields.contains(name), before.settings[name] != nil,
                  before.options[name]?.contains(value) == true else {
                throw TVFailure.message("That picture setting or value is not exposed by this TV. Numeric backlight/brightness is not available.")
            }
            operation = "set-pq-picture-settings"
            attributes = "input_mode=\"\(xmlAttribute(context.input))\" picture_mode=\"\(xmlAttribute(context.mode))\""
        }
        _ = try await requireControl(poweredOn: true)
        let current = try await queryXML("query-pq-picture-settings", root: "pq-picture-settings")
        guard try pictureContext(current) == context else {
            throw TVFailure.message("The TV input or picture mode changed. Refresh; no picture setting was written.")
        }
        let xml = "<\(operation) \(attributes)><setting name=\"\(xmlAttribute(name))\" value=\"\(xmlAttribute(value))\"/></\(operation)>"
        _ = try await rpc(operation, parameters: ["content-type": "text/xml", "param-settings": xml], mutation: true)
        do {
            let deadline = clock.now.advanced(by: .seconds(3))
            let expectedMode = name == "picture_mode" ? value : context.mode
            var after: PictureState
            while true {
                after = try await readPicture(deadline: deadline)
                guard after.context.input == context.input else {
                    throw TVFailure.message("The TV input changed after the picture command.")
                }
                let actual = name == "picture_mode" ? after.context.mode : after.settings[name]
                if after.context.mode == expectedMode, actual == value { break }
                guard clock.now < deadline else {
                    throw TVFailure.message("Picture readback did not confirm the requested value and context.")
                }
                if name != "picture_mode", after.context.mode != context.mode {
                    throw TVFailure.message("The TV picture mode changed after the picture command.")
                }
                try await pause(until: deadline, interval: .milliseconds(150))
            }
            return try await buildSnapshot(refreshCatalog: false, knownPicture: after)
        } catch {
            throw uncertain(error, context: "The picture command was sent, but its value and context were not confirmed.")
        }
    }

    func setPower(on: Bool) async throws -> TVSnapshot {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        let before = try await requireControl(poweredOn: false)
        let desired = on ? "PowerOn" : "DisplayOff"
        if before.power == desired {
            return try await buildSnapshot(refreshCatalog: false, knownIdentity: before)
        }
        discardSocket()
        if on { _ = try await ensureSocket() }
        powerQuietUntil = clock.now.advanced(by: .seconds(10))
        do {
            if on {
                _ = try await rpc("key-press", parameters: ["param-key": "PowerOn"], mutation: true)
            } else {
                try await httpPost(path: "keypress/PowerOff")
            }
        } catch {
            powerQuietUntil = clock.now.advanced(by: .seconds(10))
            throw error
        }
        powerQuietUntil = clock.now.advanced(by: .seconds(10))
        do {
            let deadline = clock.now.advanced(by: .seconds(8))
            var after: DeviceIdentity
            while true {
                after = try await readIdentity(deadline: deadline)
                if after.power == desired { break }
                guard clock.now < deadline else {
                    throw TVFailure.message("Actual screen state is \(after.power ?? "unknown"), not \(desired).")
                }
                try await pause(until: deadline, interval: .milliseconds(250))
            }
            return try await buildSnapshot(refreshCatalog: false, knownIdentity: after)
        } catch {
            throw uncertain(error, context: "The power command was sent, but actual \(desired) state was not confirmed.")
        }
    }

    func wake() async throws {
        try beginOperation()
        defer { busy = false }
        try await waitForPowerQuiet()
        guard target.wifiMAC.count == 6 else {
            throw TVFailure.message("The selected TV does not have a valid six-byte Wi-Fi MAC address.")
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, target.broadcast, &destination.sin_addr) == 1 else {
            throw TVFailure.message("The selected TV's IPv4 broadcast address is invalid.")
        }
        let descriptor = Darwin.socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard descriptor >= 0 else {
            throw TVFailure.message("Cannot create the Wake-on-LAN socket: \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TVFailure.message("Cannot enable UDP broadcast: \(String(cString: strerror(errno))).")
        }
        var packet = Data(repeating: 0xff, count: 6)
        packet.reserveCapacity(102)
        for _ in 0..<16 { packet.append(contentsOf: target.wifiMAC) }
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, address,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            throw TVFailure.message("The Wake-on-LAN packet could not be sent: \(String(cString: strerror(errno))).")
        }
        powerQuietUntil = clock.now.advanced(by: .seconds(10))
    }

    func close() {
        closed = true
        discardSocket()
        session.invalidateAndCancel()
        catalog = nil
    }

    private func beginOperation() throws {
        guard !closed else { throw TVFailure.message("The TV connection has been closed.") }
        guard !busy else { throw TVFailure.busy }
        busy = true
    }

    private func waitForPowerQuiet() async throws {
        if clock.now < powerQuietUntil {
            try await clock.sleep(until: powerQuietUntil)
        }
        try Task.checkCancellation()
        guard !closed else { throw TVFailure.message("The TV connection has been closed.") }
    }

    private func pause(until deadline: ContinuousClock.Instant, interval: Duration) async throws {
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: interval)))
    }

    private func requireControl(poweredOn: Bool) async throws -> DeviceIdentity {
        let identity = try await readIdentity()
        guard identity.networkControl == "enabled" else {
            throw TVFailure.message("Network control is restricted or unknown. Enable Control by mobile apps on the selected TCL before sending commands.")
        }
        if poweredOn, identity.power != "PowerOn" {
            throw TVFailure.message("The TV display is off or its state is unknown. Use Power on and confirm PowerOn before navigation or sound commands.")
        }
        return identity
    }

    private func readIdentity(deadline: ContinuousClock.Instant? = nil) async throws -> DeviceIdentity {
        let root = try RokuXML.parse(try await httpGet(path: "query/device-info", deadline: deadline), root: "device-info")
        return try verifyIdentity(root)
    }

    private func verifyIdentity(_ root: RokuElement) throws -> DeviceIdentity {
        guard root.value("serial-number") == target.serial, root.value("vendor-name") == "TCL" else {
            discardSocket()
            catalog = nil
            throw TVFailure.message("The device at \(target.host) is not the selected TCL (serial \(target.serial)). Controls are blocked.")
        }
        let developerEnabled: Bool?
        switch root.value("developer-enabled") {
        case "true": developerEnabled = true
        case "false": developerEnabled = false
        default: developerEnabled = nil
        }
        return DeviceIdentity(name: root.value("friendly-device-name"),
                              model: root.value("model-name") ?? root.value("model-number"),
                              power: root.value("power-mode"),
                              networkControl: root.value("ecp-setting-mode"), developerEnabled: developerEnabled)
    }

    private func readAudio(deadline: ContinuousClock.Instant? = nil) async throws -> AudioState {
        let root = try RokuXML.parse(try await httpGet(path: "query/audio-device", deadline: deadline), root: "audio-device")
        guard let global = root.child("global") else {
            return AudioState(volume: nil, muted: nil,
                              unavailableReason: "The TV did not expose global audio state.")
        }
        let parsedVolume = global.value("volume").flatMap(Int.init)
        let volume = parsedVolume.flatMap { (0...100).contains($0) ? $0 : nil }
        let muted: Bool?
        switch global.value("muted") {
        case "true": muted = true
        case "false": muted = false
        default: muted = nil
        }
        var missing: [String] = []
        if volume == nil { missing.append("a valid 0–100 volume") }
        if muted == nil { missing.append("mute state") }
        return AudioState(volume: volume, muted: muted,
                          unavailableReason: missing.isEmpty ? nil : "The TV did not expose \(missing.joined(separator: " or ")).")
    }

    private func readApps() async throws -> [TVApp] {
        let root = try RokuXML.parse(try await httpGet(path: "query/apps"), root: "apps")
        var apps: [TVApp] = []
        var identifiers = Set<String>()
        for item in root.children where item.name == "app" {
            guard let identifier = item.attributes["id"]?.nonemptyRokuText,
                  identifiers.insert(identifier).inserted else {
                throw TVFailure.message("The TV returned an app catalog with missing or duplicate IDs.")
            }
            apps.append(TVApp(id: identifier, name: item.text.nonemptyRokuText,
                              type: item.attributes["type"]?.nonemptyRokuText))
        }
        catalog = Catalog(apps: apps, observed: clock.now)
        return apps
    }

    private func readActiveApp(deadline: ContinuousClock.Instant? = nil) async throws -> TVApp? {
        let root = try RokuXML.parse(try await httpGet(path: "query/active-app", deadline: deadline), root: "active-app")
        guard let app = root.child("app"), let identifier = app.attributes["id"]?.nonemptyRokuText else {
            return nil
        }
        return TVApp(id: identifier, name: app.text.nonemptyRokuText,
                     type: app.attributes["type"]?.nonemptyRokuText)
    }

    private func readPicture(deadline: ContinuousClock.Instant? = nil) async throws -> PictureState {
        let initial = try await queryXML("query-pq-picture-settings", root: "pq-picture-settings", deadline: deadline)
        let context = try pictureContext(initial)
        let modes = try await queryXML("query-pq-picture-modes", root: "pq-picture-modes", deadline: deadline)
        let options = try await queryXML("query-pq-options", root: "pq-options", deadline: deadline)
        let current = try await queryXML("query-pq-picture-settings", root: "pq-picture-settings", deadline: deadline)
        guard try pictureContext(current) == context, modes.attributes["input_mode"] == context.input else {
            throw TVFailure.message("Picture context changed or is unknown. Refresh before adjusting.")
        }
        for response in [modes, options] {
            if let input = response.attributes["input_mode"], input != context.input {
                throw TVFailure.message("Picture options belong to a different TV input. Refresh before adjusting.")
            }
            if let mode = response.attributes["picture_mode"], mode != context.mode {
                throw TVFailure.message("Picture options belong to a different picture mode. Refresh before adjusting.")
            }
        }
        var settings: [String: String] = [:]
        for item in current.children where item.name == "setting" {
            if let name = item.attributes["name"], let value = item.attributes["value"] {
                settings[name] = value
            }
        }
        let modeValues = modes.children.filter { $0.name == "setting" && $0.attributes["name"] == "picture_mode" }
            .flatMap(\.children).filter { $0.name == "option" }.compactMap { $0.attributes["value"] }
        var values: [String: [String]] = [:]
        for item in options.children where item.name == "setting" {
            if let name = item.attributes["name"] {
                values[name] = item.children.filter { $0.name == "option" }.compactMap { $0.attributes["value"] }
            }
        }
        return PictureState(context: context, settings: settings, modes: modeValues, options: values)
    }

    private func pictureContext(_ root: RokuElement) throws -> PictureContext {
        guard let input = root.attributes["input_mode"]?.nonemptyRokuText,
              let mode = root.attributes["picture_mode"]?.nonemptyRokuText else {
            throw TVFailure.message("The TV did not expose a complete picture input/mode context.")
        }
        return PictureContext(input: input, mode: mode)
    }

    private func waitForVolume(_ expected: Int, previous: Int) async throws {
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            guard let volume = try await readAudio(deadline: deadline).volume else {
                throw TVFailure.message("Volume became unavailable after the command.")
            }
            if volume == expected {
                try await pause(until: deadline, interval: .milliseconds(100))
                guard try await readAudio(deadline: deadline).volume == expected else {
                    throw TVFailure.message("Volume changed unexpectedly during confirmation; no further step was sent.")
                }
                return
            }
            guard volume == previous else {
                throw TVFailure.message("Volume changed by an unexpected amount; another controller may be active. No further step was sent.")
            }
            guard clock.now < deadline else {
                throw TVFailure.message("The volume step did not produce confirmed progress within two seconds. It was not repeated.")
            }
            try await pause(until: deadline, interval: .milliseconds(100))
        }
    }

    private func waitForMute(_ expected: Bool) async throws {
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            guard let muted = try await readAudio(deadline: deadline).muted else {
                throw TVFailure.message("Mute state became unavailable after the command.")
            }
            if muted == expected { return }
            guard clock.now < deadline else {
                throw TVFailure.message("The requested mute state was not confirmed within two seconds.")
            }
            try await pause(until: deadline, interval: .milliseconds(100))
        }
    }

    private func buildSnapshot(refreshCatalog: Bool, knownIdentity: DeviceIdentity? = nil,
                               knownPicture: PictureState? = nil) async throws -> TVSnapshot {
        let identity: DeviceIdentity
        if let knownIdentity { identity = knownIdentity } else { identity = try await readIdentity() }
        var unavailable: [String: String] = [:]
        if identity.developerEnabled == nil {
            unavailable["developer_mode"] = "The TV did not expose a valid developer-mode state. No mode change can be requested."
        }
        let active: TVApp?
        do {
            active = try await readActiveApp()
            if active == nil { unavailable["active_app"] = "The TV did not identify an active app or input." }
        } catch {
            try propagateCancellation(error)
            active = nil
            unavailable["active_app"] = explanation(error)
        }
        let audio: AudioState
        do {
            audio = try await readAudio()
            unavailable["audio"] = audio.unavailableReason
        } catch {
            try propagateCancellation(error)
            audio = AudioState(volume: nil, muted: nil, unavailableReason: nil)
            unavailable["audio"] = explanation(error)
        }
        let apps: [TVApp]
        if !refreshCatalog, let catalog, clock.now < catalog.observed.advanced(by: .seconds(60)) {
            apps = catalog.apps
        } else {
            do {
                apps = try await readApps()
            } catch {
                try propagateCancellation(error)
                apps = []
                unavailable["apps"] = explanation(error)
            }
        }
        if apps.isEmpty, unavailable["apps"] == nil {
            unavailable["apps"] = "The TV reported no installed apps or inputs. No assumed app IDs will be launched."
        }
        let picture: PictureState?
        if let knownPicture {
            picture = knownPicture
        } else if identity.power != "PowerOn" {
            picture = nil
            unavailable["picture"] = "Picture controls require a confirmed PowerOn screen state."
        } else if identity.networkControl != "enabled" {
            picture = nil
            unavailable["picture"] = "Picture controls require enabled network control on the TV."
        } else {
            do {
                picture = try await readPicture()
            } catch {
                try propagateCancellation(error)
                picture = nil
                unavailable["picture"] = explanation(error)
            }
        }
        if let picture, picture.modes.isEmpty {
            unavailable["picture"] = "The TV did not offer picture modes for the current signal; only explicitly exposed settings can be changed."
        }
        return TVSnapshot(name: identity.name ?? target.name, model: identity.model,
                          host: target.host, power: identity.power, networkControl: identity.networkControl,
                          developerEnabled: identity.developerEnabled,
                          volume: audio.volume, muted: audio.muted, activeApp: active, apps: apps,
                          picture: picture, unavailableReasons: unavailable, observedAt: Date())
    }

    private func httpGet(path: String, deadline: ContinuousClock.Instant? = nil) async throws -> Data {
        do {
            return try await http(path: path, method: "GET", deadline: deadline).data
        } catch {
            if error is CancellationError { throw error }
            throw TVFailure.message("Cannot read \(path) from the selected TV: \(explanation(error))")
        }
    }

    private func httpPost(path: String) async throws {
        do {
            let reply = try await http(path: path, method: "POST")
            guard (200..<300).contains(reply.status) else {
                throw RokuTransportError.rejected("The TV rejected \(path) with HTTP \(reply.status).")
            }
        } catch RokuTransportError.rejected(let message) {
            throw TVFailure.message(message)
        } catch {
            throw uncertain(error, context: "The TV command \(path) was not acknowledged.")
        }
    }

    private func http(path: String, method: String, deadline: ContinuousClock.Instant? = nil) async throws -> RokuHTTPReply {
        try Task.checkCancellation()
        guard !closed else { throw TVFailure.message("The TV connection has been closed.") }
        var request = URLRequest(url: try endpoint(scheme: "http", path: path))
        request.httpMethod = method
        request.timeoutInterval = 4
        if method == "POST" { request.httpBody = Data() }
        let requestDeadline = clock.now.advanced(by: .seconds(5))
        let effectiveDeadline = min(deadline ?? requestDeadline, requestDeadline)
        guard clock.now < effectiveDeadline else { throw RokuTransportError.timeout }
        let gate = RokuDeadline<RokuHTTPReply>(deadline: effectiveDeadline)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                gate.finish(.failure(error))
            } else if let response = response as? HTTPURLResponse, let data {
                guard data.count <= 1_048_576 else {
                    gate.finish(.failure(RokuTransportError.invalid("The TV response exceeds one MiB.")))
                    return
                }
                gate.finish(.success(RokuHTTPReply(data: data, status: response.statusCode)))
            } else {
                gate.finish(.failure(RokuTransportError.invalid("The TV did not return an HTTP response.")))
            }
        }
        let reply = try await gate.wait(start: { task.resume() }, abort: { task.cancel() })
        if method == "GET", !(200..<300).contains(reply.status) {
            throw RokuTransportError.rejected("The TV returned HTTP \(reply.status).")
        }
        return reply
    }

    private func ensureSocket(deadline: ContinuousClock.Instant? = nil) async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        discardSocket()
        try Task.checkCancellation()
        guard !closed else { throw TVFailure.message("The TV connection has been closed.") }
        let task = session.webSocketTask(with: try endpoint(scheme: "ws", path: "ecp-session"), protocols: ["ecp-2"])
        task.maximumMessageSize = 1_048_576
        socket = task
        task.resume()
        do {
            let receiveDeadline = clock.now.advanced(by: .seconds(5))
            let challenge = try decodeRPC(try await receive(task, deadline: min(deadline ?? receiveDeadline, receiveDeadline)))
            guard challenge.notification == "authenticate", let text = challenge.challenge else {
                throw TVFailure.message("The TV did not provide the expected ECP2 authentication challenge.")
            }
            let digest = Insecure.SHA1.hash(data: Data((text + "F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1").utf8))
            _ = try await exchange(task, operation: "authenticate", parameters: [
                "param-response": Data(digest).base64EncodedString(),
                "param-client-friendly-name": "CouchKeys", "param-has-microphone": "false"
            ], deadline: deadline)
            let identity = try await exchange(task, operation: "query-device-info", parameters: [:], deadline: deadline)
            _ = try verifyIdentity(xmlResponse(identity, root: "device-info"))
            return task
        } catch {
            discardSocket()
            throw error
        }
    }

    private func rpc(_ operation: String, parameters: [String: String] = [:], mutation: Bool = false,
                     deadline: ContinuousClock.Instant? = nil) async throws -> RPCMessage {
        let task = try await ensureSocket(deadline: deadline)
        do {
            return try await exchange(task, operation: operation, parameters: parameters, deadline: deadline)
        } catch RokuTransportError.rejected(let message) {
            discardSocket()
            throw TVFailure.message(message)
        } catch {
            discardSocket()
            if mutation {
                throw uncertain(error, context: "The TV's \(operation) command was not acknowledged.")
            }
            throw error
        }
    }

    private func queryXML(_ operation: String, root: String,
                          deadline: ContinuousClock.Instant? = nil) async throws -> RokuElement {
        do {
            return try xmlResponse(try await rpc(operation, deadline: deadline), root: root)
        } catch {
            discardSocket()
            throw error
        }
    }

    private func xmlResponse(_ response: RPCMessage, root: String) throws -> RokuElement {
        guard let content = response.content, let data = Data(base64Encoded: content) else {
            throw TVFailure.message("The TV's \(root) response has invalid or missing base64 XML.")
        }
        return try RokuXML.parse(data, root: root)
    }

    private func exchange(_ task: URLSessionWebSocketTask, operation: String,
                          parameters: [String: String], deadline parentDeadline: ContinuousClock.Instant? = nil) async throws -> RPCMessage {
        guard requestCounter < UInt64.max else {
            throw TVFailure.message("The ECP2 request counter is exhausted. Reopen the app to start a new client.")
        }
        requestCounter += 1
        let identifier = String(requestCounter)
        var request = parameters
        request["request"] = operation
        request["request-id"] = identifier
        let bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw RokuTransportError.invalid("Cannot encode the ECP2 request.")
        }
        let requestDeadline = clock.now.advanced(by: .seconds(5))
        let deadline = min(parentDeadline ?? requestDeadline, requestDeadline)
        guard clock.now < deadline else { throw RokuTransportError.timeout }
        try await send(text, over: task, deadline: deadline)
        while clock.now < deadline {
            let response = try decodeRPC(try await receive(task, deadline: deadline))
            guard response.requestID == identifier else { continue }
            guard response.operation == operation else {
                throw RokuTransportError.invalid("ECP2 response operation does not match request \(identifier).")
            }
            guard let statusText = response.status, let status = Int(statusText) else {
                throw RokuTransportError.invalid("ECP2 response omitted a valid status.")
            }
            guard (200..<300).contains(status) else {
                let hint = status == 403 ? " Enable Control by mobile apps on the TV." : ""
                throw RokuTransportError.rejected("\(operation): the TV returned \(status) \(response.statusMessage ?? "").\(hint)")
            }
            return response
        }
        task.cancel()
        throw RokuTransportError.timeout
    }

    private func decodeRPC(_ text: String) throws -> RPCMessage {
        guard text.utf8.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RokuTransportError.invalid("Invalid ECP2 JSON response.")
        }
        return RPCMessage(notification: object["notify"] as? String, challenge: object["param-challenge"] as? String,
                          operation: object["response"] as? String, requestID: object["response-id"] as? String,
                          status: object["status"] as? String, statusMessage: object["status-msg"] as? String,
                          content: object["content-data"] as? String)
    }

    private func receive(_ task: URLSessionWebSocketTask, deadline: ContinuousClock.Instant) async throws -> String {
        let gate = RokuDeadline<String>(deadline: deadline)
        return try await gate.wait(start: {
            task.receive { result in
                switch result {
                case .success(.string(let text)):
                    gate.finish(.success(text))
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) {
                        gate.finish(.success(text))
                    } else {
                        gate.finish(.failure(RokuTransportError.invalid("Non-UTF-8 ECP2 message.")))
                    }
                case .failure(let error):
                    gate.finish(.failure(error))
                @unknown default:
                    gate.finish(.failure(RokuTransportError.invalid("Unknown ECP2 message type.")))
                }
            }
        }, abort: { task.cancel() })
    }

    private func send(_ text: String, over task: URLSessionWebSocketTask,
                      deadline: ContinuousClock.Instant) async throws {
        let gate = RokuDeadline<Void>(deadline: deadline)
        try await gate.wait(start: {
            task.send(.string(text)) { error in
                if let error { gate.finish(.failure(error)) } else { gate.finish(.success(())) }
            }
        }, abort: { task.cancel() })
    }

    private func discardSocket() {
        socket?.cancel()
        socket = nil
    }

    private func endpoint(scheme: String, path: String) throws -> URL {
        var address = in_addr()
        guard inet_pton(AF_INET, target.host, &address) == 1 else {
            throw TVFailure.message("The selected TV host must be a literal IPv4 address.")
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = target.host
        components.port = 8060
        components.percentEncodedPath = "/" + path
        guard let url = components.url else { throw TVFailure.message("The selected TV address is invalid.") }
        return url
    }

    private func encodedPathComponent(_ value: String) throws -> String {
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters: characters) else {
            throw TVFailure.message("The TV supplied an invalid app ID. No launch was sent.")
        }
        return encoded
    }

    private func xmlAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func propagateCancellation(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if closed { throw TVFailure.message("The TV connection has been closed.") }
    }

    private func explanation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func uncertain(_ error: any Error, context: String) -> TVFailure {
        if let failure = error as? TVFailure, case .unknownOutcome(let message) = failure {
            return .unknownOutcome(message)
        }
        return .unknownOutcome("\(context) \(explanation(error))")
    }
}

private struct RokuHTTPReply: Sendable {
    let data: Data
    let status: Int
}

private enum RokuTransportError: LocalizedError, Sendable {
    case timeout
    case invalid(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The TV response deadline expired; its network task was cancelled."
        case .invalid(let text), .rejected(let text): return text
        }
    }
}

private final class RokuNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class RokuDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var continuation: CheckedContinuation<Value, any Error>?
    private var earlyResult: Result<Value, any Error>?
    private var completed = false
    private var timer: DispatchSourceTimer?
    private var abort: (@Sendable () -> Void)?

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    func wait(start: @escaping @Sendable () -> Void,
              abort: @escaping @Sendable () -> Void) async throws -> Value {
        setAbort(abort)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if install(continuation) { start() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancelling: true)
        }
    }

    func finish(_ result: Result<Value, any Error>, cancelling: Bool = false) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { earlyResult = result }
        let timer = self.timer
        self.timer = nil
        let abort = cancelling ? self.abort : nil
        self.abort = nil
        lock.unlock()
        timer?.cancel()
        abort?()
        continuation?.resume(with: result)
    }

    private func setAbort(_ abort: @escaping @Sendable () -> Void) {
        lock.lock()
        self.abort = abort
        lock.unlock()
    }

    private func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if completed {
            let result = earlyResult
            earlyResult = nil
            lock.unlock()
            if let result { continuation.resume(with: result) }
            return false
        }
        self.continuation = continuation
        let components = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(RokuTransportError.timeout), cancelling: true)
        }
        self.timer = timer
        timer.resume()
        lock.unlock()
        return true
    }
}
