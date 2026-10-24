import AppKit
import SwiftUI

@MainActor
final class RemoteApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = RemoteStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "tv", accessibilityDescription: "CouchKeys")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "CouchKeys"
            button.setAccessibilityLabel("CouchKeys")
            button.setAccessibilityIdentifier("CouchKeysStatusItem")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if !CommandLine.arguments.contains("--background") {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.showPopover()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) }
        else { showPopover() }
    }

    private func showPopover() {
        guard !isTerminating, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let screen = button.window?.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.height ?? 800) - 45
        let panelHeight = max(300, min(680, availableHeight))
        let panel = RemotePanel(store: store, height: panelHeight) {
            NSApp.terminate(nil)
        }
        let controller = NSHostingController(rootView: panel)
        controller.preferredContentSize = NSSize(width: 360, height: panelHeight)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: panelHeight)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        store.opened()
    }

    func popoverDidClose(_ notification: Notification) {
        store.closed()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        popover.performClose(nil)
        Task { @MainActor in
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let application = NSApplication.shared
let applicationDelegate = RemoteApplicationDelegate()
application.delegate = applicationDelegate
application.run()
