//
//  InvisibleWindow.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit
import SwiftUI

/// This allows us to render SwiftUI views anywhere on the screen, without dealing with the awkward
/// rendering issues that come with normal MacOS windows. Essentially, we create one giant invisible
/// window that covers the entire screen, and render our SwiftUI views into it.
///
/// I'm pretty sure this is what CleanShot X and other apps do to render their floating widgets.
/// But if there's a better way to do this, I'd love to know!
class InvisibleWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let styleMask: NSWindow.StyleMask = [.fullSizeContentView, .borderless, .utilityWindow, .nonactivatingPanel]

        super.init(contentRect: screen.frame,
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)

        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false // Prevent hiding when app loses focus
        canHide = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

        // Set initial frame
        updateToScreenWithMouse()

        // Start observing screen changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )

        // Also observe screen parameters for resolution changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateToScreenWithMouse() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
        setFrame(screenWithMouse.frame, display: true)
    }

    @objc private func screenDidChange(_: Notification) {
        updateToScreenWithMouse()
    }
}

extension InvisibleWindow: NSWindowDelegate {
    static func fromView<V: View>(_ view: V) -> InvisibleWindow {
        let window = InvisibleWindow()
        window.contentView = NSHostingView(rootView: view)
        window.delegate = window
        return window
    }
}
