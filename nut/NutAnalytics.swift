//
//  NutAnalytics.swift
//  nut
//
//  Analytics seam. All event names and call sites are defined here so
//  instrumentation stays consistent and easy to audit. The PostHog dependency
//  was removed, so these are currently no-ops — wire up your own analytics
//  backend by filling in `configure()`, `identify(email:)`, and the `track*`
//  method bodies.
//

import Foundation

enum NutAnalytics {

    // MARK: - Setup

    static func configure() {}

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingDemoTriggered() {}

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - User

    static func identify(email: String) {}

    // MARK: - Errors

    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
