# TWConvert

A macOS menu bar app that converts Simplified Chinese to Traditional Chinese (Taiwan) with a global shortcut.
Conversion uses [OpenCC](https://github.com/BYVoid/OpenCC) 1.4.2 with the `s2twp` config
(Taiwan standard characters plus Taiwan phrases, e.g. 软件 → 軟體, 内存 → 記憶體, 鼠标 → 滑鼠).

## Behavior

Press the shortcut (default **⌃⌥T**, changeable in Settings):

| Where the focus is | Result |
| --- | --- |
| Text field with a selection | The selection is replaced with the converted text |
| Text field without a selection | The whole field is converted in place |
| Selected text in non-editable content (web page, PDF, label…) | Converted text is copied to the clipboard |
| Password field / nothing selected | Beep, nothing changes |

When replacing inside a text field the app pastes through the clipboard and restores the previous clipboard contents afterwards.
The menu bar icon briefly shows ✓ (replaced), ⧉ (copied) or ＝ (already Traditional).
The menu also has **Convert Clipboard**, **Launch at Login**, and **Settings…** (shortcut recorder).

## Requirements

- macOS 14+
- Accessibility permission (System Settings → Privacy & Security → Accessibility → TWConvert). It is needed to read the focused element and to send ⌘A/⌘C/⌘V.

## Build

```bash
./scripts/build-opencc.sh   # builds static universal OpenCC + dictionaries into Vendor/opencc
xcodegen generate
xcodebuild -project TWConvert.xcodeproj -scheme TWConvert -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/TWConvert.app /Applications/
```

Requires Xcode, CMake, Ninja and XcodeGen (`brew install cmake ninja xcodegen`).

## License notes

OpenCC and its dictionaries are Apache-2.0. KeyboardShortcuts is MIT.
