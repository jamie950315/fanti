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

    func run() async -> Outcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        await waitForModifierRelease()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .nothingToConvert
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium apps only expose their accessibility tree after an AX client asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let focused: AXUIElement? = copyAttribute(appElement, kAXFocusedUIElementAttribute)
        if let focused, stringAttribute(focused, kAXRoleAttribute) == (kAXTextFieldRole as String),
           stringAttribute(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return .secureField
        }
        let editable = focused.map(isEditable) ?? false
        let axSelection = focused.flatMap { stringAttribute($0, kAXSelectedTextAttribute) }

        if editable {
            let selectionIsEmpty = focused.map(hasEmptySelection) ?? false
            return await replaceInEditable(axSelection: axSelection, selectionIsEmpty: selectionIsEmpty)
        }
        return await copyConvertedSelection(axSelection: axSelection)
    }

    // MARK: - Modes

    private func replaceInEditable(axSelection: String?, selectionIsEmpty: Bool) async -> Outcome {
        let saved = PasteboardSnapshot(pasteboard)
        let outcome = await convertEditableContent(axSelection: axSelection, selectionIsEmpty: selectionIsEmpty)
        // Everything on the pasteboard since the snapshot was written by us; put the user's clipboard back.
        saved.expectedChangeCount = pasteboard.changeCount
        await saved.restore(to: pasteboard)
        return outcome
    }

    private func convertEditableContent(axSelection: String?, selectionIsEmpty: Bool) async -> Outcome {
        var source = axSelection ?? ""
        if source.isEmpty && !selectionIsEmpty {
            // Accessibility could not tell us the selection; probe with ⌘C. When nothing is selected
            // this waits for its full timeout, so it is skipped whenever AX reports an empty selection.
            source = await copySelection() ?? ""
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

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute)
    }

    // MARK: - Keyboard / pasteboard helpers

    /// The shortcut fires on key-up, usually while its modifiers are still held. Chromium-based apps
    /// read the live modifier state, so a synthetic ⌘A sent then arrives as e.g. ⌃⌥⌘A and does nothing.
    private func waitForModifierRelease() async {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<200 {
            if CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Sends ⌘C and returns the copied text, or nil if the pasteboard did not change (nothing selected).
    private func copySelection() async -> String? {
        let before = pasteboard.changeCount
        postKey(kVK_ANSI_C, flags: .maskCommand)
        for _ in 0..<50 {
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
