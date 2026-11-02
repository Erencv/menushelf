<div align="center">
  <img src="Resources/AppIcon.png" width="128" alt="MenuShelf icon">
  <h1>MenuShelf</h1>
  <p>A lightweight, native macOS menu bar utility for choosing which app icons stay visible and collapsing the unchecked group behind a movable divider.</p>
</div>

---

## Features

- Choose which menu bar icons stay visible with per-icon checkboxes; changes are staged and applied together in one pass.
- Collapse the unchecked group to the left side of the menu bar behind a draggable `│` divider.
- Reorder pinned icons by dragging rows in the popover; macOS saves the arrangement.
- No network access, no background services, no telemetry — a single Swift binary.

## Requirements

- macOS 13.0 or later
- Xcode Command Line Tools (`xcode-select --install`) for the Swift compiler
- Accessibility permission, which MenuShelf will prompt for on launch

## Install

With Homebrew:

```sh
brew install --cask Erencv/tap/menushelf
```

Or download `MenuShelf-macOS-universal.zip` from the [latest release](https://github.com/Erencv/menushelf/releases/latest) and drag the app to Applications. The binary is ad-hoc signed, so Gatekeeper blocks manually downloaded copies on recent macOS; clear the quarantine flag once after extracting:

```sh
xattr -dr com.apple.quarantine MenuShelf.app
```

## Build and run

```sh
./build.sh
open build/MenuShelf.app
```

Rebuilding replaces the ad-hoc code signature. macOS ties Accessibility grants to the code signature, so after a rebuild you may need to re-enable MenuShelf under System Settings → Privacy & Security → Accessibility.

MenuShelf opens its controls at launch and has no Dock icon. Click its visible `│` divider to reopen the controls, and use that divider as the boundary:

- In the icon list, turn **Always show** on for icons you want to remain to the divider's right; turn it off to place them in the group hidden on the left. Checkbox changes are staged; choose **Apply changes** to move them together. Unchecked icons remain visible while expanded and are tucked away when you choose **Hide selected icons**.
- Drag checked rows in the icon list to change their left-to-right order on the menu bar. macOS saves the resulting arrangement. Some system controls may not support rearranging. Rows use native system symbols for Apple controls and the owning app's icon for third-party items.
- You can also hold Command and drag app icons across the divider manually.
- Choose **Hide selected icons** to collapse the left group, or **Expand hidden icons** to reveal it.
- Use **Close** to dismiss the controls, or click the divider again to reopen them.
- Choose **Quit MenuShelf** in the popover to quit.

The divider and app positions are saved by macOS. On first launch, icons may need to be moved around the divider once.

## How it works and limitations

macOS exposes menu bar extras through Accessibility, but doesn't provide a supported API for setting their positions. MenuShelf reads the extras from each running app and uses a Command-drag event to move an icon across its divider. This requires Accessibility permission and may not work for an item whose app does not expose a usable position. Manual Command-drag remains available. Native status items and resizable spacers provide the hide and expand controls; they do not stop or modify the apps that own the icons.

macOS can still overflow pinned icons when the menu bar runs out of room. MenuShelf marks those items as overflowed and cannot drag an item that macOS has placed off-screen; tuck another visible icon first to make room.

App-owned extras and Accessibility-visible Apple-managed controls are listed separately. When collapsing, MenuShelf attempts to keep accessible system controls on the visible side of the divider; macOS may not expose every control to Accessibility.

Menu bar managers rely on macOS layout behavior, which can change between system releases. MenuShelf currently targets the classic status-item layout used by macOS 26 and earlier. It needs hands-on compatibility checks on every supported macOS release, including notch and external-display setups.

## Contributing

Issues and pull requests are welcome. Bug reports that name a specific macOS version and hardware setup (notch or external displays, in particular) are especially useful, since menu bar layout behavior changes between releases.

## License

MIT. See [LICENSE](LICENSE).
