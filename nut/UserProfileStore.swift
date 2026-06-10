//
//  UserProfileStore.swift
//  nut
//
//  The "My Info" vault: the user's personal details (name, email, phone, etc.)
//  stored ENCRYPTED in the macOS Keychain. Nut injects these into the agentic
//  autofill prompt so it can fill forms with the user's real data — without the
//  user having to dictate their email/address every time.
//
//  All fields are PII, so the whole profile lives in the Keychain (never
//  UserDefaults, never the app bundle, never committed).
//

import Combine
import Foundation

struct UserProfile: Codable, Equatable {
    var fullName: String = ""
    var email: String = ""
    var phone: String = ""
    var address: String = ""
    var company: String = ""
    var notes: String = ""   // free-form: anything else Nut should know to fill in

    var isEmpty: Bool {
        [fullName, email, phone, address, company, notes]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Plain-text block of the non-empty fields, for injecting into prompts.
    var promptContext: String {
        var lines: [String] = []
        if !fullName.isEmpty  { lines.append("name: \(fullName)") }
        if !email.isEmpty     { lines.append("email: \(email)") }
        if !phone.isEmpty     { lines.append("phone: \(phone)") }
        if !address.isEmpty   { lines.append("address: \(address)") }
        if !company.isEmpty   { lines.append("company: \(company)") }
        if !notes.isEmpty     { lines.append("other: \(notes)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class UserProfileStore: ObservableObject {
    static let shared = UserProfileStore()

    @Published private(set) var profile: UserProfile

    private static let keychainService = "com.nut.profile"
    private static let keychainAccount = "userProfile"

    private init() {
        if let raw = KeychainHelper.read(service: Self.keychainService, account: Self.keychainAccount),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = UserProfile()
        }
    }

    var isConfigured: Bool { !profile.isEmpty }

    func update(_ newProfile: UserProfile) {
        profile = newProfile
        if newProfile.isEmpty {
            KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        } else if let data = try? JSONEncoder().encode(newProfile),
                  let json = String(data: data, encoding: .utf8) {
            KeychainHelper.save(json, service: Self.keychainService, account: Self.keychainAccount)
        }
    }
}
