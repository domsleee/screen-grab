# Development

## Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools: `xcode-select --install`

## Build & Run

```bash
bash scripts/install.sh   # builds, signs, copies to /Applications
open /Applications/ScreenGrab.app
```

The build script (`scripts/build.sh`) accepts flags:

| Flag | Description |
|------|-------------|
| `--universal` | Build universal binary (arm64 + x86_64) |
| `--sign <identity>` | Code-signing identity (default: `ScreenGrab Dev`) |
| `--version <ver>` | Set version for release builds |

## Self-Signed Certificate

Dev builds are signed with a self-signed certificate called **"ScreenGrab Dev"**. Without it, macOS will show a security prompt every time you rebuild and launch the app (because the code signature changes on each build).

### Creating the certificate

1. Open **Keychain Access** (Spotlight → "Keychain Access")
2. Menu bar → **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name**: `ScreenGrab Dev`
   - **Identity Type**: Self-Signed Root
   - **Certificate Type**: Code Signing
4. Click **Create**

The certificate appears in your **login** keychain. The build script will now find it automatically.

### Trusting the certificate

The first time you run an app signed with the new certificate, macOS may still prompt you. To avoid this:

1. In **Keychain Access**, double-click the **ScreenGrab Dev** certificate
2. Expand the **Trust** section
3. Set **Code Signing** to **Always Trust**
4. Close the dialog and enter your password to confirm

After this, rebuilds will launch without security prompts.

### Verifying

```bash
# Check the certificate exists
security find-identity -v -p codesigning | grep "ScreenGrab Dev"

# Check the app is signed correctly
codesign -dvvv /Applications/ScreenGrab.app 2>&1 | grep Authority
```

## Dev vs Release Builds

| | Dev build (default) | Release build (`--version`) |
|---|---|---|
| Bundle ID | `com.screengrab.app.dev` | `com.screengrab.app` |
| App name | ScreenGrab Dev | ScreenGrab |
| Signing | Self-signed, no hardened runtime | Hardened runtime (for notarization) |

Dev builds use a separate bundle ID so macOS doesn't confuse permissions between your development copy and an installed release.
