//
//  UserProfileSetupView.swift
//  nut
//
//  "My Info" form in the menu-bar panel. Lets the user store the personal details
//  Nut uses to autofill forms (saved to the Keychain via UserProfileStore).
//

import SwiftUI

struct UserProfileSetupView: View {
    @ObservedObject private var profileStore = UserProfileStore.shared
    var onSaved: () -> Void

    @State private var fullName: String
    @State private var email: String
    @State private var phone: String
    @State private var address: String
    @State private var company: String
    @State private var notes: String

    init(onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        let profile = UserProfileStore.shared.profile
        _fullName = State(initialValue: profile.fullName)
        _email = State(initialValue: profile.email)
        _phone = State(initialValue: profile.phone)
        _address = State(initialValue: profile.address)
        _company = State(initialValue: profile.company)
        _notes = State(initialValue: profile.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 11))
                    .foregroundColor(.green.opacity(0.85))
                Text("My Info")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Text("Nut uses these to autofill forms for you. Stored encrypted on this Mac.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            field("Full name", text: $fullName)
            field("Email", text: $email)
            field("Phone", text: $phone)
            field("Address", text: $address)
            field("Company", text: $company)
            field("Anything else (notes)", text: $notes)

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.9)))
            }
            .buttonStyle(.plain)
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

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }

    private func save() {
        profileStore.update(UserProfile(
            fullName: fullName, email: email, phone: phone,
            address: address, company: company, notes: notes
        ))
        onSaved()
    }
}
