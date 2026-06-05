//
//  NotchIslandView.swift
//  nut
//
//  The "Dynamic-Island-for-Mac" HUD. A small pill that hugs the notch / top-center
//  and stays clean when idle. Hovering (or a new reply arriving) expands it to show
//  Nut's last answer plus an inline reply field and a push-to-talk mic — so
//  you can respond without opening the full menu-bar panel.
//

import SwiftUI

struct NotchIslandView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Called whenever the expanded state flips, so the manager can resize/reposition the panel.
    let onExpansionChange: (Bool) -> Void

    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var isRevealed = false
    @State private var replyText = ""
    @State private var isHoldingMic = false
    @FocusState private var replyFieldFocused: Bool

    /// Whether the island chrome (pill + background) should be visible at all.
    /// We want it invisible while the mouse isn't near the notch, and to fade in
    /// when the user hovers, when a fresh reply arrives, or while typing/recording.
    private var shouldShowChrome: Bool {
        isHovering || isExpanded || replyFieldFocused || isHoldingMic
    }

    private var statusColor: Color {
        switch companionManager.voiceState {
        case .idle: return .green
        case .listening: return .blue
        case .processing: return .orange
        case .responding: return .purple
        }
    }

    private var statusText: String {
        switch companionManager.voiceState {
        case .idle: return "Nut"
        case .listening: return "listening…"
        case .processing: return "thinking…"
        case .responding: return "speaking…"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedBar
            if companionManager.pendingAction != nil {
                actionConsentContent
            } else if isExpanded {
                expandedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        // Fade chrome in only when the user hovers the notch area (or while we
        // have a reason to stay visible — expanded, typing, recording). The
        // panel itself stays mounted so it can keep receiving hover events.
        .opacity(isRevealed ? 1 : 0)
        // The whole frame is a hover target even when the chrome is invisible,
        // so moving the mouse near the notch reveals the pill.
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            // Stay open while hovering or while the reply field has focus.
            setExpanded(hovering || replyFieldFocused)
            updateRevealed()
        }
        .onChange(of: companionManager.latestResponseText) { _, newValue in
            // A fresh answer arrived — pop open, then auto-collapse if the user
            // isn't hovering or typing.
            guard !newValue.isEmpty else { return }
            setExpanded(true)
            updateRevealed()
            scheduleAutoCollapse()
        }
        .onChange(of: companionManager.pendingAction) { _, newPending in
            // An action is waiting for approval — force the island open and keep
            // it revealed until the user answers Yes/No. NEVER auto-collapse a
            // consent prompt, because that would dismiss it silently.
            if newPending != nil {
                setExpanded(true)
                updateRevealed()
            }
        }
        .onChange(of: replyFieldFocused) { _, _ in updateRevealed() }
        .onChange(of: isHoldingMic) { _, _ in updateRevealed() }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: isRevealed)
    }

    private var collapsedBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.7), radius: 3)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Spacer(minLength: 8)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .contentShape(Rectangle())
    }

    /// Consent prompt for an app-control action the model is asking to perform.
    /// Replaces the normal reply view while a PendingAction is set; the user
    /// must explicitly Approve or Cancel before anything runs.
    private var actionConsentContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.white.opacity(0.1))

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                Text("Nut wants to take an action")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }

            if let pendingAction = companionManager.pendingAction {
                Text(pendingAction.action.humanDescription)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }

            HStack(spacing: 8) {
                Button(action: companionManager.cancelPendingAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text("Cancel")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: companionManager.approvePendingAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Run it")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.1))

            if let transcript = companionManager.lastTranscript, !transcript.isEmpty {
                Text("you: \(transcript)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }

            ScrollView {
                Text(companionManager.latestResponseText.isEmpty
                     ? "ask me anything, or hold the mic to talk."
                     : companionManager.latestResponseText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)

            HStack(spacing: 8) {
                TextField("Reply…", text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .focused($replyFieldFocused)
                    .onSubmit(sendReply)

                Button(action: sendReply) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(replyText.isEmpty ? 0.3 : 0.95))
                }
                .buttonStyle(.plain)
                .disabled(replyText.isEmpty)

                micButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var micButton: some View {
        Image(systemName: isHoldingMic ? "mic.fill" : "mic")
            .font(.system(size: 15))
            .foregroundColor(isHoldingMic ? .red : .white.opacity(0.8))
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .gesture(
                // Press-and-hold = push-to-talk, reusing the global pipeline.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHoldingMic {
                            isHoldingMic = true
                            companionManager.beginVoiceReply()
                        }
                    }
                    .onEnded { _ in
                        if isHoldingMic {
                            isHoldingMic = false
                            companionManager.endVoiceReply()
                        }
                    }
            )
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        companionManager.submitTypedMessage(text)
        replyText = ""
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        onExpansionChange(expanded)
    }

    private func updateRevealed() {
        isRevealed = shouldShowChrome
    }

    private func scheduleAutoCollapse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            if !isHovering && !replyFieldFocused {
                setExpanded(false)
                updateRevealed()
            }
        }
    }
}
