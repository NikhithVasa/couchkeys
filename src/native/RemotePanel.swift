import SwiftUI

private enum RemotePalette {
    static let background = Color(red: 10 / 255.0, green: 14 / 255.0, blue: 26 / 255.0)
    static let surface = Color.white.opacity(0.055)
    static let surfaceHigh = Color.white.opacity(0.1)
    static let line = Color.white.opacity(0.085)
    static let text = Color(red: 243 / 255.0, green: 245 / 255.0, blue: 250 / 255.0)
    static let secondary = Color(red: 222 / 255.0, green: 230 / 255.0, blue: 247 / 255.0).opacity(0.6)
    static let faint = Color(red: 222 / 255.0, green: 230 / 255.0, blue: 247 / 255.0).opacity(0.36)
    static let accent = Color(red: 61 / 255.0, green: 139 / 255.0, blue: 255 / 255.0)
    static let warm = Color(red: 255 / 255.0, green: 180 / 255.0, blue: 107 / 255.0)
    static let green = Color(red: 74 / 255.0, green: 222 / 255.0, blue: 128 / 255.0)
    static let red = Color(red: 255 / 255.0, green: 120 / 255.0, blue: 110 / 255.0)
    static let primaryTop = Color(red: 90 / 255.0, green: 162 / 255.0, blue: 255 / 255.0)
    static let primaryBottom = Color(red: 47 / 255.0, green: 123 / 255.0, blue: 242 / 255.0)
}

private struct RemoteCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RemotePalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(RemotePalette.line, lineWidth: 1))
    }
}

