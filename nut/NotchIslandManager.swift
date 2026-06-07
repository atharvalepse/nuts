//
//  NotchIslandManager.swift
//  nut
//
//  Owns the floating "island" NSPanel that sits inside the camera notch on notched
//  Macs (MacBook Pro 14/16, MacBook Air 15 M3+) or at top-center on non-notched
//  Macs. The panel level is set above the menu bar so it genuinely occupies the
//  notch area rather than floating below it.
//
//  Notch detection uses NSScreen.safeAreaInsets.top — Apple's official API for
//  this. When top > 0 the screen has a notch and we position the pill so its top
//  edge touches the very top of the screen (screen.frame.maxY), visually filling
//  the notch gap. On non-notched Macs we fall back to just below the menu bar.
//
//  Expansion anchors at the top: the pill stays at the top of the screen and the
//  card grows downward, so the notch position never shifts on expand/collapse.
//

import AppKit
import SwiftUI

/// NSPanel that can become key so the inline reply text field accepts typing,
/// even though the panel style is non-activating.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchIslandManager: NSObject {
    private var panel: NSPanel?
    private let companionManager: CompanionManager

    /// Width of the collapsed pill. Chosen to be slightly narrower than the
    /// MacBook Pro notch (~74–80 pt) so it sits snugly inside it.
    private let collapsedWidth: CGFloat = 200
    private let collapsedHeight: CGFloat = 36

    /// Expanded card dimensions — wide enough for reply text + mic button.
    private let expandedWidth: CGFloat = 480
    private let expandedHeight: CGFloat = 280

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    // MARK: - Public

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

    // MARK: - Panel creation

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
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: collapsedWidth, height: collapsedHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        islandPanel.isFloatingPanel = true
        islandPanel.isOpaque = false
        islandPanel.backgroundColor = .clear
        islandPanel.hasShadow = true
        islandPanel.hidesOnDeactivate = false
        islandPanel.isExcludedFromWindowsMenu = true
        islandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        islandPanel.isMovableByWindowBackground = false
        islandPanel.contentView = hostingView

        // Place the island above the menu bar so it occupies the notch area.
        // kCGMainMenuWindowLevel (24) is the menu bar's own level. We go two
        // levels above it so nothing in the menu bar draws over our panel.
        islandPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)

        panel = islandPanel
    }

    // MARK: - Positioning

    /// Positions the panel to the collapsed pill or the expanded card.
    /// The panel is always TOP-anchored: its top edge sits at `screen.frame.maxY`
    /// on notched Macs (inside the notch) or at `screen.visibleFrame.maxY` on
    /// non-notched Macs (just below the menu bar). As the panel expands, it grows
    /// downward — the top anchor never shifts.
    private func positionPanel(expanded: Bool) {
        guard let panel else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            panel.setContentSize(CGSize(width: collapsedWidth, height: collapsedHeight))
            return
        }

        let screenHasNotch = screen.safeAreaInsets.top > 0

        let panelWidth  = expanded ? expandedWidth  : collapsedWidth
        let panelHeight = expanded ? expandedHeight : collapsedHeight

        // Center horizontally on the screen.
        let originX = screen.frame.midX - panelWidth / 2

        // Y origin (AppKit: bottom-left). We want the TOP of the panel to be:
        //   • on notched Mac  → screen.frame.maxY   (top of physical screen, inside notch)
        //   • on normal Mac   → screen.visibleFrame.maxY  (bottom of menu bar)
        let topEdgeY: CGFloat
        if screenHasNotch {
            topEdgeY = screen.frame.maxY
        } else {
            topEdgeY = screen.visibleFrame.maxY
        }
        let originY = topEdgeY - panelHeight

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: true,
            animate: true
        )

        print("🏝️ Island: notch=\(screenHasNotch) expanded=\(expanded) frame=(\(Int(originX)),\(Int(originY))) \(Int(panelWidth))×\(Int(panelHeight))")
    }
}
