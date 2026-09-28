import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let convert = Self("convert", initial: .init(.t, modifiers: [.control, .option]))
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let replacer = TextReplacer()
    private var isRunning = false
    private var settingsWindow: NSWindow?

    private let convertItem = NSMenuItem(title: "Convert Selection", action: #selector(convertFromMenu), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Converter.shared  // Load dictionaries up front so the first shortcut press is fast.

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("繁")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(convertItem)
        menu.addItem(NSMenuItem(title: "Convert Clipboard", action: #selector(convertClipboard), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fanti", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        KeyboardShortcuts.onKeyUp(for: .convert) { [weak self] in
            Task { await self?.convert() }
        }

        if !AXIsProcessTrusted() { promptForAccessibility() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        accessibilityItem.title = trusted ? "Accessibility: Granted" : "Grant Accessibility Permission…"
        accessibilityItem.state = trusted ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let shortcut = KeyboardShortcuts.getShortcut(for: .convert) {
            convertItem.title = "Convert Selection (\(shortcut.description))"
        } else {
            convertItem.title = "Convert Selection"
        }
    }

    // MARK: - Actions

    private func convert() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        switch await replacer.run() {
        case .replaced: flash("✓")
        case .copied: flash("⧉")
        case .unchanged: flash("＝")
        case .nothingToConvert, .secureField: NSSound.beep()
        case .notTrusted: promptForAccessibility()
        }
    }

    @objc private func convertFromMenu() {
        // Let the menu close and focus return to the previous app before reading its selection.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await convert()
        }
    }

    @objc private func convertClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        pasteboard.clearContents()
        pasteboard.setString(Converter.shared.convert(text), forType: .string)
        flash("⧉")
    }

    @objc private func openAccessibilitySettings() {
        promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Fanti Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func setIcon(_ title: String) {
        statusItem.button?.title = title
    }

    private func flash(_ symbol: String) {
        setIcon(symbol)
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            setIcon("繁")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Convert shortcut:", name: .convert)
            Text("Converts Simplified Chinese to Traditional Chinese (Taiwan) with OpenCC s2twp.\nIn a text field: replaces the selection, or the whole field when nothing is selected.\nElsewhere: copies the converted selection to the clipboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}
