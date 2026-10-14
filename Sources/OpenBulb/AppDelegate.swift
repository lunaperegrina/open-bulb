import AppKit
import Combine
import SwiftUI
import TuyaLocal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let appState = AppState.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 320, height: 640)
        // Drive the popover's size from SwiftUI layout changes (mode switch
        // grows/shrinks the content); otherwise the content gets squeezed
        // into the previous size with no way to see the rest.
        let hostingController = NSHostingController(
            rootView: PopoverRootView().environmentObject(appState))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = BulbIcon.image(for: appState.bulb, connection: appState.connection)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIconIfNeeded()
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []
    private var lastIconSignature = ""

    private func updateIconIfNeeded() {
        let signature = "\(String(describing: appState.bulb))|\(appState.connection)"
        guard signature != lastIconSignature else { return }
        lastIconSignature = signature
        statusItem?.button?.image = BulbIcon.image(for: appState.bulb,
                                                   connection: appState.connection)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            appState.popoverWillShow()
        }
    }

    // MARK: - NSPopoverDelegate

    @objc func popoverWillShow(_ notification: Notification) {
        appState.popoverWillShow()
    }

    @objc func popoverDidClose(_ notification: Notification) {
        appState.popoverDidClose()
    }
}
