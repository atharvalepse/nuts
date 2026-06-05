//
//  NotchIslandManager.swift
//  nut
//
//  Owns the floating "island" NSPanel that sits at the notch / top-center of the
//  main screen. Same non-activating, all-Spaces panel pattern as the menu-bar
//  panel and cursor overlay. The SwiftUI view (NotchIslandView) drives the
//  expanded/collapsed state via the onExpansionChange callback, and this manager
//  resizes + recenters the panel to match.
//

import AppKit
import SwiftUI

/// NSPanel that can become key (so the inline reply field can receive typing)
/// even though it's a non-activating panel.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchIslandManager: NSObject {
    private var panel: NSPanel?
    private let companionManager: CompanionManager

    private let collapsedSize = CGSize(width: 230, height: 36)
    private let expandedSize = CGSize(width: 460, height: 300)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    /// Creates (once) and shows the collapsed pill.
    func show() {
        if panel == nil {
            createPanel()
        }
        positionPanel(expanded: false)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let islandView = NotchIslandView(companionManager: companionManager) { [weak self] expanded in
            self?.positionPanel(expanded: expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        let hostingView = NSHostingView(rootView: islandView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let islandPanel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        islandPanel.isFloatingPanel = true
        islandPanel.level = .statusBar
        islandPanel.isOpaque = false
        islandPanel.backgroundColor = .clear
        islandPanel.hasShadow = true
        islandPanel.hidesOnDeactivate = false
        islandPanel.isExcludedFromWindowsMenu = true
        islandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        islandPanel.isMovableByWindowBackground = false
        islandPanel.contentView = hostingView
        panel = islandPanel
    }

    /// Sizes the panel to the collapsed pill or the expanded card, keeping it
    /// centered horizontally and anchored just under the menu bar (so it appears
    /// to hug the notch on notched Macs and float at top-center otherwise).
    private func positionPanel(expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? expandedSize : collapsedSize

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.setContentSize(size)
            return
        }

        let originX = screen.frame.midX - size.width / 2
        // visibleFrame.maxY is the bottom of the menu bar; sit just beneath it.
        let originY = screen.visibleFrame.maxY - size.height - 2

        panel.setFrame(
            NSRect(x: originX, y: originY, width: size.width, height: size.height),
            display: true,
            animate: true
        )
    }
}
