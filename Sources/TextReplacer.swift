import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Converts the text the user is working with in the frontmost app.
///
/// - Editable text field: converts the selection, or the whole field when nothing is selected,
///   and replaces it in place. The user's clipboard is restored afterwards.
/// - Selection in non-editable content: the converted text is copied to the clipboard.
@MainActor
final class TextReplacer {
    enum Outcome {
        case replaced
        case copied
        case unchanged
        case nothingToConvert
        case secureField
        case notTrusted
    }

    private let pasteboard = NSPasteboard.general
    /// Chromium apps that are not Electron ignore AXManualAccessibility and expose no focused element.
    /// The only switch they react to is AXEnhancedUserInterface, which puts the app in screen-reader
    /// mode, so these are handled without accessibility information instead.
    private static let opaqueEditorBundleIDs: Set<String> = ["com.openai.codex"]
    /// How long to wait for ⌘C in those apps before concluding nothing is selected. Codex answers a copy
    /// in 20–55 ms and not at all without a selection, so the default 500 ms would be spent on every press.
    private static let opaqueProbeTimeout: Duration = .milliseconds(150)
    /// Apps whose accessibility tree was already requested through AXManualAccessibility.
    private var manualAccessibilityPIDs: Set<pid_t> = []

    func run() async -> Outcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        await waitForModifierKeysUp()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .nothingToConvert
        }

        let focused = await focusedElement(frontmost: app)
        if focused == nil, let bundleID = app.bundleIdentifier, Self.opaqueEditorBundleIDs.contains(bundleID) {
            // Nothing can be read from this app, so treat the focus as a text field and let ⌘C find the selection.
            return await replaceInEditable(axSelection: nil, selectionIsEmpty: false, probeTimeout: Self.opaqueProbeTimeout)
        }
        if let focused, stringAttribute(focused, kAXRoleAttribute) == (kAXTextFieldRole as String),
           stringAttribute(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return .secureField
        }
        let editable = focused.map(isEditable) ?? false
        let axSelection = focused.flatMap { stringAttribute($0, kAXSelectedTextAttribute) }

        if editable {
            let caretOnly = focused.map(hasEmptySelection) ?? false
            return await replaceInEditable(axSelection: axSelection, selectionIsEmpty: caretOnly)
        }
        return await copyConvertedSelection(axSelection: axSelection)
    }

    // MARK: - Modes

    private func replaceInEditable(axSelection: String?, selectionIsEmpty: Bool,
                                   probeTimeout: Duration = .milliseconds(500)) async -> Outcome {
        let saved = PasteboardSnapshot(pasteboard)
        let outcome = await convertEditableContent(axSelection: axSelection, selectionIsEmpty: selectionIsEmpty,
                                                   probeTimeout: probeTimeout)
        // Everything on the pasteboard since the snapshot was written by us; put the user's clipboard back.
        saved.expectedChangeCount = pasteboard.changeCount
        await saved.restore(to: pasteboard)
        return outcome
    }

    private func convertEditableContent(axSelection: String?, selectionIsEmpty: Bool,
                                        probeTimeout: Duration) async -> Outcome {
        var source = axSelection ?? ""
        if source.isEmpty && !selectionIsEmpty {
            // AX could not tell us the selection, so probe with ⌘C. With nothing selected the probe
            // waits for its full timeout, which is why a caret-only selection skips it.
            source = await copySelection(timeout: probeTimeout) ?? ""
        }
        if source.isEmpty {
            // Nothing selected: take the whole field.
            postKey(kVK_ANSI_A, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(60))
            source = await copySelection() ?? ""
        }
        guard !source.isEmpty else { return .nothingToConvert }

        let converted = Converter.shared.convert(source)
        guard converted != source else { return .unchanged }

        writeTransient(converted)
        postKey(kVK_ANSI_V, flags: .maskCommand)
        // Give the target app time to read the pasteboard before it is restored.
        try? await Task.sleep(for: .milliseconds(250))
        return .replaced
    }

    private func copyConvertedSelection(axSelection: String?) async -> Outcome {
        var source = axSelection ?? ""
        if source.isEmpty {
            let saved = PasteboardSnapshot(pasteboard)
            source = await copySelection() ?? ""
            if source.isEmpty {
                saved.expectedChangeCount = pasteboard.changeCount
                await saved.restore(to: pasteboard)
                return .nothingToConvert
            }
        }
        pasteboard.clearContents()
        pasteboard.setString(Converter.shared.convert(source), forType: .string)
        return .copied
    }

    // MARK: - Accessibility helpers

    /// The element with keyboard focus. Asked system-wide rather than of the frontmost app, because
    /// launcher panels (Raycast, Spotlight) take key focus without becoming the frontmost app.
    private func focusedElement(frontmost app: NSRunningApplication) async -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps only expose their accessibility tree after an AX client asks for it.
        let justEnabled = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
            && manualAccessibilityPIDs.insert(app.processIdentifier).inserted

        if let focused: AXUIElement = copyAttribute(systemWide, kAXFocusedUIElementAttribute) { return focused }
        guard justEnabled else { return nil }
        // The tree takes a second or two to build after being switched on.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(50))
            if let focused: AXUIElement = copyAttribute(systemWide, kAXFocusedUIElementAttribute) { return focused }
        }
        return nil
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        // WebKit and Chromium mark inputs and contenteditable regions with an editable ancestor.
        if let _: AXUIElement = copyAttribute(element, "AXEditableAncestor") { return true }
        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String,
            kAXComboBoxRole as String, "AXSearchField",
        ]
        guard let role = stringAttribute(element, kAXRoleAttribute), textRoles.contains(role) else { return false }
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// True when the element reports a zero-length selected text range, i.e. only a caret.
    private func hasEmptySelection(_ element: AXUIElement) -> Bool {
        guard let value: AXValue = copyAttribute(element, kAXSelectedTextRangeAttribute),
              AXValueGetType(value) == .cfRange else { return false }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) && range.length == 0
    }

    /// The shortcut fires on key-up, usually while its modifiers are still physically held, and keystrokes
    /// sent then can arrive with those modifiers added. Our own synthetic ⌘ events leave ⌘ reported as down
    /// until the next physical key event (normally the shortcut itself), hence the 500 ms cap.
    private func waitForModifierKeysUp() async {
        let keys = [kVK_Command, kVK_RightCommand, kVK_Control, kVK_RightControl,
                    kVK_Option, kVK_RightOption, kVK_Shift, kVK_RightShift]
        for _ in 0..<100 {
            if !keys.contains(where: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute)
    }

    // MARK: - Keyboard / pasteboard helpers

    /// Sends ⌘C and returns the copied text, or nil if the pasteboard did not change (nothing selected).
    private func copySelection(timeout: Duration = .milliseconds(500)) async -> String? {
        let before = pasteboard.changeCount
        postKey(kVK_ANSI_C, flags: .maskCommand)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }

    private func writeTransient(_ string: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        // Ask clipboard managers not to record this temporary value (nspasteboard.org convention).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
    }

    private func postKey(_ keyCode: Int, flags: CGEventFlags) {
        // A private event source keeps the physically held shortcut modifiers out of the synthetic event.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Copy of every pasteboard item so the user's clipboard can be put back after a paste-based replacement.
@MainActor
final class PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    /// Only restore if nothing else has written to the pasteboard since this was set.
    var expectedChangeCount: Int

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
        expectedChangeCount = pasteboard.changeCount
    }

    func restore(to pasteboard: NSPasteboard) async {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
