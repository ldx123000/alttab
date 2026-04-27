//
//  WindowModel.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Window enumeration and MRU (most recently used) tracking. Discovers all
//  user windows via CGWindowListCopyWindowInfo for on-screen windows and
//  AXUIElement queries for minimized windows. Maintains MRU order using
//  NSWorkspace activation notifications and per-app AXObservers that track
//  intra-app focused-window changes (e.g., Cmd-` between two Terminal windows).
//  Uses the private _AXUIElementGetWindow SPI to bridge between AXUIElement
//  and CGWindowID — the standard approach for macOS window managers.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa
import ApplicationServices

// MARK: - WindowInfo

struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String
    let isMinimized: Bool

    /// Returns the app icon for this window's owner process.
    var appIcon: NSImage {
        NSRunningApplication(processIdentifier: ownerPID)?.icon ??
            NSImage(named: NSImage.applicationIconName) ??
            NSImage(size: NSSize(width: 32, height: 32))
    }
}

private struct AXWindowRecord {
    let windowID: CGWindowID
    let title: String
    let isMinimized: Bool
}

// MARK: - WindowModel

final class WindowModel {

    /// MRU-ordered list of window IDs. Front of array = most recently used.
    private var mruOrder: [CGWindowID] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Per-PID AXObservers for intra-app window focus tracking.
    private var axObservers: [pid_t: AXObserver] = [:]

    init() {
        seedMRUFromStackingOrder()
        observeAppActivation()
        observeAppLifecycle()
        installAXObserversForRunningApps()
    }

    deinit {
        removeAllAXObservers()
    }

    // MARK: - Enumerate

    /// Returns all user windows, ordered by MRU.
    func enumerateWindows() -> [WindowInfo] {
        var windows: [WindowInfo] = []
        var seenIDs = Set<CGWindowID>()
        var axCache: [pid_t: [AXWindowRecord]] = [:]

        // 1. On-screen windows from CGWindowList
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] {
            for info in infoList {
                guard let window = parseWindowInfo(info, axCache: &axCache) else { continue }
                if seenIDs.insert(window.windowID).inserted {
                    windows.append(window)
                }
            }
        }

        // 2. Minimized windows via AXUIElement (not in CG list)
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        for app in runningApps {
            for axWindow in axWindows(for: app.processIdentifier, cache: &axCache) where axWindow.isMinimized {
                guard seenIDs.insert(axWindow.windowID).inserted else { continue }

                let windowInfo = WindowInfo(
                    windowID: axWindow.windowID,
                    ownerPID: app.processIdentifier,
                    ownerName: app.localizedName ?? "Unknown",
                    windowTitle: axWindow.title,
                    isMinimized: true
                )
                windows.append(windowInfo)
            }
        }

        // 3. Remove our own windows
        windows.removeAll { $0.ownerName == "AltTab" || $0.ownerPID == ownPID }

        // 4. Sort by MRU
        pruneMRU(validIDs: Set(windows.map { $0.windowID }))
        var mruRank: [CGWindowID: Int] = [:]
        for (index, windowID) in mruOrder.enumerated() where mruRank[windowID] == nil {
            mruRank[windowID] = index
        }
        windows.sort { a, b in
            let idxA = mruRank[a.windowID] ?? Int.max
            let idxB = mruRank[b.windowID] ?? Int.max
            return idxA < idxB
        }