private struct RemoteButtonStyle: ButtonStyle {
    var accent = RemotePalette.text
    var filled = false
    var cornerRadius: CGFloat = 16
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(filled ? Color.white : accent)
            .background {
                if filled {
                    shape.fill(LinearGradient(colors: [RemotePalette.primaryTop, RemotePalette.primaryBottom], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(isHovered && isEnabled ? Color.white.opacity(0.14) : RemotePalette.surfaceHigh)
                }
            }
            .overlay(shape.strokeBorder(filled ? .clear : RemotePalette.line, lineWidth: 1))
            .contentShape(shape)
            .brightness(configuration.isPressed && isEnabled ? -0.07 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

@MainActor
struct RemotePanel: View {
    @ObservedObject var store: RemoteStore
    let height: CGFloat
    let onQuit: () -> Void
    @State private var showDirections = false
    @FocusState private var keyboardFocused: Bool
    @State private var showDeveloperConfirmation = false
    @State private var developerModeRequested = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 10) {
                    feedback
                    nowPlaying
                    favorites
                    keyboard
                    volume
                    picture
                    appMenus
                    navigation
                    directionalControls
                    developerMode
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            footer.padding(.horizontal, 18).padding(.vertical, 11)
                .background(RemotePalette.background)
                .overlay(alignment: .top) { Rectangle().fill(RemotePalette.line).frame(height: 1) }
        }
        .frame(width: 360, height: height)
        .background(RemotePalette.background)
        .foregroundStyle(RemotePalette.text)
        .font(.system(size: 12))
        .tint(RemotePalette.accent)
        .preferredColorScheme(.dark)
        .confirmationDialog(developerModeRequested ? "Enable Roku developer mode?" : "Disable Roku developer mode?", isPresented: $showDeveloperConfirmation, titleVisibility: .visible) {
            Button("Open settings on TV") { store.requestDeveloperModeChange(to: developerModeRequested) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This leaves the current TV app and can interrupt AirPlay. Finish the change on the TV; Roku will restart when you confirm it. CouchKeys does not accept terms, set a password, or confirm the restart for you. The switch changes only after the TV reports the new state.")
        }
    }

    private var developerMode: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 9) {
                if let enabled = store.snapshot?.developerEnabled {
                    Toggle(isOn: Binding(get: { enabled }, set: {
                        developerModeRequested = $0
                        showDeveloperConfirmation = true
                    })) {
                        Label("Developer mode", systemImage: "curlybraces")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .toggleStyle(.switch)
                    .disabled(!store.canControl || store.pendingDeveloperMode != nil)
                    .accessibilityLabel("Roku developer mode")
                    .accessibilityValue(store.lastReadFailed ? "Last known \(enabled ? "on" : "off")" : (enabled ? "On" : "Off"))
                    Text(store.lastReadFailed ? "Cached mode; refresh before changing it." : "Verified TV state. Changing it requires on-TV confirmation and a restart. This is not USB/ADB debugging.")
                        .font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Label("Developer mode", systemImage: "curlybraces").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("Unknown").foregroundStyle(RemotePalette.secondary)
                    }
                    Text(store.snapshot?.unavailableReasons["developer_mode"] ?? "Refresh to read the TV’s developer-mode status.")
                        .font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requested = store.pendingDeveloperMode {
                    Text(requested ? "On the TV: enable the installer, accept Roku’s terms, set a password, and allow restart. Keep the password on the TV. Reopen or refresh CouchKeys after the TV returns." : "On the TV: choose Disable installer and restart, then confirm. Reopen or refresh CouchKeys after the TV returns to verify Off.")
                        .font(.system(size: 11)).foregroundStyle(RemotePalette.warm)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { store.stopWaitingForDeveloperMode() } label: {
                        Text("Stop waiting").font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 28)
                    }
                        .buttonStyle(RemoteButtonStyle())
                        .disabled(store.isBusy)
                        .help("Stops monitoring this request; it does not change anything on the TV.")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "house")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(RemotePalette.accent)
                .frame(width: 38, height: 38)
                .background(RemotePalette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("CouchKeys").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusDescription).font(.system(size: 11)).foregroundStyle(RemotePalette.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 2)
            Button { store.setPower(on: store.snapshot?.isPoweredOn != true) } label: {
                Image(systemName: "power").font(.system(size: 17, weight: .regular)).frame(width: 38, height: 38)
            }
            .buttonStyle(RemoteButtonStyle(accent: RemotePalette.secondary, filled: store.snapshot?.isPoweredOn == true, cornerRadius: 19))
            .disabled(store.isBusy || (store.snapshot?.isPoweredOn == true && !store.canControl))
            .accessibilityLabel(store.snapshot?.isPoweredOn == true ? "Turn TV off" : "Turn TV on")
            .help(store.snapshot?.isPoweredOn == true ? "Turn TV off" : "Turn TV on")
            Menu {
                Button("Refresh TV state", systemImage: "arrow.clockwise") { store.refresh() }
                    .disabled(store.isBusy)
                Divider()
                Button("Turn TV on", systemImage: "power") { store.setPower(on: true) }.disabled(store.isBusy)
                Button("Turn TV off", systemImage: "power") { store.setPower(on: false) }.disabled(!store.canControl)
                Button("Send Wake packet", systemImage: "antenna.radiowaves.left.and.right") { store.wake() }.disabled(store.isBusy)
                Divider()
                Text("\(TVTarget.configured.name) · \(TVTarget.configured.host)")
                Button("Quit CouchKeys", action: onQuit).keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Remote options")
        }
    }

    private var statusColor: Color {
        if store.lastReadFailed { return RemotePalette.warm }
        if store.snapshot?.isPoweredOn == true { return RemotePalette.green }
        return RemotePalette.secondary
    }

    private var statusDescription: String {
        if store.lastReadFailed { return "Last read failed · cached state" }
        if store.isRefreshing { return "Reading TV state…" }
        if store.snapshot == nil { return "Not yet connected" }
        if store.snapshot?.networkControl != "enabled" { return "\(store.powerDescription) · control unavailable" }
        return "\(store.powerDescription) · Roku TV"
    }

    @ViewBuilder private var feedback: some View {
        if let operation = store.operationStatus {
            RemoteCard {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(operation).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        if let started = store.operationStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("\(Int(max(0, context.date.timeIntervalSince(started))))s elapsed · power changes may wait 10s")
                                    .font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        if let error = store.errorText {
            message(error, symbol: "exclamationmark.triangle", color: RemotePalette.red)
        } else if let notice = store.notice {
            message(notice, symbol: "info.circle", color: RemotePalette.accent)
        }
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        RemoteCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(.system(size: 11)).lineLimit(5).help(text).accessibilityLabel(text)
                Spacer(minLength: 0)
                Button { store.dismissMessage() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss status message")
            }
        }
    }

    private var nowPlaying: some View {
        RemoteCard {
            HStack(spacing: 12) {
                Image(systemName: store.snapshot?.activeApp?.isInput == true ? "cable.connector" : "tv")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(RemotePalette.warm)
                    .frame(width: 42, height: 42)
                    .background(RemotePalette.warm.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.lastReadFailed ? "LAST KNOWN APP / INPUT" : "CURRENT APP / INPUT")
                        .font(.system(size: 9, weight: .bold)).tracking(1.1)
                        .foregroundStyle(RemotePalette.faint)
                    Text(store.snapshot?.activeApp?.title ?? "No app reported")
                        .font(.system(size: 16.5, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(store.lastReadFailed ? "Cached state" : store.powerDescription)
                            .font(.system(size: 11)).foregroundStyle(RemotePalette.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var favorites: some View {
        HStack(spacing: 9) {
            favorite(id: "12", title: "Netflix", symbol: "n.square", color: RemotePalette.warm)
            favorite(id: "837", title: "YouTube", symbol: "play.rectangle", color: RemotePalette.accent)
        }
    }

    private func favorite(id: String, title: String, symbol: String, color: Color) -> some View {
        let app = store.snapshot?.streamingApps.first { $0.id == id }
        return Button {
            if let app { store.launch(app) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                    .foregroundStyle(color).frame(width: 30, height: 30)
                    .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 50)
        }
        .buttonStyle(RemoteButtonStyle())
        .disabled(app == nil || !store.canControl)
        .accessibilityLabel("Launch \(title)")
        .help(app == nil ? "\(title) is not in the TV’s current app catalog" : "Open \(title)")
    }

    private var keyboard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "keyboard").foregroundStyle(RemotePalette.accent)
                    Text("Keyboard").fontWeight(.semibold)
                }
                .font(.system(size: 13))
                Text("Open Search in Netflix on the TV first. Type or paste here, then press Return to send.")
                    .font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    TextField("Search text…", text: $store.keyboardDraft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keyboardFocused ? RemotePalette.accent : RemotePalette.line, lineWidth: 1))
                        .focused($keyboardFocused)
                        .onSubmit { store.sendKeyboardText() }
                        .disabled(store.snapshot?.canControl != true || store.isMutating)
                        .accessibilityLabel("TV search text")
                    Button { store.sendKeyboardText() } label: {
                        Text("Send").fontWeight(.semibold).frame(width: 52, height: 36)
                    }
                        .buttonStyle(RemoteButtonStyle(filled: true, cornerRadius: 14))
                        .disabled(!store.canControl || store.keyboardDraft.isEmpty)
                        .accessibilityLabel("Send text to TV")
                }
                HStack(spacing: 7) {
                    labeledControl("Delete on TV", symbol: "delete.left", key: .backspace)
                    labeledControl("Enter on TV", symbol: "return", key: .enter)
                }
            }
        }
    }

    private var volume: some View {
        RemoteCard {
            VStack(spacing: 8) {
                HStack {
                    Label("Volume", systemImage: "speaker.wave.2").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(volumeDescription).monospacedDigit().foregroundStyle(RemotePalette.secondary)
                    Button { store.press(.mute) } label: {
                        Image(systemName: store.snapshot?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 29, height: 24)
                    }
                    .buttonStyle(RemoteButtonStyle(accent: store.snapshot?.muted == true ? RemotePalette.warm : RemotePalette.text))
                    .disabled(!store.canControl)
                    .accessibilityLabel(store.snapshot?.muted == true ? "Unmute TV" : "Mute TV")
                    .accessibilityValue(store.snapshot?.muted.map { $0 ? "Muted" : "Not muted" } ?? "Unknown")
                }
                HStack(spacing: 9) {
                    controlButton("Decrease volume", symbol: "minus", key: .volumeDown, width: 28, height: 26)
                    Slider(value: Binding(get: { store.volumeDraft }, set: { store.updateVolumeDraft($0) }), in: 0...100, step: 1, onEditingChanged: store.volumeEditingChanged)
                        .disabled(!store.canSetVolume)
                        .accessibilityLabel("TV volume")
                        .accessibilityValue(store.snapshot?.volume == nil ? "Unknown" : "\(Int(store.volumeDraft)) percent")
                    controlButton("Increase volume", symbol: "plus", key: .volumeUp, width: 28, height: 26)
                }
            }
        }
        .help(store.snapshot?.unavailableReasons["audio"] ?? "Volume is read back from the TV after each change")
    }

    private var volumeDescription: String {
        guard store.snapshot?.volume != nil else { return "—" }
        let level = Int(store.volumeDraft)
        let mute = store.snapshot?.muted == true ? " · muted" : (store.snapshot?.muted == nil ? " · mute —" : "")
        return "\(level)\(mute)"
    }

    private var picture: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Brightness & picture", systemImage: "sun.max").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let state = store.snapshot?.picture, !state.modes.isEmpty {
                        Menu {
                            ForEach(state.modes, id: \.self) { mode in
                                Button {
                                    store.setPicture(name: "picture_mode", value: mode)
                                } label: {
                                    if mode == state.context.mode { Label(PictureState.modeTitle(mode), systemImage: "checkmark") }
                                    else { Text(PictureState.modeTitle(mode)) }
                                }
                            }
                        } label: {
                            Text(state.modeTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(!store.canControl)
                        .accessibilityLabel("Picture mode").accessibilityValue(state.modeTitle)
                    } else {
                        Text("—").foregroundStyle(RemotePalette.secondary)
                    }
                }
                if let state = store.snapshot?.picture, let modes = nonemptyModes(state) {
                    HStack(spacing: 5) {
                        ForEach(modes, id: \.self) { mode in
                            Button { store.setPicture(name: "picture_mode", value: mode) } label: {
                                Text(PictureState.modeTitle(mode)).font(.system(size: 10, weight: .medium))
                                    .lineLimit(1).frame(maxWidth: .infinity).frame(height: 25)
                            }
                            .buttonStyle(RemoteButtonStyle(accent: RemotePalette.secondary, filled: state.context.mode == mode, cornerRadius: 12))
                            .disabled(!store.canControl)
                            .accessibilityLabel("Set picture mode to \(PictureState.modeTitle(mode))")
                            .accessibilityAddTraits(state.context.mode == mode ? .isSelected : [])
                        }
                    }
                }
                if let state = store.snapshot?.picture, let options = state.options["gamma"], !options.isEmpty {
                    HStack {
                        Text("Gamma").font(.system(size: 11)).foregroundStyle(RemotePalette.secondary)
                        Spacer()
                        Menu {
                            ForEach(options, id: \.self) { option in
                                Button { store.setPicture(name: "gamma", value: option) } label: {
                                    if state.settings["gamma"] == option { Label(option, systemImage: "checkmark") }
                                    else { Text(option) }
                                }
                            }
                        } label: { Text(state.settings["gamma"] ?? "—").font(.system(size: 11)).monospacedDigit() }
                        .menuStyle(.borderlessButton).fixedSize().disabled(!store.canControl)
                        .accessibilityLabel("Gamma").accessibilityValue(state.settings["gamma"] ?? "Unknown")
                    }
                }
                Label("Backlight slider unavailable on this Roku firmware.", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.snapshot?.picture == nil, let reason = store.snapshot?.unavailableReasons["picture"] {
                    Text(reason).font(.system(size: 10)).foregroundStyle(RemotePalette.secondary).lineLimit(2).help(reason)
                }
            }
        }
    }

