//
//  AIBrainSetupView.swift
//  nut
//
//  Bring-your-own-key setup form shown in the menu-bar panel. The user picks a
//  provider, pastes their API key (stored in the Keychain via LLMSettings), and
//  chooses a vision model. Until this is filled in, the panel shows it as a
//  first-run gate ("Add your AI key to start").
//

import SwiftUI

struct AIBrainSetupView: View {
    @ObservedObject private var llmSettings = LLMSettings.shared
    /// Called after a successful save so the parent can collapse the form.
    var onSaved: () -> Void

    @State private var selectedProvider: LLMProvider
    @State private var endpointInput: String
    @State private var modelInput: String
    @State private var apiKeyInput: String

    init(onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        let settings = LLMSettings.shared
        _selectedProvider = State(initialValue: settings.provider)
        _endpointInput = State(initialValue: settings.endpoint)
        _modelInput = State(initialValue: settings.model)
        _apiKeyInput = State(initialValue: settings.apiKey)
    }

    private var canSave: Bool {
        let keyOK = !selectedProvider.requiresAPIKey
            || !apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty
        let endpointOK = selectedProvider != .custom
            || !endpointInput.trimmingCharacters(in: .whitespaces).isEmpty
        let modelOK = !modelInput.trimmingCharacters(in: .whitespaces).isEmpty
        return keyOK && endpointOK && modelOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(llmSettings.isConfigured ? "AI provider" : "Add your AI key to start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Picker("", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: selectedProvider) { _, newProvider in
                // Prefill sensible defaults whenever the provider changes.
                endpointInput = newProvider.defaultEndpoint
                modelInput = newProvider.defaultModel
            }

            if selectedProvider == .custom {
                fieldLabel("Endpoint URL")
                styledField("https://.../v1/chat/completions", text: $endpointInput, secure: false)
            }

            fieldLabel("Model (must support vision)")
            styledField("model name", text: $modelInput, secure: false)

            if selectedProvider.requiresAPIKey {
                fieldLabel("API key")
                styledField("paste your key", text: $apiKeyInput, secure: true)
            }

            Text(selectedProvider.keyHint)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(canSave ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func save() {
        llmSettings.update(
            provider: selectedProvider,
            endpoint: endpointInput,
            model: modelInput,
            apiKey: apiKeyInput
        )
        onSaved()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
    }

    @ViewBuilder
    private func styledField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }
}
