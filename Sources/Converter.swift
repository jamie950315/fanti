import Foundation

/// Simplified Chinese → Traditional Chinese (Taiwan, with Taiwan phrases) using OpenCC's `s2twp` config.
final class Converter: @unchecked Sendable {
    static let shared = Converter()

    private let handle: opencc_t
    private let lock = NSLock()

    private init() {
        guard let config = Bundle.main.url(forResource: "s2twp", withExtension: "json", subdirectory: "dict") else {
            fatalError("s2twp.json is missing from the app bundle")
        }
        let h = opencc_open(config.path)
        if h == nil || Int(bitPattern: h) == -1 {
            fatalError("Failed to open OpenCC: \(String(cString: opencc_error()))")
        }
        handle = h!
    }

    func convert(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return text.withCString { input -> String in
            guard let output = opencc_convert_utf8(handle, input, strlen(input)) else { return text }
            defer { opencc_convert_utf8_free(output) }
            return String(cString: output)
        }
    }
}
