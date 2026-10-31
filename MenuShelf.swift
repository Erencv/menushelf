import AppKit

/// MenuShelf uses a native separator and an expanding spacer to tuck away
/// status items on the separator's left. macOS doesn't expose a public API for
/// enumerating or directly moving another app's status item.
final class MenuShelf: NSObject, NSApplicationDelegate {
    private let bar = NSStatusBar.system
    private var dividerItem: NSStatusItem!
    private var spacerItem: NSStatusItem!
    private var popover: NSPopover!
    private var isPerformingMenuBarMove = false
    private var outsideClickMonitor: Any?
    // Keys are ".v2" because system icon IDs no longer embed the host
    // process's PID, which changes on every login; pre-v2 entries can never
    // match a scanned icon.
    private let hiddenSystemIconsDefaultsKey = "MenuShelf.hiddenSystemIconIDs.v2"
    private let pinnedIconPreferencesKey = "MenuShelf.pinnedIconPreferences.v2"
    enum VisibilityMode: Equatable {
        case expanded
        case selectedHidden
    }
    private var visibilityMode = VisibilityMode.expanded

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Show macOS's standard Accessibility prompt when trust is missing
        // instead of relying on the user finding the app in System Settings.
        MenuBarIconService.requestAccessibilityAccess()
        // Drop preferences written under pre-v2, PID-keyed system icon IDs.
        UserDefaults.standard.removeObject(forKey: "MenuShelf.hiddenSystemIconIDs")
        UserDefaults.standard.removeObject(forKey: "MenuShelf.pinnedIconPreferences")

        // The visible divider is also the app's control, so the popover anchor
        // cannot drift from a separate status item.
        dividerItem = bar.statusItem(withLength: 20)
        dividerItem.autosaveName = "com.menushelf.divider.v2"
        dividerItem.button?.title = "│"
        dividerItem.button?.toolTip = "MenuShelf — click for controls; ⌘-drag icons across"
        dividerItem.button?.setAccessibilityLabel("MenuShelf divider")
        dividerItem.button?.target = self
        dividerItem.button?.action = #selector(togglePopover)

        // Register the collapse spacer after the clickable divider. On macOS,
        // newer status items are placed toward the left; this keeps MenuShelf's
        // control on the always-visible side while the spacer pushes icons away.
        spacerItem = bar.statusItem(withLength: 0)
        spacerItem.autosaveName = "com.menushelf.spacer.v2"