        return windows
    }

    // MARK: - MRU Management

    func promoteToFront(windowID: CGWindowID) {
        guard mruOrder.first != windowID else { return }
        mruOrder.removeAll { $0 == windowID }
        mruOrder.insert(windowID, at: 0)
    }

    private func seedMRUFromStackingOrder() {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return }
        mruOrder = infoList.compactMap { info -> CGWindowID? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 0 && h > 0 else { return nil }
            return id
        }
    }

    private func pruneMRU(validIDs: Set<CGWindowID>) {
        mruOrder.removeAll { !validIDs.contains($0) }
        let knownIDs = Set(mruOrder)
        for id in validIDs where !knownIDs.contains(id) {
            mruOrder.append(id)
        }
    }

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.ownPID else { return }
            self.promoteAppWindows(pid: app.processIdentifier)
        }
    }

    /// When an app is activated, promote its frontmost window in MRU.
    private func promoteAppWindows(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else { return }
        guard let focusedRef = focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
        let focusedWindow = focusedRef as! AXUIElement
        if let windowID = cgWindowID(for: focusedWindow) {
            promoteToFront(windowID: windowID)
        }
    }

    // MARK: - AXObserver (Intra-App Focus Tracking)

    /// Install AXObservers on all currently running regular apps.
    private func installAXObserversForRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        for app in apps {
            installAXObserver(for: app.processIdentifier)
        }
    }

    /// Creates an AXObserver for a single app and watches for focused-window changes.
    private func installAXObserver(for pid: pid_t) {
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let observer = observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let addResult = AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString,
                                                  Unmanaged.passUnretained(self).toOpaque())
        guard addResult == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObservers[pid] = observer
    }

    /// Remove observer for a terminated app.
    private func removeAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeAllAXObservers() {
        for pid in Array(axObservers.keys) {
            removeAXObserver(for: pid)
        }
    }

    /// Called from the AXObserver C callback when any app's focused window changes.
    fileprivate func handleFocusedWindowChanged(_ element: AXUIElement) {
        if let windowID = cgWindowID(for: element) {
            promoteToFront(windowID: windowID)
        }
    }

    /// Watch for app launches and terminations to manage observer lifecycle.
    private func observeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  app.processIdentifier != self.ownPID else { return }
            self.installAXObserver(for: app.processIdentifier)
        }

        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeAXObserver(for: app.processIdentifier)
        }
    }

    // MARK: - Helpers

    private func parseWindowInfo(
        _ info: [String: Any],
        axCache: inout [pid_t: [AXWindowRecord]]
    ) -> WindowInfo? {
        guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              let ownerName = info[kCGWindowOwnerName as String] as? String,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let w = boundsDict["Width"], let h = boundsDict["Height"],
              w > 0 && h > 0 else { return nil }

        // kCGWindowName requires Screen Recording permission. Fall back to
        // AXUIElement title which only needs Accessibility (already granted).
        var title = info[kCGWindowName as String] as? String ?? ""
        if title.isEmpty {
            title = axWindowTitle(for: windowID, pid: ownerPID, cache: &axCache)
        }

        return WindowInfo(
            windowID: windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            windowTitle: title,
            isMinimized: false
        )
    }

    /// Reads the window title via AXUIElement, which only requires Accessibility permission.
    private func axWindowTitle(
        for targetID: CGWindowID,
        pid: pid_t,
        cache: inout [pid_t: [AXWindowRecord]]
    ) -> String {
        axWindows(for: pid, cache: &cache).first { $0.windowID == targetID }?.title ?? ""
    }

    private func axWindows(for pid: pid_t, cache: inout [pid_t: [AXWindowRecord]]) -> [AXWindowRecord] {
        if let cached = cache[pid] {
            return cached
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            cache[pid] = []
            return []
        }

        var records: [AXWindowRecord] = []
        for axWindow in axWindows {
            guard let windowID = cgWindowID(for: axWindow) else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)

            records.append(AXWindowRecord(
                windowID: windowID,
                title: titleRef as? String ?? "",
                isMinimized: minimizedRef as? Bool ?? false
            ))
        }

        cache[pid] = records
        return records
    }
}

func cgWindowID(for element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    _ = _AXUIElementGetWindow(element, &windowID)
    return windowID == 0 ? nil : windowID
}

// Private SPI to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// C callback for AXObserver — bridges to WindowModel.handleFocusedWindowChanged
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let model = Unmanaged<WindowModel>.fromOpaque(userInfo).takeUnretainedValue()
    model.handleFocusedWindowChanged(element)
}
