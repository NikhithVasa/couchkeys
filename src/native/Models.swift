import Foundation

struct TVTarget: Sendable {
    let host: String
    let serial: String
    let name: String
    let wifiMAC: [UInt8]
    let broadcast: String

    static let configured = TVTarget(
        host: "10.0.0.128",
        serial: "X01200UWX4Y2",
        name: "65\" TCL Roku TV",
        wifiMAC: [0x38, 0xe7, 0xc0, 0x7b, 0xde, 0x72],
        broadcast: "10.0.0.255"
    )
}

struct TVApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let type: String?

    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? id }
    var isInput: Bool { type == "tvin" }
}

struct PictureContext: Equatable, Sendable {
    let input: String
    let mode: String
}

struct PictureState: Equatable, Sendable {
    let context: PictureContext
    let settings: [String: String]
    let modes: [String]
    let options: [String: [String]]

    var modeTitle: String { Self.modeTitle(context.mode) }

    static func modeTitle(_ value: String) -> String {
        switch value {
        case "low_power": return "Low Power"
        case "normal": return "Standard"
        case "vivid": return "Vivid"
        case "movie": return "Movie"
        case "sports": return "Sports"
        case "hdr_dark": return "HDR Dark"
        case "hdr_normal": return "HDR Normal"
        case "hdr_bright": return "HDR Bright"
        case "dv_dark": return "Dolby Vision Dark"
        case "dv_normal": return "Dolby Vision Normal"
        case "dv_bright": return "Dolby Vision Bright"
        default: return value
        }
    }
}

struct TVSnapshot: Equatable, Sendable {
    let name: String
    let model: String?
    let host: String
    let power: String?
    let networkControl: String?
    let developerEnabled: Bool?
    let volume: Int?
    let muted: Bool?
    let activeApp: TVApp?
    let apps: [TVApp]
    let picture: PictureState?
    let unavailableReasons: [String: String]
    let observedAt: Date

    var isPoweredOn: Bool { power == "PowerOn" }
    var canControl: Bool { isPoweredOn && networkControl == "enabled" }
    var inputs: [TVApp] { apps.filter(\.isInput) }
    var streamingApps: [TVApp] { apps.filter { !$0.isInput } }
}

enum RemoteKey: String, Sendable {
    case home = "Home"
    case back = "Back"
    case options = "Info"
    case up = "Up"
    case down = "Down"
    case left = "Left"
    case right = "Right"
    case select = "Select"
    case backspace = "Backspace"
    case enter = "Enter"
    case play = "Play"
    case rewind = "Rev"
    case forward = "Fwd"
    case volumeUp = "VolumeUp"
    case volumeDown = "VolumeDown"
    case mute = "VolumeMute"
}

enum TVFailure: LocalizedError, Sendable {
    case busy
    case message(String)
    case unknownOutcome(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Another TV operation is still running."
        case .message(let text): return text
        case .unknownOutcome(let text): return text + " The command may have applied; it was not retried. Refresh to read the actual TV state."
        }
    }
}
