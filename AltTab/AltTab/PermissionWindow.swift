//
//  PermissionWindow.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  First-run Accessibility permission guide. This mirrors the user-facing
//  flow of mature macOS utilities: show a clear app-owned window, provide a
//  native Accessibility permission prompt, and keep polling until permission
//  is granted.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa

final class PermissionWindow: NSWindow, NSWindowDelegate {

    private let onRequestPermission: () -> Void
    private let statusLabel = NSTextField(labelWithString: "")
    private let cardView = NSView()
    private var permissionGranted = false
    private var isTerminating = false

    init(onRequestPermission: @escaping () -> Void) {
        self.onRequestPermission = onRequestPermission
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "AltTab needs Accessibility permission"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self
        setupContent()
    }

    func show() {
        guard !isVisible else {
            makeKeyAndOrderFront(nil)
            return
        }
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func updatePermissionStatus(isTrusted: Bool) {
        permissionGranted = isTrusted
        let color = isTrusted
            ? NSColor.systemGreen.withAlphaComponent(0.18)
            : NSColor.systemRed.withAlphaComponent(0.14)
        cardView.layer?.backgroundColor = color.cgColor
        statusLabel.textColor = isTrusted ? .systemGreen : .systemRed
        statusLabel.stringValue = isTrusted ? "Allowed" : "Not allowed"
    }

    func closeAfterPermissionGranted() {
        permissionGranted = true
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isTerminating {
            return true
        }
        if !permissionGranted && !AXIsProcessTrusted() {
            isTerminating = true
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    private func setupContent() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView = content

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        root.addArrangedSubview(makeHeader())
        root.addArrangedSubview(makePermissionCard())
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "AltTab")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])

        let title = NSTextField(labelWithString: "AltTab needs Accessibility permission")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        let subtitle = NSTextField(wrappingLabelWithString: "Grant permission once, then AltTab can detect Command-Tab and focus the selected window.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        let header = NSStackView(views: [icon, textStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalToConstant: 512),
        ])
        return header
    }

    private func makePermissionCard() -> NSView {
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 8
        cardView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Accessibility")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let description = NSTextField(wrappingLabelWithString: "Required for global hotkey handling, window titles, raising windows, and unminimizing selected windows.")
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 3

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let button = NSButton(title: "Request Accessibility Access...", target: self, action: #selector(requestPermission))
        button.bezelStyle = .rounded

        let textStack = NSStackView(views: [title, description])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let actionStack = NSStackView(views: [button, statusLabel])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 12

        let root = NSStackView(views: [textStack, actionStack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(root)

        NSLayoutConstraint.activate([
            cardView.widthAnchor.constraint(equalToConstant: 512),
            root.topAnchor.constraint(equalTo: cardView.topAnchor),
            root.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
        ])

        updatePermissionStatus(isTrusted: AXIsProcessTrusted())
        return cardView
    }

    @objc private func requestPermission() {
        onRequestPermission()
    }
}