    private func nonemptyModes(_ state: PictureState) -> [String]? {
        let preferred = ["low_power", "normal", "vivid"].filter { state.modes.contains($0) }
        let modes = preferred.isEmpty ? Array(state.modes.prefix(3)) : Array(preferred.prefix(3))
        return modes.isEmpty ? nil : modes
    }

    private var appMenus: some View {
        HStack(spacing: 9) {
            catalogMenu(title: "All apps", symbol: "square.grid.2x2", apps: store.snapshot?.streamingApps ?? [])
            catalogMenu(title: "Inputs", symbol: "cable.connector", apps: store.snapshot?.inputs ?? [])
        }
    }

    private func catalogMenu(title: String, symbol: String, apps: [TVApp]) -> some View {
        Menu {
            if apps.isEmpty {
                Text(store.snapshot?.unavailableReasons["apps"] ?? "No \(title.lowercased()) reported by TV")
            }
            ForEach(apps) { app in
                Button { store.launch(app) } label: {
                    if store.snapshot?.activeApp?.id == app.id { Label(app.title, systemImage: "checkmark") }
                    else { Text(app.title) }
                }
            }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RemotePalette.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RemotePalette.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .disabled(!store.canControl || apps.isEmpty)
        .accessibilityLabel(title == "Inputs" ? "Choose TV input" : "Choose TV app")
        .help(store.snapshot?.unavailableReasons["apps"] ?? (title == "Inputs" ? "Switch the TV input" : "Launch an installed TV app"))
    }

    private var navigation: some View {
        HStack(spacing: 7) {
            labeledControl("Home", symbol: "house", key: .home)
            labeledControl("Back", symbol: "arrow.uturn.backward", key: .back)
            labeledControl("Play / pause", symbol: "playpause", key: .play)
        }
    }

    private var directionalControls: some View {
        DisclosureGroup(isExpanded: $showDirections) {
            VStack(spacing: 6) {
                controlButton("Navigate up", symbol: "chevron.up", key: .up, width: 44)
                HStack(spacing: 7) {
                    controlButton("Navigate left", symbol: "chevron.left", key: .left, width: 44)
                    Button { store.press(.select) } label: {
                        Text("OK").font(.system(size: 12, weight: .semibold)).frame(width: 50, height: 33)
                    }
                        .buttonStyle(RemoteButtonStyle(filled: true))
                        .disabled(!store.canControl).accessibilityLabel("Select TV item")
                    controlButton("Navigate right", symbol: "chevron.right", key: .right, width: 44)
                }
                controlButton("Navigate down", symbol: "chevron.down", key: .down, width: 44)
                HStack(spacing: 7) {
                    labeledControl("Rewind", symbol: "backward.end", key: .rewind)
                    labeledControl("Forward", symbol: "forward.end", key: .forward)
                    labeledControl("Options", symbol: "asterisk", key: .options)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Directional controls", systemImage: "dpad").font(.system(size: 11)).foregroundStyle(RemotePalette.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func labeledControl(_ title: String, symbol: String, key: RemoteKey) -> some View {
        Button { store.press(key) } label: {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 31)
        }
        .buttonStyle(RemoteButtonStyle()).disabled(!store.canControl)
        .accessibilityLabel("TV \(title)")
    }

    private func controlButton(_ title: String, symbol: String, key: RemoteKey, width: CGFloat = 30, height: CGFloat = 30) -> some View {
        Button { store.press(key) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: width, height: height)
        }
        .buttonStyle(RemoteButtonStyle()).disabled(!store.canControl)
        .accessibilityLabel(title).help(title)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let date = store.snapshot?.observedAt {
                Text("\(store.lastReadFailed ? "Cached" : "Last read") \(date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(store.lastReadFailed ? RemotePalette.warm : RemotePalette.faint)
                    .monospacedDigit()
            } else {
                Text("\(TVTarget.configured.host) · local connection").font(.system(size: 10)).foregroundStyle(RemotePalette.secondary)
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing TV state") }
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 23, height: 20) }
                .buttonStyle(.plain).disabled(store.isBusy)
                .accessibilityLabel("Refresh TV state").help("Refresh TV state")
        }
    }
}
