# ScreenGrab

A lightweight screenshot tool for macOS with annotation capabilities, inspired by [ShareX](https://github.com/ShareX/ShareX).

## Demo

![Demo](docs/demo.avif)

## Features

- **Global Hotkey**: `⌘⇧2` to start capture from anywhere
- **Region Selection**: Click and drag to select — screenshot is taken on release
- **Annotations**: Draw rectangles (`R`), arrows (`A`), or select/move them (`V`)
- **Auto-save & clipboard**: Copies to clipboard and saves to `~/Pictures/ScreenGrab/`
- **Preview thumbnail**: macOS-style thumbnail after capture — click to reveal in Finder

## Installation

### Homebrew

```bash
brew install domsleee/tap/screengrab
```

> [!NOTE]
> ScreenGrab is ad-hoc signed and not notarized with Apple (same approach as [AeroSpace](https://github.com/nikitabobko/AeroSpace)). The Homebrew cask automatically strips the quarantine attribute during install so macOS Gatekeeper won't block it. If you download the zip manually from GitHub Releases, you'll need to run `xattr -d com.apple.quarantine /Applications/ScreenGrab.app` before launching.

### Build from Source

```bash
xcode-select --install  # if needed
git clone <repo-url>
cd ScreenGrab
bash scripts/install.sh
```

## Usage

Launch ScreenGrab — it runs in the background with a menu bar icon.

On first launch, macOS will ask for **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording).

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧2` | Start capture |
| `R` | Rectangle tool |
| `A` | Arrow tool |
| `V` | Select tool |
| `Delete` | Delete selected annotation |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
| `ESC` | Cancel |

## Requirements

- macOS 13.0 (Ventura) or later
- Screen Recording permission

## License

MIT License