        popover = NSPopover()
        // Synthetic Command-drag briefly clicks outside the popover. Keep the
        // panel open during that gesture and dismiss it when focus is lost.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 400, height: 590)
        popover.contentViewController = MenuShelfViewController(owner: self)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, !self.isPerformingMenuBarMove else { return }
            let point = NSEvent.mouseLocation
            let popoverFrame = self.popover.contentViewController?.view.window?.frame
            let dividerFrame = self.dividerItem.button.flatMap { button in
                button.window.map { window in
                    window.convertToScreen(button.convert(button.bounds, to: nil))
                }
            }
            if popoverFrame?.contains(point) != true && dividerFrame?.contains(point) != true {
                DispatchQueue.main.async { self.closePopover() }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Start expanded so no icons unexpectedly disappear on launch.
        setMode(.expanded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isPerformingMenuBarMove else { return }
        closePopover()
    }

    @objc func showPopover() {
        guard let button = dividerItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    @objc private func screenConfigurationChanged() {
        switch visibilityMode {
        case .expanded: break
        case .selectedHidden: setMode(.selectedHidden)
        }
    }

    func toggleCollapsed() {
        guard visibilityMode == .expanded else {
            setMode(.expanded)
            return
        }
        moveSystemIconsToVisibleSide(attempt: 0) { [weak self] in
            guard let self else { return }
            let corrections = self.refreshListedIcons().reduce(into: [String: Bool]()) { result, icon in
                guard let frame = icon.frame, self.isOnscreen(frame),
                      self.isAlwaysVisible(icon) != self.isOnShownSide(icon) else { return }
                result[icon.id] = self.isAlwaysVisible(icon)
            }
            self.applyIconChanges(corrections, restoreHidden: false) { [weak self] _ in
                self?.moveNextUncheckedAppIconOffscreen(attempt: 0) { [weak self] in
                    self?.setMode(.selectedHidden)
                }
            }
        }
    }

    /// Apply a group of requested pin states with at most one temporary reveal.
    /// The menu bar has no public API for moving another app's status item, so
    /// each move still uses the native Command-drag gesture while expanded.
    func applyIconChanges(_ changes: [String: Bool], restoreHidden: Bool,
                          completion: @escaping ([String: Bool]) -> Void) {
        guard MenuBarIconService.hasAccessibilityAccess else {
            completion([:])
            return
        }
        let startedHidden = collapsed
        var work = changes
        // Also repair reachable icons whose saved pin choice and real side of
        // the divider disagree; this prevents checked items being left in the
        // tucked zone when the group is collapsed again.
        for icon in refreshListedIcons() {
            guard let frame = icon.frame, isOnscreen(frame) else { continue }
            let actualSide = isOnShownSide(icon)
            let desiredSide = work[icon.id] ?? isAlwaysVisible(icon)
            if desiredSide != actualSide { work[icon.id] = desiredSide }
        }
        isPerformingMenuBarMove = true
        if startedHidden { setMode(.expanded) }
        let orderedIDs = work.keys.sorted { left, right in
            let leftShown = work[left] ?? false
            let rightShown = work[right] ?? false
            if leftShown != rightShown { return !leftShown }
            return left < right
        }
        var results: [String: Bool] = [:]
        func moveNext(_ index: Int) {
            guard index < orderedIDs.count else {
                if startedHidden && restoreHidden { self.setMode(.selectedHidden) }
                self.isPerformingMenuBarMove = false
                completion(results)
                return
            }
            let id = orderedIDs[index]
            self.moveIcon(id, toAlwaysVisible: work[id] ?? false) { moved in
                results[id] = moved
                moveNext(index + 1)
            }
        }
        moveNext(0)
    }

    func refreshIcons() -> [MenuBarIcon] {
        MenuBarIconService.scan()
    }

    func refreshListedIcons() -> [MenuBarIcon] {
        (refreshIcons() + MenuBarIconService.scanSystemIcons()).sorted {
            let left = $0.frame?.midX ?? .greatestFiniteMagnitude
            let right = $1.frame?.midX ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func openAccessibilitySettings() {
        // Open the TCC permission list itself, rather than the general
        // Accessibility features page.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func setPopoverContentSize(_ size: NSSize) {
        popover.contentSize = size
    }

    func isAlwaysVisible(_ icon: MenuBarIcon) -> Bool {
        if let preference = pinnedIconPreferences[icon.id] { return preference }
        return isOnShownSide(icon)
    }

    private var pinnedIconPreferences: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: pinnedIconPreferencesKey) as? [String: Bool] ?? [:]
    }

    private func savePinnedPreference(_ id: String, _ pinned: Bool) {
        var preferences = pinnedIconPreferences
        preferences[id] = pinned
        UserDefaults.standard.set(preferences, forKey: pinnedIconPreferencesKey)
    }

    private func isOnShownSide(_ icon: MenuBarIcon) -> Bool {
        guard let frame = icon.frame, let dividerX = dividerScreenX else { return false }
        return frame.midX > dividerX
    }

    func isIconOnscreen(_ icon: MenuBarIcon) -> Bool {
        guard let frame = icon.frame else { return false }
        return isOnscreen(frame)
    }

    func moveIcon(_ id: String, toAlwaysVisible alwaysVisible: Bool,
                  completion: @escaping (Bool) -> Void) {
        guard MenuBarIconService.hasAccessibilityAccess else {
            completion(false)
            return
        }
        isPerformingMenuBarMove = true
        let previousMode = visibilityMode
        exposeIconForMove(id, previousMode: previousMode) { [weak self] icon, needsRestore in
            guard let self, let icon, let dividerX = self.dividerScreenX else {
                if needsRestore { self?.setMode(previousMode) }
                self?.isPerformingMenuBarMove = false
                completion(false)
                return
            }
            let iconWidth = icon.frame?.width ?? 24
            let destination: CGFloat
            if alwaysVisible {
                let firstShownFrame = self.refreshListedIcons()
                    .filter { $0.id != id && self.isAlwaysVisible($0) }
                    .compactMap(\.frame)
                    .min { $0.minX < $1.minX }
                let beforeFirstShown = (firstShownFrame?.minX ?? (dividerX + iconWidth + 24))
                    - iconWidth / 2 - 4
                destination = max(dividerX + iconWidth / 2 + 12, beforeFirstShown)
            } else {
                destination = (self.hiddenBoundaryScreenX ?? dividerX) - iconWidth / 2 - 12
            }
            let started = MenuBarIconService.move(icon, toX: destination)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { completion(false); return }
                let moved = started
                    && self.refreshListedIcons().first(where: { $0.id == id })
                        .map { self.isOnShownSide($0) == alwaysVisible } == true
                if moved {
                    // Persist only what the menu bar actually accepted, so a
                    // failed drag does not record a state that never happened.
                    self.savePinnedPreference(id, alwaysVisible)
                    if id.hasPrefix("system|") {
                        var hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: self.hiddenSystemIconsDefaultsKey) ?? [])
                        if alwaysVisible { hiddenIDs.remove(id) } else { hiddenIDs.insert(id) }
                        UserDefaults.standard.set(Array(hiddenIDs), forKey: self.hiddenSystemIconsDefaultsKey)
                    }
                }
                if needsRestore { self.setMode(previousMode) }
                // The spacer is zero-width while the item is first dragged.
                // Once restored, its real hidden boundary may be far away;
                // finish the tuck relative to that boundary so the item is
                // not merely left beside the divider (notably for Control Center).
                guard moved, !alwaysVisible,
                      let boundaryX = self.hiddenBoundaryScreenX,
                      let current = self.refreshListedIcons().first(where: { $0.id == id }),
                      let currentX = current.frame?.midX,
                      currentX >= boundaryX - 8 else {
                    self.isPerformingMenuBarMove = false
                    completion(moved)
                    return
                }
                let finished = MenuBarIconService.move(current, toX: boundaryX - 38)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self else { completion(false); return }
                    let finalX = self.refreshListedIcons().first(where: { $0.id == id })?.frame?.midX
                    self.isPerformingMenuBarMove = false
                    completion(finished && (finalX.map { $0 < boundaryX - 8 } ?? false))
                }
            }
        }
    }

    /// Moves an always-visible icon to a zero-based position among the other
    /// always-visible items. The menu bar itself persists the resulting order.
    func reorderVisibleIcon(_ id: String, toIndex requestedIndex: Int,
                            completion: @escaping (Bool) -> Void) {
        guard MenuBarIconService.hasAccessibilityAccess else {
            completion(false)
            return
        }
        isPerformingMenuBarMove = true
        let previousMode = visibilityMode
        exposeIconForMove(id, previousMode: previousMode) { [weak self] icon, needsRestore in
            guard let self, let icon else {
                if needsRestore { self?.setMode(previousMode) }
                self?.isPerformingMenuBarMove = false
                completion(false)
                return
            }
            let visibleIcons = self.refreshListedIcons()
                .filter { self.isAlwaysVisible($0) }
                .sorted { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
            guard let index = visibleIcons.firstIndex(where: { $0.id == id }),
                  icon.frame != nil else {
                if needsRestore { self.setMode(previousMode) }
                self.isPerformingMenuBarMove = false
                completion(false)
                return
            }
            let targetIndex = min(max(requestedIndex, 0), visibleIcons.count - 1)
            guard targetIndex != index else {
                if needsRestore { self.setMode(previousMode) }
                self.isPerformingMenuBarMove = false
                completion(true)
                return
            }
            let neighborIndex = targetIndex
            guard visibleIcons.indices.contains(neighborIndex),
                  let neighborFrame = visibleIcons[neighborIndex].frame else {
                if needsRestore { self.setMode(previousMode) }
                self.isPerformingMenuBarMove = false
                completion(false)
                return
            }
            let targetX = targetIndex < index ? neighborFrame.minX - 3 : neighborFrame.maxX + 3
            let started = MenuBarIconService.move(icon, toX: targetX)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self else { completion(false); return }
                let reordered = self.refreshListedIcons()
                    .filter { self.isAlwaysVisible($0) }
                    .sorted { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
                let newIndex = reordered.firstIndex(where: { $0.id == id })
                let changed = started && newIndex == targetIndex
                if needsRestore { self.setMode(previousMode) }
                self.isPerformingMenuBarMove = false
                completion(changed)
            }
        }
    }

    /// Reveal only enough of the tucked group to reach the requested item.
    /// A zero-width spacer exposes every menu extra, so use the target's AX
    /// frame to reduce the spacer by just the distance needed to bring it
    /// onto the screen. Fall back to a full expansion when macOS does not
    /// update the frame after this targeted reveal. The completion's second
    /// argument reports whether the bar was expanded or the spacer shortened,
    /// so the caller can restore exactly what was changed; moving an already
    /// reachable icon changes nothing and needs no restore.
    private func exposeIconForMove(_ id: String, previousMode: VisibilityMode,
                                   completion: @escaping (MenuBarIcon?, Bool) -> Void) {
        let current = refreshListedIcons().first(where: { $0.id == id })
        let displayBounds = MenuBarIconService.displayBoundsInAXSpace()
        guard previousMode == .selectedHidden,
              let current,
              let frame = current.frame,
              !isOnscreen(frame),
              let screen = displayBounds.first(where: { $0.intersects(frame) })
                ?? displayBounds.first,
              frame.maxX < screen.minX,
              spacerItem.length > 0 else {
            let reachable = current.flatMap { $0.frame.map(isOnscreen) } ?? false
            let expanded = previousMode == .selectedHidden && !reachable
            if expanded { setMode(.expanded) }
            waitForVisibleIcon(id, attempt: 0, previousFrame: nil, stableSamples: 0) { icon in
                completion(icon, expanded)
            }
            return
        }

        let distanceToScreen = screen.minX - frame.maxX + 28
        spacerItem.length = max(0, spacerItem.length - distanceToScreen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { completion(nil, true); return }
            if let revealed = self.refreshListedIcons().first(where: { $0.id == id }),
               self.isIconOnscreen(revealed) {
                self.waitForVisibleIcon(id, attempt: 0, previousFrame: nil,
                                        stableSamples: 0) { icon in
                    completion(icon, true)
                }
            } else {
                self.setMode(.expanded)
                self.waitForVisibleIcon(id, attempt: 0, previousFrame: nil,
                                        stableSamples: 0) { icon in
                    completion(icon, true)
                }
            }
        }
    }

    private func waitForVisibleIcon(_ id: String, attempt: Int, previousFrame: CGRect?,
                                    stableSamples: Int,
                                    completion: @escaping (MenuBarIcon?) -> Void) {
        let icon = refreshListedIcons().first(where: { $0.id == id })
        if attempt >= 14 {
            completion(icon?.frame.map { isOnscreen($0) } == true ? icon : nil)
            return
        }
        guard let icon, let frame = icon.frame, isOnscreen(frame) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.waitForVisibleIcon(id, attempt: attempt + 1, previousFrame: nil,
                                         stableSamples: 0, completion: completion)
            }
            return
        }
        let stable = previousFrame.map {
            abs($0.midX - frame.midX) < 2 && abs($0.midY - frame.midY) < 2
        } == true
        let nextStableSamples = stable ? stableSamples + 1 : 0
        guard nextStableSamples < 2 else { completion(icon); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.waitForVisibleIcon(id, attempt: attempt + 1, previousFrame: frame,
                                     stableSamples: nextStableSamples, completion: completion)
        }
    }

    private func isOnscreen(_ frame: CGRect) -> Bool {
        MenuBarIconService.displayBoundsInAXSpace().contains { $0.intersects(frame) }
    }

    private var dividerScreenX: CGFloat? {
        statusItemScreenX(dividerItem)
    }

    private var hiddenBoundaryScreenX: CGFloat? {
        statusItemScreenX(spacerItem)
    }

    private func statusItemScreenX(_ item: NSStatusItem?) -> CGFloat? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).midX
    }

    private func moveSystemIconsToVisibleSide(attempt: Int, completion: @escaping () -> Void) {
        guard attempt < 20, let dividerX = dividerScreenX else { completion(); return }
        let hiddenSystemIcon = MenuBarIconService.scanSystemIcons()
            .filter {
                let hiddenIDs = UserDefaults.standard.stringArray(forKey: hiddenSystemIconsDefaultsKey) ?? []
                return !hiddenIDs.contains($0.id) && ($0.frame?.midX ?? dividerX) < dividerX - 8
            }
            .max { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
        guard let icon = hiddenSystemIcon else { completion(); return }
        guard MenuBarIconService.move(icon, toX: dividerX + 38) else { completion(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.moveSystemIconsToVisibleSide(attempt: attempt + 1, completion: completion)
        }
    }

    private func moveNextUncheckedAppIconOffscreen(attempt: Int, completion: @escaping () -> Void) {
        guard attempt < 40,
              dividerScreenX != nil,
              let boundaryX = hiddenBoundaryScreenX else { completion(); return }
        let icon = refreshIcons()
            .filter { !isAlwaysVisible($0) && ($0.frame?.midX ?? 0) >= boundaryX - 20 }
            .max { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
        guard let icon else { completion(); return }
        guard MenuBarIconService.move(icon, toX: boundaryX - 42) else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.moveNextUncheckedAppIconOffscreen(attempt: attempt + 1, completion: completion)
        }
    }

    func setMode(_ mode: VisibilityMode) {
        visibilityMode = mode
        // On classic status-item macOS, a full-width spacer is the reliable
        // way to push the hidden zone beyond the display, even with many items.
        // 10,000 pt is AppKit's practical maximum used by established hiders.
        let hiddenWidth: CGFloat = 10_000
        spacerItem.length = mode == .expanded ? 0 : hiddenWidth
        let hidden = mode != .expanded
        dividerItem.button?.toolTip = hidden
            ? "MenuShelf — icons hidden; click for controls"
            : "MenuShelf — click for controls; ⌘-drag icons across"
        NotificationCenter.default.post(name: .menuShelfStateChanged, object: nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    var collapsed: Bool { visibilityMode != .expanded }

    var visibilityDescription: String {
        switch visibilityMode {
        case .expanded: return "All app icons are expanded"
        case .selectedHidden: return "Unchecked icons are tucked away"
        }
    }
}

private extension Notification.Name {
    static let menuShelfStateChanged = Notification.Name("MenuShelfStateChanged")
}

final class MenuShelfViewController: NSViewController {
    private weak var owner: MenuShelf?
    private let titleLabel = NSTextField(labelWithString: "MenuShelf")
    private let stateLabel = NSTextField(labelWithString: "")
    private weak var toggleButton: NSButton?
    private let accessLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private weak var permissionButton: NSButton?
    private weak var refreshButton: NSButton?
    private weak var scrollView: NSScrollView?
    private weak var helpLabel: NSTextField?
    private weak var closeButton: NSButton?
    private weak var quitButton: NSButton?
    private let applyButton = NSButton(title: "Apply changes", target: nil, action: nil)
    private let tableView = NSTableView()
    private var displayedIcons: [MenuBarIcon] = []
    private var visibleIconCount = 0
    private var pendingVisibility: [String: Bool] = [:]
    private var isApplyingPendingChanges = false
    private let iconColumnID = NSUserInterfaceItemIdentifier("MenuShelf.icon")

    init(owner: MenuShelf) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 590))
        titleLabel.font = .boldSystemFont(ofSize: 19)
        titleLabel.frame = NSRect(x: 20, y: 548, width: 340, height: 26)

        stateLabel.frame = NSRect(x: 20, y: 523, width: 350, height: 18)
        stateLabel.textColor = .secondaryLabelColor

        let toggle = makeButton("Hide selected icons", action: #selector(toggleIcons))
        toggle.frame = NSRect(x: 20, y: 474, width: 360, height: 36)
        toggleButton = toggle

        accessLabel.font = .systemFont(ofSize: 11)
        accessLabel.textColor = .secondaryLabelColor
        accessLabel.frame = NSRect(x: 20, y: 430, width: 350, height: 30)

        let permission = makeButton("Grant access in System Settings…", action: #selector(enableIconControls))
        permission.frame = NSRect(x: 20, y: 389, width: 164, height: 30)
        permission.bezelStyle = .rounded
        permissionButton = permission

        let refresh = makeButton("Refresh", action: #selector(refreshIconRows))
        refresh.frame = NSRect(x: 192, y: 389, width: 72, height: 30)
        refresh.bezelStyle = .rounded
        refreshButton = refresh

        applyButton.target = self
        applyButton.action = #selector(applyPendingChanges)
        applyButton.frame = NSRect(x: 272, y: 389, width: 108, height: 30)
        applyButton.bezelStyle = .rounded

        countLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 20, y: 365, width: 350, height: 17)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 97, width: 360, height: 250))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 9
        scroll.layer?.masksToBounds = true
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: iconColumnID))
        tableView.tableColumns.first?.width = 360
        tableView.registerForDraggedTypes([.string])
        scroll.documentView = tableView
        scrollView = scroll

        let help = NSTextField(wrappingLabelWithString: "Checkbox changes are staged. Apply them together; drag checked rows to reorder.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 20, y: 62, width: 360, height: 28)
        helpLabel = help

        let close = makeButton("Close", action: #selector(closePanel))
        close.frame = NSRect(x: 20, y: 8, width: 174, height: 28)
        close.bezelStyle = .accessoryBarAction
        closeButton = close
        let quit = makeButton("Quit MenuShelf", action: #selector(quitApp))
        quit.frame = NSRect(x: 206, y: 8, width: 174, height: 28)
        quit.bezelStyle = .accessoryBarAction
        quitButton = quit

        [titleLabel, stateLabel, toggle, accessLabel, permission, refresh, applyButton,
         countLabel, scroll, help, close, quit].forEach(root.addSubview)
        view = root
        refreshState()
        refreshIconRows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshState),
            name: .menuShelfStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshIconRows()
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func refreshState() {
        stateLabel.stringValue = owner?.collapsed == true
            ? (owner?.visibilityDescription ?? "Icons are tucked away")
            : (owner?.visibilityDescription ?? "All app icons are expanded")
        toggleButton?.title = owner?.collapsed == true
            ? "Expand hidden icons"
            : "Hide unchecked icons"
    }

    @objc private func applicationDidBecomeActive() {
        refreshIconRows()
    }

    private func updatePermissionLayout(isGranted: Bool) {
        // NSViewController.viewIfLoaded is annotated macOS 14+ in the SDK;
        // isViewLoaded has the same no-load semantics since 10.10.
        guard isViewLoaded else { return }
        let root = view
        let permissionRequired = !isGranted
        let height: CGFloat = permissionRequired ? 260 : 590
        root.setFrameSize(NSSize(width: 400, height: height))
        owner?.setPopoverContentSize(NSSize(width: 400, height: height))

        permissionButton?.isHidden = !permissionRequired
        toggleButton?.isHidden = permissionRequired
        stateLabel.isHidden = permissionRequired
        accessLabel.isHidden = permissionRequired
        refreshButton?.isHidden = permissionRequired
        applyButton.isHidden = permissionRequired
        countLabel.isHidden = permissionRequired
        scrollView?.isHidden = permissionRequired
        helpLabel?.isHidden = permissionRequired

        if permissionRequired {
            titleLabel.frame.origin.y = 218
            permissionButton?.title = "Grant access in System Settings…"
            permissionButton?.frame = NSRect(x: 20, y: 126, width: 360, height: 38)
            closeButton?.frame = NSRect(x: 20, y: 12, width: 174, height: 28)
            quitButton?.frame = NSRect(x: 206, y: 12, width: 174, height: 28)
        } else {
            titleLabel.frame.origin.y = 548
            refreshButton?.frame = NSRect(x: 192, y: 389, width: 72, height: 30)
            closeButton?.frame = NSRect(x: 20, y: 8, width: 174, height: 28)
            quitButton?.frame = NSRect(x: 206, y: 8, width: 174, height: 28)
        }
    }

    @objc private func toggleIcons() {
        guard !isApplyingPendingChanges else { return }
        if !pendingVisibility.isEmpty {
            applyQueuedChanges(restoreHidden: owner?.collapsed != true)
        } else {
            owner?.toggleCollapsed()
        }
    }

    @objc private func quitApp() {
        owner?.quit()
    }

    @objc private func closePanel() {
        owner?.closePopover()
    }

    @objc private func enableIconControls() {
        owner?.openAccessibilitySettings()
    }

    @objc private func refreshIconRows() {
        reloadRows(using: nil)
    }

    private func reloadRows(using scannedIcons: [MenuBarIcon]?) {
        guard MenuBarIconService.hasAccessibilityAccess else {
            updatePermissionLayout(isGranted: false)
            accessLabel.stringValue = "Enable Accessibility access to identify app icons by name."
            displayedIcons = []
            visibleIconCount = 0
            tableView.reloadData()
            countLabel.stringValue = "ACCESSIBILITY ACCESS REQUIRED"
            applyButton.isEnabled = false
            return
        }

        updatePermissionLayout(isGranted: true)
        let icons = scannedIcons ?? owner?.refreshListedIcons() ?? []
        let isShown: (MenuBarIcon) -> Bool = { [weak self] icon in
            self?.pendingVisibility[icon.id] ?? self?.owner?.isAlwaysVisible(icon) ?? false
        }
        let visible = icons.filter(isShown)
            .sorted { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
        let hidden = icons.filter { !isShown($0) }
            .sorted { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
        displayedIcons = visible + hidden
        visibleIconCount = visible.count
        let pinnedOverflowCount = visible.filter { owner?.isIconOnscreen($0) != true }.count
        accessLabel.stringValue = !pendingVisibility.isEmpty
            ? "Changes are queued; apply once to move them together."
            : (icons.isEmpty
                ? "No accessible menu bar icons found. Open a menu bar app, then refresh."
                : "Pinned items can still be overflowed by macOS when the menu bar is full.")
        countLabel.stringValue = "\(visible.count) PINNED  ·  \(hidden.count) TUCKED"
        if !pendingVisibility.isEmpty {
            countLabel.stringValue += "  ·  \(pendingVisibility.count) PENDING"
        }
        if pinnedOverflowCount > 0 {
            countLabel.stringValue += "  ·  \(pinnedOverflowCount) OVERFLOWED"
        }
        if icons.isEmpty {
            countLabel.stringValue = "OPEN YOUR MENU BAR APPS, THEN REFRESH"
        }
        applyButton.title = pendingVisibility.isEmpty ? "Apply changes" :
            "Apply \(pendingVisibility.count) \(pendingVisibility.count == 1 ? "change" : "changes")"
        applyButton.isEnabled = !pendingVisibility.isEmpty && !isApplyingPendingChanges
        tableView.reloadData()
    }

    @objc private func iconVisibilityChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        guard !isApplyingPendingChanges else { return }
        let shouldShow = sender.state == .on
        // Keep checkbox interaction predictable in both modes: edits are
        // staged and only touch the menu bar when the user presses Apply.
        // This also avoids trying to drag an item that macOS has overflowed
        // offscreen while the menu bar is crowded.
        let icons = owner?.refreshListedIcons() ?? []
        let baseline = icons.first(where: { $0.id == id })
            .map { owner?.isAlwaysVisible($0) ?? false } ?? false
        if shouldShow == baseline {
            pendingVisibility.removeValue(forKey: id)
        } else {
            pendingVisibility[id] = shouldShow
        }
        reloadRows(using: icons)
    }

    @objc private func applyPendingChanges() {
        applyQueuedChanges(restoreHidden: true)
    }

    private func applyQueuedChanges(restoreHidden: Bool) {
        guard !pendingVisibility.isEmpty, !isApplyingPendingChanges else { return }
        isApplyingPendingChanges = true
        applyButton.isEnabled = false
        tableView.reloadData()
        accessLabel.stringValue = "Applying once; the menu bar will briefly expand to move these icons."
        let queued = pendingVisibility
        owner?.applyIconChanges(queued, restoreHidden: restoreHidden) { [weak self] results in
            guard let self else { return }
            for (id, succeeded) in results where succeeded {
                self.pendingVisibility.removeValue(forKey: id)
            }
            self.isApplyingPendingChanges = false
            let failures = queued.keys.filter { results[$0] != true }
            self.accessLabel.stringValue = failures.isEmpty
                ? "Changes applied."
                : "\(failures.count) move(s) were not accepted; those changes remain queued."
            self.refreshIconRows()
        }
    }
}

extension MenuShelfViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { displayedIcons.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedIcons.indices.contains(row) else { return nil }
        let icon = displayedIcons[row]
        let cell = MenuIconRowView()
        cell.configure(icon: icon, shown: row < visibleIconCount,
                       pending: pendingVisibility[icon.id] != nil,
                       enabled: !isApplyingPendingChanges,
                       onScreen: owner?.isIconOnscreen(icon) == true, target: self,
                       action: #selector(iconVisibilityChanged(_:)))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard pendingVisibility.isEmpty, !isApplyingPendingChanges,
              row < visibleIconCount, displayedIcons.indices.contains(row) else { return nil }
        return displayedIcons[row].id as NSString
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above,
              pendingVisibility.isEmpty,
              !isApplyingPendingChanges,
              let id = info.draggingPasteboard.string(forType: .string),
              let source = displayedIcons.firstIndex(where: { $0.id == id }),
              source < visibleIconCount,
              row >= 0, row <= visibleIconCount else { return [] }
        tableView.setDropRow(min(row, visibleIconCount), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: .string),
              visibleIconCount > 0,
              let source = displayedIcons.firstIndex(where: { $0.id == id }),
              source < visibleIconCount else { return false }
        let destination = min(max(row, 0), visibleIconCount - 1)
        guard source != destination else { return true }
        let moving = displayedIcons.remove(at: source)
        displayedIcons.insert(moving, at: destination)
        tableView.beginUpdates()
        tableView.moveRow(at: source, to: destination)
        tableView.endUpdates()
        owner?.reorderVisibleIcon(id, toIndex: destination) { [weak self] moved in
            self?.accessLabel.stringValue = moved
                ? "Order saved."
                : "macOS did not accept that move; restored the previous order."
            self?.refreshIconRows()
        }
        return true
    }
}

private final class MenuIconRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 5
        iconView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.title = ""
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func configure(icon: MenuBarIcon, shown: Bool, pending: Bool, enabled: Bool, onScreen: Bool,
                   target: AnyObject, action: Selector) {
        iconView.image = icon.iconImage
        titleLabel.stringValue = icon.title
        let state: String
        if pending {
            state = shown ? "Pending · will pin" : "Pending · will tuck"
        } else if shown {
            state = onScreen ? "Pinned · On screen" : "Pinned · Overflowed by macOS"
        } else {
            state = "Tucked when hidden"
        }
        subtitleLabel.stringValue = icon.appName + " · " + state
        checkbox.identifier = NSUserInterfaceItemIdentifier(icon.id)
        checkbox.state = shown ? .on : .off
        checkbox.target = target
        checkbox.action = action
        checkbox.isEnabled = enabled
        checkbox.setAccessibilityLabel("Always show \(icon.title)")
        checkbox.toolTip = icon.frame == nil ? "No position reported" : nil
    }
}

@main
struct MenuShelfMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuShelf()
        app.delegate = delegate
        app.run()
    }
}
