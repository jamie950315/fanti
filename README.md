# Fanti

繁體中文 | [English](README.en.md)

一個 macOS 選單列 app，按下快速鍵就能把簡體中文轉換成臺灣正體中文。
轉換引擎使用 [OpenCC](https://github.com/BYVoid/OpenCC) 1.4.2 的 `s2twp` 設定，
除了轉成臺灣標準字形，也會換成臺灣慣用詞，例如：软件 → 軟體、内存 → 記憶體、鼠标 → 滑鼠。

## 使用方式

按下快速鍵（預設 **⌃⌥T**，可在「設定⋯」中修改）：

| 目前位置 | 結果 |
| --- | --- |
| 輸入框中有選取文字 | 以轉換後的文字取代選取內容 |
| 輸入框中沒有選取文字 | 直接轉換整個輸入框的內容 |
| 在不可編輯的內容中選取文字（網頁、PDF、標籤等） | 將轉換後的文字複製到剪貼簿 |
| 密碼欄位，或沒有選取任何文字 | 發出提示音，不做任何變更 |

在輸入框中取代文字時，app 會透過剪貼簿貼上，完成後再還原您原本的剪貼簿內容。
選單列圖示（斜切成「简」與「繁」兩半的方塊）會短暫顯示勾號（已取代）、複製圖示（已複製）或等號（原本就是繁體）。
選單中另有「轉換剪貼簿內容」、「登入時啟動」與「設定⋯」（修改快速鍵）。

## 安裝

從 [最新版本](https://github.com/jamie950315/fanti/releases/latest) 下載 `Fanti.zip`，解壓縮後將 `Fanti.app` 移到「應用程式」資料夾。

此版本使用 Apple Development 憑證簽署，但未經 Apple 公證，因此第一次開啟會被 Gatekeeper 擋下。
請到「系統設定 → 隱私權與安全性」點選「強制打開」，或執行：

```bash
xattr -dr com.apple.quarantine /Applications/Fanti.app
```

## 系統需求

- macOS 14 以上
- 輔助使用權限（系統設定 → 隱私權與安全性 → 輔助使用 → Fanti）。app 需要此權限來讀取目前聚焦的輸入框，並送出 ⌘A／⌘C／⌘V。

## 自行建置

```bash
./scripts/build-opencc.sh   # 將 OpenCC 靜態函式庫（universal）與字典建置到 Vendor/opencc
xcodegen generate
xcodebuild -project Fanti.xcodeproj -scheme Fanti -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/Fanti.app /Applications/
```

需要 Xcode、CMake、Ninja 與 XcodeGen（`brew install cmake ninja xcodegen`）。

## 授權

採用 MIT 授權，詳見 [LICENSE](LICENSE)。內含的第三方軟體（以 Apache-2.0 授權的 OpenCC 及其字典、marisa-trie、darts-clone、RapidJSON、KeyboardShortcuts）列於 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)，此檔案也一併包含在 app 中。
