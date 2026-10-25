import Combine
import Foundation

@MainActor
final class RemoteStore: ObservableObject {
    @Published private(set) var snapshot: TVSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var lastReadFailed = false
    @Published private(set) var errorText: String?
    @Published private(set) var notice: String?
    @Published private(set) var operationStatus: String?
    @Published private(set) var operationStartedAt: Date?
    @Published private(set) var volumeDraft = 0.0
    @Published private(set) var isVolumeEditing = false
    @Published var keyboardDraft = ""
    @Published private(set) var pendingDeveloperMode: Bool?

    private let client: TVClient
    private var isVisible = false
    private var isShuttingDown = false
    private var hasVolumeDraft = false
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var volumeCommitTask: Task<Void, Never>?

    init(client: TVClient = TVClient()) {
        self.client = client
    }

    var isBusy: Bool { isRefreshing || isMutating }
    var canControl: Bool { snapshot?.canControl == true && !isBusy && !lastReadFailed }
    var canSetVolume: Bool { canControl && snapshot?.volume != nil }
    var powerDescription: String {
        switch snapshot?.power {
        case "PowerOn": return "TV on"
        case "DisplayOff": return "Display off"
        case .some(let value): return value
        case nil: return "Power —"
        }
    }

    func opened() {
        guard !isShuttingDown else { return }
        isVisible = true
        refresh()
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6)) }
                catch { return }
                guard let self, self.isVisible else { return }
                self.refresh(userInitiated: false)
            }
        }
    }

    func closed() {
        isVisible = false
        periodicTask?.cancel()
        periodicTask = nil
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        cancelVolumeDraft()
    }

    func refresh(userInitiated: Bool = true) {
        guard !isShuttingDown, !isBusy, !isVolumeEditing, !hasVolumeDraft else { return }
        if userInitiated { errorText = nil }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.snapshot()
                guard !Task.isCancelled, generation == self.refreshGeneration else { return }
                self.accept(result)
            } catch {
                guard !Task.isCancelled, generation == self.refreshGeneration else { return }
                self.lastReadFailed = true
                self.errorText = error.localizedDescription
            }
            guard generation == self.refreshGeneration else { return }
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    func press(_ key: RemoteKey) {
        guard canControl else { return }
        perform("Sending \(key.rawValue)…") { try await $0.press(key) }
    }

    func sendKeyboardText() {
        guard canControl, !keyboardDraft.isEmpty else { return }
        let text = keyboardDraft
        keyboardDraft = ""
        perform("Sending keyboard text…", successNotice: "Text sent. Check the TV’s search field; app text is not available for readback.") {
            try await $0.sendText(text)
        }
    }

    func launch(_ app: TVApp) {
        guard canControl, snapshot?.apps.contains(where: { $0.id == app.id }) == true else { return }
        perform("Opening \(app.title) · waiting for TV readback…") { try await $0.launch(appID: app.id) }
    }

    func requestDeveloperModeChange(to enabled: Bool) {
        guard canControl, pendingDeveloperMode == nil, let current = snapshot?.developerEnabled, current != enabled else { return }
        cancelVolumeDraft()
        beginOperation("Sending Roku developer-settings sequence…")
        pendingDeveloperMode = enabled
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.openDeveloperSettings(expectedEnabled: current)
                guard !Task.isCancelled else { return }
                self.accept(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingDeveloperMode = nil
                self.lastReadFailed = true
                self.errorText = error.localizedDescription
            }
            self.endOperation()
        }
    }

    func stopWaitingForDeveloperMode() {
        pendingDeveloperMode = nil
    }

    func setPicture(name: String, value: String) {
        guard canControl, let picture = snapshot?.picture else { return }
        if name == "picture_mode" {
            guard picture.modes.contains(value), value != picture.context.mode else { return }
        } else {
            guard picture.options[name]?.contains(value) == true, picture.settings[name] != value else { return }
        }
        let context = picture.context
        perform("Applying picture setting · reading actual values…") {
            try await $0.setPicture(name: name, value: value, context: context)
        }
    }

    func setPower(on: Bool) {
        guard !isBusy, !isShuttingDown else { return }
        if !on { guard canControl else { return } }
        perform(on ? "Turning TV on · waiting for power readback…" : "Turning TV off · waiting for power readback…") {
            try await $0.setPower(on: on)
        }
    }

    func wake() {
        guard !isBusy, !isShuttingDown else { return }
        cancelVolumeDraft()
        beginOperation("Sending Wake-on-LAN packet…")
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.wake()
                guard !Task.isCancelled else { return }
                self.notice = "Wake packet sent. This does not confirm that the TV is on."
                self.operationStatus = "Wake packet sent · checking TV state…"
                do {
                    let result = try await self.client.snapshot()
                    guard !Task.isCancelled else { return }
                    self.accept(result)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.lastReadFailed = true
                    self.errorText = "Wake packet sent; TV readback failed. \(error.localizedDescription)"
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
            }
            self.endOperation()
        }
    }

    func updateVolumeDraft(_ value: Double) {
        guard canSetVolume else { return }
        volumeDraft = min(100, max(0, value.rounded()))
        hasVolumeDraft = true
        volumeCommitTask?.cancel()
        if !isVolumeEditing {
            volumeCommitTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.commitVolumeDraft()
            }
        }
    }

    func volumeEditingChanged(_ editing: Bool) {
        isVolumeEditing = editing
        volumeCommitTask?.cancel()
        volumeCommitTask = nil
        if !editing { commitVolumeDraft() }
    }

    func dismissMessage() {
        errorText = nil
        notice = nil
    }

    func shutdown() async {
        isShuttingDown = true
        closed()
        mutationTask?.cancel()
        mutationTask = nil
        await client.close()
    }

    private func commitVolumeDraft() {
        volumeCommitTask?.cancel()
        volumeCommitTask = nil
        guard hasVolumeDraft, !isVolumeEditing else { return }
        let value = Int(volumeDraft.rounded())
        hasVolumeDraft = false
        guard canSetVolume, value != snapshot?.volume else { return }
        perform("Setting volume to \(value) · reading actual volume…") { try await $0.setVolume(value) }
    }

    private func cancelVolumeDraft() {
        volumeCommitTask?.cancel()
        volumeCommitTask = nil
        hasVolumeDraft = false
        isVolumeEditing = false
        if let volume = snapshot?.volume { volumeDraft = Double(volume) }
    }

    private func accept(_ result: TVSnapshot) {
        snapshot = result
        lastReadFailed = false
        if let requested = pendingDeveloperMode, result.developerEnabled == requested {
            pendingDeveloperMode = nil
            errorText = nil
            notice = "Roku developer mode \(requested ? "on" : "off") · confirmed by the TV."
        }
        if !isVolumeEditing, !hasVolumeDraft, let volume = result.volume {
            volumeDraft = Double(volume)
        }
    }

    private func perform(_ status: String, successNotice: String? = nil, operation: @escaping @Sendable (TVClient) async throws -> TVSnapshot) {
        guard !isBusy, !isShuttingDown else { return }
        cancelVolumeDraft()
        beginOperation(status)
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await operation(self.client)
                guard !Task.isCancelled else { return }
                self.accept(result)
                if let successNotice { self.notice = successNotice }
            } catch {
                guard !Task.isCancelled else { return }
                self.lastReadFailed = true
                self.errorText = error.localizedDescription
            }
            self.endOperation()
        }
    }

    private func beginOperation(_ status: String) {
        errorText = nil
        notice = nil
        isMutating = true
        operationStatus = status
        operationStartedAt = Date()
    }

    private func endOperation() {
        isMutating = false
        operationStatus = nil
        operationStartedAt = nil
        mutationTask = nil
    }
}
