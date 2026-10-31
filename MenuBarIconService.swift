import AppKit
import ApplicationServices
import Darwin

struct MenuBarIcon {
    let id: String
    let appName: String
    let title: String
    let frame: CGRect?
    let element: AXUIElement
    let iconImage: NSImage?
}

enum MenuBarIconService {
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    /// Per-element AX messaging cap so a hung process cannot stall a scan for
    /// the systemwide default of six seconds per call.
    private static let messagingTimeout: Float = 2.0

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func scan() -> [MenuBarIcon] {
        guard hasAccessibilityAccess else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var results: [MenuBarIcon] = []
        let systemMenuBarHosts: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.dock"
        ]
        // One pass over the process table up front; matching helpers per app
        // is then dictionary lookups instead of a proc_pidpath call for every
        // running process per application.
        let pidPaths = pidExecutablePaths()
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ownPID,
                  let appID = app.bundleIdentifier,
                  !systemMenuBarHosts.contains(appID) else { continue }
            let appName = app.localizedName ?? appID
            // Some apps host their status item in an embedded helper process
            // instead of the main application process (ChatGPT is one example).
            // Treat those helpers as part of the owning app so their item is
            // still controllable from the same row in MenuShelf.
            let appProcessIDs = helperProcessIDs(for: app, pidPaths: pidPaths)
            var ownedItemIndex = 0
            var titleOccurrences: [String: Int] = [:]
            var seenItems = Set<String>()
            for processPID in appProcessIDs.sorted() {
                let root = AXUIElementCreateApplication(processPID)
                AXUIElementSetMessagingTimeout(root, messagingTimeout)
                let itemElements: [AXUIElement]
                let isExtrasContainer: Bool
                if let rawExtras = copyValue(root, kAXExtrasMenuBarAttribute as String),
                   let extras = axElement(rawExtras),
                   let children = copyValue(extras, kAXChildrenAttribute as String) as? [AXUIElement] {
                    itemElements = children
                    isExtrasContainer = true
                } else if let rootChildren = copyValue(root, kAXChildrenAttribute as String) as? [AXUIElement] {
                    // Legacy accessibility tree used by some menu bar apps and
                    // earlier macOS releases. Only direct AXMenuExtra children
                    // are extras; AXMenuBarItem children belong to app menus.
                    itemElements = rootChildren.filter {
                        stringValue($0, kAXRoleAttribute as String) == "AXMenuExtra"
                    }
                    isExtrasContainer = false
                } else {
                    continue
                }

                for element in itemElements {
                    // The extras container can surface system items too. Keep
                    // only elements owned by this app or its embedded helpers.
                    var elementPID: pid_t = 0
                    guard AXUIElementGetPid(element, &elementPID) == .success,
                          appProcessIDs.contains(elementPID) else { continue }
                    let role = stringValue(element, kAXRoleAttribute as String) ?? ""
                    let supportedRole = role == (kAXMenuBarItemRole as String) || role == "AXMenuExtra"
                    guard supportedRole && (isExtrasContainer || role == "AXMenuExtra") else {
                        continue
                    }
                    let label = stringValue(element, kAXTitleAttribute as String)
                        ?? stringValue(element, kAXDescriptionAttribute as String)
                        ?? stringValue(element, kAXHelpAttribute as String)
                        ?? stringValue(element, kAXIdentifierAttribute as String)
                    let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stableIdentifier = (stringValue(element, kAXIdentifierAttribute as String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let frame = frameValue(element)
                    let frameKey = frame.map { "\(Int($0.midX.rounded()))|\(Int($0.midY.rounded()))" } ?? "no-frame"
                    let dedupeKey = "\(elementPID)|\(stableIdentifier)|\(normalizedLabel)|\(frameKey)"
                    guard seenItems.insert(dedupeKey).inserted else { continue }

                    let base = normalizedLabel.isEmpty ? "Icon \(ownedItemIndex + 1)" : normalizedLabel
                    // AX children can change order after a Command-drag. An
                    // index fallback therefore makes preferences jump to a
                    // different icon. Prefer title-derived identity.
                    let identity: String
                    if !stableIdentifier.isEmpty {
                        identity = "identifier:\(stableIdentifier)"
                    } else if !normalizedLabel.isEmpty {
                        let occurrence = titleOccurrences[normalizedLabel, default: 0]
                        titleOccurrences[normalizedLabel] = occurrence + 1
                        identity = "title:\(normalizedLabel)|\(occurrence)"
                    } else {
                        identity = "item:\(ownedItemIndex)"
                    }
                    ownedItemIndex += 1
                    results.append(MenuBarIcon(
                        id: "\(appID)|\(identity)",
                        appName: appName,
                        title: base,
                        frame: frame,
                        element: element,
                        iconImage: app.icon
                    ))
                }
            }
        }
        return results.sorted {
            let left = $0.frame?.midX ?? .greatestFiniteMagnitude
            let right = $1.frame?.midX ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            if $0.appName != $1.appName { return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// System extras are scanned separately so collapsing app icons can keep
    /// Apple-owned controls on the visible side of the divider.
    static func scanSystemIcons() -> [MenuBarIcon] {
        guard hasAccessibilityAccess else { return [] }
        let systemHosts: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        let applications = NSWorkspace.shared.runningApplications
        let hostNames = Dictionary(uniqueKeysWithValues: applications.compactMap { app -> (pid_t, String)? in
            guard let bundleID = app.bundleIdentifier, systemHosts.contains(bundleID) else { return nil }
            return (app.processIdentifier, app.localizedName ?? "macOS")
        })
        guard !hostNames.isEmpty else { return [] }
        // Host-owned extras normally sit in their host's own container, but a
        // host's items can also be surfaced through another container (the
        // Dock has done this for legacy extras). Only these few bundles can
        // hold system items, so skip every other running application.
        let containerHosts = systemHosts.union(["com.apple.dock"])
        var results: [MenuBarIcon] = []
        for sourceApp in applications where sourceApp.bundleIdentifier.map(containerHosts.contains) == true {
            let root = AXUIElementCreateApplication(sourceApp.processIdentifier)
            AXUIElementSetMessagingTimeout(root, messagingTimeout)
            let children: [AXUIElement]
            if let rawExtras = copyValue(root, kAXExtrasMenuBarAttribute as String),
               let extras = axElement(rawExtras),
               let extrasChildren = copyValue(extras, kAXChildrenAttribute as String) as? [AXUIElement] {
                children = extrasChildren
            } else if let rootChildren = copyValue(root, kAXChildrenAttribute as String) as? [AXUIElement] {
                children = rootChildren.filter {
                    stringValue($0, kAXRoleAttribute as String) == "AXMenuExtra"
                }
            } else {
                continue
            }
            var occurrences: [String: Int] = [:]
            for element in children {
                var ownerPID: pid_t = 0
                guard AXUIElementGetPid(element, &ownerPID) == .success,
                      let appName = hostNames[ownerPID] else { continue }
                let role = stringValue(element, kAXRoleAttribute as String) ?? ""
                guard role == (kAXMenuBarItemRole as String) || role == "AXMenuExtra",
                      let frame = frameValue(element), frame.width > 0, frame.height > 0 else { continue }
                let label = stringValue(element, kAXTitleAttribute as String)
                    ?? stringValue(element, kAXDescriptionAttribute as String)
                    ?? stringValue(element, kAXHelpAttribute as String)
                let title = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let occurrence = occurrences[title, default: 0]
                occurrences[title] = occurrence + 1
                let identifier = (stringValue(element, kAXIdentifierAttribute as String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stablePart = identifier.isEmpty ? "\(title)|\(occurrence)" : identifier
                results.append(MenuBarIcon(
                    // PID-free so preferences survive the host process
                    // getting a new identity on every login.
                    id: "system|\(stablePart)",
                    appName: appName,
                    title: title.isEmpty ? "System item \(occurrence + 1)" : title,
                    frame: frame,
                    element: element,
                    iconImage: systemIconImage(for: title)
                ))
            }
        }
        // A system extra may be surfaced by both hosts. Avoid trying to drag
        // the same onscreen control twice.
        var seen = Set<String>()
        return results.filter { icon in
            guard let frame = icon.frame else { return false }
            let key = "\(Int(frame.midX.rounded()))|\(Int(frame.midY.rounded()))|\(icon.title)"
            return seen.insert(key).inserted
        }
    }

    private static func systemIconImage(for title: String) -> NSImage? {
        let value = title.lowercased()
        let symbol: String
        if value.contains("battery") { symbol = "battery.100percent" }
        else if value.contains("wi-fi") || value.contains("wifi") { symbol = "wifi" }
        else if value.contains("sound") || value.contains("volume") { symbol = "speaker.wave.2" }
        else if value.contains("clock") || value.contains("date") { symbol = "clock" }
        else if value.contains("now playing") || value.contains("play") { symbol = "play.circle" }
        else if value.contains("control center") { symbol = "switch.2" }
        else { symbol = "menubar.dock.rectangle" }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }

    /// Maps every running PID to its executable path, growing the process
    /// table buffer until `proc_listpids` reports it held the complete list.
    private static func pidExecutablePaths() -> [pid_t: String] {
        let stride = MemoryLayout<pid_t>.stride
        var capacity = 4096
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                              Int32(buffer.count * stride))
            }
            guard byteCount > 0 else { return [:] }
            let count = min(pids.count, Int(byteCount) / stride)
            if count < pids.count || capacity >= 65_536 {
                var paths: [pid_t: String] = [:]
                paths.reserveCapacity(count)
                for pid in pids.prefix(count) where pid > 0 {
                    var pathBuffer = [CChar](repeating: 0, count: 4096)
                    let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
                    }
                    guard pathLength > 0 else { continue }
                    paths[pid] = String(cString: pathBuffer)
                }
                return paths
            }
            capacity *= 2
        }
    }

    /// PIDs whose executable lives inside the app's bundle: the app itself
    /// plus any embedded helpers that host its status item.
    private static func helperProcessIDs(for app: NSRunningApplication,
                                         pidPaths: [pid_t: String]) -> Set<pid_t> {
        var result: Set<pid_t> = [app.processIdentifier]
        guard let bundleURL = app.bundleURL else { return result }
        let bundlePath = bundleURL.standardizedFileURL.path + "/"
        for (pid, path) in pidPaths where pid != app.processIdentifier && path.hasPrefix(bundlePath) {
            result.insert(pid)
        }
        return result
    }

    /// Bounds of every active display in the top-left-origin global space that
    /// AX frames and CGEvents share. NSScreen frames use a bottom-left origin
    /// and must not be compared against AX geometry directly.
    static func displayBoundsInAXSpace() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            let bounds = CGDisplayBounds(displayID)
            return bounds.isNull ? nil : bounds
        }
    }

    /// Status item AXPosition is read-only, so moving one uses the same
    /// Command-drag gesture a person uses to reorder menu bar icons.
    static func move(_ icon: MenuBarIcon, toX destinationX: CGFloat) -> Bool {
        guard hasAccessibilityAccess, let frame = icon.frame,
              frame.width > 0, frame.height > 0,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let start = CGPoint(x: frame.midX, y: frame.midY)
        let originalCursor = CGEvent(source: nil)?.location
        defer {
            if let originalCursor {
                CGWarpMouseCursorPosition(originalCursor)
            }
        }
        guard displayBoundsInAXSpace().contains(where: { $0.insetBy(dx: -4, dy: -4).contains(start) }) else {
            return false
        }

        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: start, mouseButton: .left)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        for step in 1...6 {
            let fraction = CGFloat(step) / 6
            let point = CGPoint(x: start.x + (destinationX - start.x) * fraction, y: start.y)
            let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                               mouseCursorPosition: point, mouseButton: .left)
            drag?.flags = .maskCommand
            drag?.post(tap: .cghidEventTap)
            usleep(8_000)
        }

        let end = CGPoint(x: destinationX, y: start.y)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: end, mouseButton: .left)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        return true
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func frameValue(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = copyValue(element, kAXPositionAttribute as String),
              let rawSize = copyValue(element, kAXSizeAttribute as String),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(rawPosition, to: AXValue.self)
        let size = unsafeBitCast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func axElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
