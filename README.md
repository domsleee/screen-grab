# ShareX Mac

A lightweight screenshot tool for macOS with annotation capabilities, inspired by [ShareX](https://github.com/ShareX/ShareX).

## Features

- **Global Hotkey**: Press `⌘⇧2` (Cmd+Shift+2) to start capture from anywhere
- **Region Selection**: Click and drag to select any region of your screen
- **Annotation Tools**:
  - **Rectangle** (press `R`): Draw red rectangles to highlight areas
  - **Arrow** (press `A`): Draw red arrows to point at things
  - **Select** (press `V`): Move and resize annotations
- **Auto-copy**: Automatically copies the annotated image to clipboard

## Installation

### Build from Source

1. Make sure you have Xcode command line tools installed:
   ```bash
   xcode-select --install
   ```

2. Clone and build:
   ```bash
   git clone <repo-url>
   cd sharex-mac
   swift build -c release
   ```

3. The built app will be at `.build/release/ShareXMac`

### Running the App

> ⚠️ **Note**: `swift run` doesn't work well with this app because it requires proper Application context for menu bar items and global hotkeys.

**Recommended way to run:**

```bash
# Build and run directly
swift build && .build/debug/ShareXMac

# Or for release build
swift build -c release && .build/release/ShareXMac
```

The app runs in the background with a menu bar icon. To quit, click the menu bar icon and select "Quit" or press `⌘Q`.

### First Run

On first launch, macOS will ask for **Screen Recording** permission. Grant this in System Settings → Privacy & Security → Screen Recording.

## Usage

1. **Start the app** - It runs in the background with a menu bar icon (camera viewfinder)
2. **Press ⌘⇧2** to start capturing (or click the menu bar icon)
3. **Drag to select** the region you want to capture
4. **Annotate** your screenshot:
   - Press `R` for rectangle tool, click and drag to draw
   - Press `A` for arrow tool, click and drag to draw
   - Press `V` for select tool, click annotations to move/resize them
   - Press `Delete` to remove selected annotation
5. **Press Enter or ⌘C** to copy to clipboard (or click the Copy button)
6. **Press ESC** to cancel at any time

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧2` | Start capture |
| `R` | Rectangle tool |
| `A` | Arrow tool |
| `V` | Select tool |
| `Delete` | Delete selected annotation |
| `Enter` / `⌘C` | Copy and close |
| `ESC` | Cancel |

## Requirements

- macOS 13.0 (Ventura) or later
- Screen Recording permission

## License

MIT License
