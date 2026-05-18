// FILE: CodexSecurePairingStateTests.swift
// Purpose: Verifies fresh QR scans force bootstrap mode and secure pairing failures stay actionable in UI state.
// Layer: Unit Test
// Exports: CodexSecurePairingStateTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexSecurePairingStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testRememberRelayPairingForcesFreshQRBootstrapEvenForTrustedMac() {
        let service = CodexService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let originalPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        let freshQRPublicKey = Data(repeating: 2, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: originalPublicKey,
            lastPairedAt: Date()
        )

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: macDeviceID,
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertFalse(service.hasTrustedReconnectContext)
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(service.normalizedRelayMacIdentityPublicKey, freshQRPublicKey)
    }

    func testRememberRelayPairingShowsHandshakeStateForBrandNewMac() {
        let service = CodexService()
        let freshQRPublicKey = Data(repeating: 4, count: 32).base64EncodedString()

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: "mac-\(UUID().uuidString)",
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertEqual(service.secureConnectionState, .handshaking)
        XCTAssertEqual(service.secureMacFingerprint, codexSecureFingerprint(for: freshQRPublicKey))
    }

    func testResetSecureTransportStatePreservesRePairRequiredState() {
        let service = CodexService()
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://relay.local/relay"
        service.secureConnectionState = .rePairRequired
        service.secureMacFingerprint = "ABC123"

        service.resetSecureTransportState()

        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.secureMacFingerprint, "ABC123")
    }

    func testApplyingResolvedTrustedSessionResetsReplayCursorWhenLiveSessionChanges() {
        let service = CodexService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "stale-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.lastAppliedBridgeOutboundSeq = 17
        SecureStore.writeString("17", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)

        service.applyResolvedTrustedSession(
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
                displayName: "Desk Mac",
                sessionId: "fresh-session"
            ),
            relayURL: "wss://relay.local/relay"
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 0)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq),
            "0"
        )
    }

    func testApplyingResolvedTrustedSessionKeepsReplayCursorWhenLiveSessionIsUnchanged() {
        let service = CodexService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "same-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.lastAppliedBridgeOutboundSeq = 17
        SecureStore.writeString("17", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)

        service.applyResolvedTrustedSession(
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 8, count: 32).base64EncodedString(),
                displayName: "Desk Mac",
                sessionId: "same-session"
            ),
            relayURL: "wss://relay.local/relay"
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 17)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq),
            "17"
        )
    }

    func testSelectingTrustedHostChangesReconnectTargetAndPersistsSelection() async {
        let service = CodexService()
        let firstMacDeviceID = "mac-\(UUID().uuidString)"
        let secondMacDeviceID = "mac-\(UUID().uuidString)"
        let firstPublicKey = Data(repeating: 11, count: 32).base64EncodedString()
        let secondPublicKey = Data(repeating: 12, count: 32).base64EncodedString()
        let firstRelayURL = "wss://first.example.com/relay"
        let secondRelayURL = "wss://second.example.com/relay"

        service.trustedMacRegistry.records[firstMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: firstMacDeviceID,
            macIdentityPublicKey: firstPublicKey,
            lastPairedAt: Date().addingTimeInterval(-120),
            relayURL: firstRelayURL,
            displayName: "First Host",
            lastResolvedSessionId: "first-session",
            lastResolvedAt: Date().addingTimeInterval(-100),
            lastUsedAt: Date().addingTimeInterval(-80)
        )
        service.trustedMacRegistry.records[secondMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: secondMacDeviceID,
            macIdentityPublicKey: secondPublicKey,
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: secondRelayURL,
            displayName: "Second Host",
            lastResolvedSessionId: "second-session",
            lastResolvedAt: Date().addingTimeInterval(-40),
            lastUsedAt: Date().addingTimeInterval(-20)
        )

        service.lastTrustedMacDeviceId = firstMacDeviceID
        service.relaySessionId = "first-session"
        service.relayUrl = firstRelayURL
        service.relayMacDeviceId = firstMacDeviceID
        service.relayMacIdentityPublicKey = firstPublicKey
        service.lastAppliedBridgeOutboundSeq = 31
        SecureStore.writeString("31", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)

        await service.selectTrustedHost(deviceId: secondMacDeviceID)

        XCTAssertEqual(service.normalizedRelaySessionId, "second-session")
        XCTAssertEqual(service.normalizedRelayURL, secondRelayURL)
        XCTAssertEqual(service.normalizedRelayMacDeviceId, secondMacDeviceID)
        XCTAssertEqual(service.normalizedRelayMacIdentityPublicKey, secondPublicKey)
        XCTAssertEqual(service.normalizedLastTrustedMacDeviceId, secondMacDeviceID)
        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 0)
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.relaySessionId), "second-session")
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.relayUrl), secondRelayURL)
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.lastTrustedMacDeviceId), secondMacDeviceID)
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq), "0")
        XCTAssertEqual(service.trustedHostPresentations.first?.id, secondMacDeviceID)
        XCTAssertTrue(service.trustedHostPresentations.first?.isActive ?? false)
    }

    func testSelectingTrustedHostWithoutSavedSessionKeepsTrustedReconnectCandidate() async {
        let service = CodexService()
        let firstMacDeviceID = "mac-\(UUID().uuidString)"
        let secondMacDeviceID = "mac-\(UUID().uuidString)"
        let firstPublicKey = Data(repeating: 13, count: 32).base64EncodedString()
        let secondPublicKey = Data(repeating: 14, count: 32).base64EncodedString()
        let secondRelayURL = "wss://second.example.com/relay"

        service.trustedMacRegistry.records[firstMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: firstMacDeviceID,
            macIdentityPublicKey: firstPublicKey,
            lastPairedAt: Date().addingTimeInterval(-120),
            relayURL: "wss://first.example.com/relay",
            lastResolvedSessionId: "first-session"
        )
        service.trustedMacRegistry.records[secondMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: secondMacDeviceID,
            macIdentityPublicKey: secondPublicKey,
            lastPairedAt: Date().addingTimeInterval(-60),
            relayURL: secondRelayURL,
            displayName: "Second Host"
        )

        service.lastTrustedMacDeviceId = firstMacDeviceID
        service.relaySessionId = "first-session"
        service.relayUrl = "wss://first.example.com/relay"
        service.relayMacDeviceId = firstMacDeviceID
        service.relayMacIdentityPublicKey = firstPublicKey

        await service.selectTrustedHost(deviceId: secondMacDeviceID)

        XCTAssertNil(service.normalizedRelaySessionId)
        XCTAssertFalse(service.hasSavedRelaySession)
        XCTAssertTrue(service.hasTrustedMacReconnectCandidate)
        XCTAssertEqual(service.normalizedRelayURL, secondRelayURL)
        XCTAssertEqual(service.normalizedRelayMacDeviceId, secondMacDeviceID)
        XCTAssertEqual(service.normalizedLastTrustedMacDeviceId, secondMacDeviceID)
        XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.relaySessionId))
        XCTAssertEqual(SecureStore.readString(for: CodexSecureKeys.relayUrl), secondRelayURL)
    }

    // Clears the persisted relay session keys touched by secure reconnect tests.
    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }
}
