//
//  GMLSetupView.swift
//  nut
//
//  Settings form for the GML (Graph Memory Layer) cloud backend.
//  Shown in the Nut panel when GML is not configured yet, or when
//  the user taps "Edit" on the connected GML row.
//

import SwiftUI

struct GMLSetupView: View {
    @ObservedObject private var gmlSettings = GMLSettings.shared
    var onSaved: () -> Void

    @State private var endpointInput: String
    @State private var authTokenInput: String

    init(onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        _endpointInput  = State(initialValue: GMLSettings.shared.endpoint)
        _authTokenInput = State(initialValue: GMLSettings.shared.authToken)
    }

    private var canSave: Bool {
        !endpointInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.blue.opacity(0.8))
                Text(gmlSettings.isConfigured ? "GML Cloud Memory" : "Connect GML Memory")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Text("GML stores your screen memories in the cloud and retrieves relevant ones using semantic search — smarter than local recency-only recall.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("API endpoint")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("https://your-project.run.app", text: $endpointInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))

            Text("Auth token (optional)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            SecureField("Bearer token if required", text: $authTokenInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))

            Text("Nut will POST to /ingest when you save a memory, and POST to /query before each answer to retrieve relevant context.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(canSave ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .pointerCursor()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
    }

    private func save() {
        Task { @MainActor in
            gmlSettings.update(endpoint: endpointInput, authToken: authTokenInput)
            onSaved()
        }
    }
}
