# ScreenGrab

A lightweight screenshot tool for macOS with annotation capabilities, inspired by [ShareX](https://github.com/ShareX/ShareX).

## Demo

![Demo](docs/demo.avif)

## Features

- **Global Hotkey**: `⌘⇧2` to start capture from anywhere
- **Region Selection**: Click and drag to select — screenshot is captured when you release the mouse button
- **Annotations**: Draw rectangles (`R`), arrows (`A`), text (`T`), with customizable colors — or select/move them (`V`)
- **Auto-save & clipboard**: Copies to clipboard and saves to a configurable location (default `~/Pictures/ScreenGrab/`)
- **Preview thumbnail**: macOS-style thumbnail after capture — click to reveal in Finder

## Installation

### Homebrew

```bash
brew install domsleee/tap/screengrab
```

> [!NOTE]
> ScreenGrab is ad-hoc signed and not notarized with Apple (same approach as [AeroSpace](https://github.com/nikitabobko/AeroSpace)). The Homebrew cask automatically strips the quarantine attribute during install so macOS Gatekeeper won't block it. If you download the zip manually from [GitHub Releases](https://github.com/domsleee/ScreenGrab/releases), you'll need to run `xattr -d com.apple.quarantine /Applications/ScreenGrab.app` before launching.

### Build from Source

```bash
xcode-select --install  # if needed
git clone https://github.com/domsleee/ScreenGrab.git
cd ScreenGrab
bash scripts/install.sh  # builds and copies ScreenGrab.app to /Applications
```

## Usage

Launch ScreenGrab — it runs in the background with a menu bar icon. Click the icon to start a capture, open settings, or quit.

On first launch, macOS will ask for **Screen Recording** permission.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧2` | Start capture |
| `R` | Rectangle tool |
| `A` | Arrow tool |
| `T` | Text tool |
| `V` | Select tool |
| `Delete` | Delete selected annotation |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
| `ESC` | Cancel |

## Requirements

- macOS 13.0 (Ventura) or later
- Screen Recording permission

## License

MIT License
