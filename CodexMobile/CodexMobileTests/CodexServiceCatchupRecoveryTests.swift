// FILE: CodexServiceCatchupRecoveryTests.swift
// Purpose: Verifies deferred-history recovery and running-thread catch-up escalation for large or active chats.
// Layer: Unit Test
// Exports: CodexServiceCatchupRecoveryTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceCatchupRecoveryTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testModernHistoryOpenUsesTurnPaginationWithoutThreadRead() async throws {
        let service = makeService()
        let threadID = "thread-modern-pagination"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Modern"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                XCTAssertEqual(params?.objectValue?["limit"]?.intValue, ThreadHistoryHydrationPolicy.initialTurnPageSize)
                XCTAssertEqual(params?.objectValue?["sortDirection"]?.stringValue, "desc")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                XCTFail("Modern paginated history open should not call thread/read")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedPaginatedWindow)
        XCTAssertEqual(recordedMethods, ["thread/turns/list"])
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
    }

    func testHistoryOpenFallsBackToLegacyThreadReadWhenTurnPaginationIsUnsupported() async throws {
        let service = makeService()
        let threadID = "thread-legacy-pagination"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Legacy"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32601, message: "Method not found: thread/turns/list")
                )
            case "thread/read":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                XCTAssertEqual(params?.objectValue?["includeTurns"]?.boolValue, true)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Legacy"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedCanonicalHistory)
        XCTAssertEqual(recordedMethods, ["thread/turns/list", "thread/read"])
        XCTAssertFalse(service.supportsTurnPagination)
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
    }

    func testHistoryOpenFallsBackToLegacyThreadReadWhenTurnPaginationPayloadIsInvalid() async throws {
        let service = makeService()
        let threadID = "thread-invalid-pagination-payload"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Invalid page"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .null,
                    includeJSONRPC: false
                )
            case "thread/read":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Invalid page"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedCanonicalHistory)
        XCTAssertEqual(recordedMethods, ["thread/turns/list", "thread/read"])
        XCTAssertFalse(service.supportsTurnPagination)
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
    }

    func testForcedHistorySkipsFreshFirstTurnWhileThreadIsStillMaterializing() async throws {
        let service = makeService()
        let threadID = "thread-first-turn-materializing"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Hi"))
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.runningThreadIDs.insert(threadID)
        service.messagesByThread[threadID] = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "hi",
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                kind: .thinking,
                text: "",
                isStreaming: true
            ),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            if let response = remodexTestPreflightRPCResponse(method: method, params: params) {
                return response
            }
            recordedMethods.append(method)
            XCTFail("First running turn should not hydrate history before the runtime materializes it")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .skippedForRunningThread)
        XCTAssertTrue(recordedMethods.isEmpty)
    }

    func testRunningCatchupEscalatesExistingLightweightTaskIntoForcedResume() async {
        let service = makeService()
        let threadID = "thread-running"
        let turnID = "turn-running"

        service.isConnected = true
        service.isInitialized = true
        service.upsertThread(CodexThread(id: threadID, title: "Running"))

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/turns/list":
                try? await Task.sleep(nanoseconds: 20_000_000)
                return remodexTestThreadTurnsListResponse(turns: [
                    .object([
                        "id": .string(turnID),
                        "status": .string("running"),
                    ]),
                ])
            case "thread/read":
                try? await Task.sleep(nanoseconds: 20_000_000)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
                            "turns": .array([
                                .object([
                                    "id": .string(turnID),
                                    "status": .string("running"),
                                ]),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequestCount += 1
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        async let lightweightOutcome = service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: false
        )
        await Task.yield()
        let forcedOutcome = await service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: true
        )
        let initialOutcome = await lightweightOutcome

        XCTAssertEqual(resumeRequestCount, 1)
        XCTAssertTrue(forcedOutcome.isRunning)
        XCTAssertTrue(forcedOutcome.didRunForcedResume)
        XCTAssertTrue(initialOutcome.isRunning)
    }

    func testServerUpdateRearmsDeferredHistoryRefreshForLargeActiveChat() {
        let service = makeService()
        let threadID = "thread-large"
        let previousUpdatedAt = Date(timeIntervalSince1970: 10)
        let nextUpdatedAt = Date(timeIntervalSince1970: 20)

        service.activeThreadId = threadID
        service.threadsWithSatisfiedDeferredHistoryHydration.insert(threadID)
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        let shouldRefresh = service.shouldRefreshDeferredHydrationForServerUpdate(
            incomingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "new preview",
                updatedAt: nextUpdatedAt
            ),
            existingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "old preview",
                updatedAt: previousUpdatedAt
            ),
            treatAsServerState: true
        )

        XCTAssertTrue(shouldRefresh)
    }

    func testForegroundSyncKeepsDeferredLargeClosedChatOffForcedHistoryRead() async {
        let service = makeService()
        let threadID = "thread-large-closed"

        service.isConnected = true
        service.isInitialized = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(id: threadID, title: "Large Closed"))
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        var lightweightTurnRefreshCount = 0
        var canonicalHistoryReadCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/turns/list":
                lightweightTurnRefreshCount += 1
                return remodexTestThreadTurnsListResponse()
            case "thread/read":
                let includeTurns = params?.objectValue?["includeTurns"]?.boolValue ?? false
                if includeTurns {
                    canonicalHistoryReadCount += 1
                    try? await Task.sleep(nanoseconds: 120_000_000)
                } else {
                    lightweightTurnRefreshCount += 1
                }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Large Closed"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        let startedAt = Date()
        await service.syncActiveThreadState(threadId: threadID)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(lightweightTurnRefreshCount, 1)
        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertLessThanOrEqual(canonicalHistoryReadCount, 1)
    }

    func testReloadThreadHistoryFromServerDropsStaleLocalCache() async throws {
        let service = makeService()
        let threadID = "thread-reload-success"
        let staleMessage = CodexMessage(threadId: threadID, role: .assistant, text: "stale local")

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = false
        service.upsertThread(CodexThread(id: threadID, title: "Reload"))
        service.messagesByThread[threadID] = [staleMessage]
        service.hydratedThreadIDs.insert(threadID)
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.threadTimelineProjectionLimitByThreadID[threadID] = 500
        service.olderHistoryLoadErrorByThreadID[threadID] = "Old error"
        let state = service.timelineState(for: threadID)

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
            return self.threadReadResponse(
                threadID: threadID,
                title: "Reload",
                itemID: "server-assistant",
                text: "server fresh"
            )
        }

        let outcome = try await service.reloadThreadHistoryFromServer(threadId: threadID)

        XCTAssertEqual(outcome, .loadedCanonicalHistory)
        XCTAssertEqual(recordedMethods, ["thread/read"])
        XCTAssertEqual(service.messages(for: threadID).map(\.text), ["server fresh"])
        XCTAssertFalse(service.messages(for: threadID).contains { $0.text == staleMessage.text })
        XCTAssertEqual(
            service.threadTimelineProjectionLimitByThreadID[threadID],
            TurnTimelineProjectionPolicy.initialMessageLimit
        )
        XCTAssertNil(service.olderHistoryLoadErrorByThreadID[threadID])
        XCTAssertEqual(state.renderSnapshot.messages.map(\.text), ["server fresh"])
    }

    func testReloadThreadHistoryFromServerRestoresLocalCacheWhenRequestFails() async {
        let service = makeService()
        let threadID = "thread-reload-failure"
        let staleMessage = CodexMessage(threadId: threadID, role: .assistant, text: "stale local")

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = false
        service.upsertThread(CodexThread(id: threadID, title: "Reload"))
        service.messagesByThread[threadID] = [staleMessage]
        service.hydratedThreadIDs.insert(threadID)
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.threadsWithAuthoritativeLocalHistoryStart.insert(threadID)
        service.threadTimelineProjectionLimitByThreadID[threadID] = 500
        service.olderHistoryLoadErrorByThreadID[threadID] = "Old error"
        let state = service.timelineState(for: threadID)

        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.invalidResponse("boom")
        }

        do {
            _ = try await service.reloadThreadHistoryFromServer(threadId: threadID)
            XCTFail("Expected reload failure")
        } catch {
            // Expected failure; the local cache should be restored below.
        }

        XCTAssertEqual(service.messages(for: threadID).map(\.text), ["stale local"])
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.threadsWithAuthoritativeLocalHistoryStart.contains(threadID))
        XCTAssertEqual(service.threadTimelineProjectionLimitByThreadID[threadID], 500)
        XCTAssertEqual(service.olderHistoryLoadErrorByThreadID[threadID], "Old error")
        XCTAssertEqual(state.renderSnapshot.messages.map(\.text), ["stale local"])
    }

    func testReloadThreadHistoryFromServerIgnoresStaleOlderPageCompletion() async throws {
        let service = makeService()
        let threadID = "thread-reload-stale-older-page"
        let recentMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: "recent cached",
            itemId: "recent-cached",
            orderIndex: 100
        )

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Reload"))
        service.messagesByThread[threadID] = [recentMessage]
        service.hydratedThreadIDs.insert(threadID)
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.olderThreadHistoryCursorByThreadID[threadID] = .string("older-cursor")
        service.threadTimelineProjectionLimitByThreadID[threadID] = TurnTimelineProjectionPolicy.initialMessageLimit

        var olderPageStarted = false
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)

            if params?.objectValue?["cursor"]?.stringValue == "older-cursor" {
                olderPageStarted = true
                try? await Task.sleep(nanoseconds: 120_000_000)
                return self.threadTurnsListResponse(
                    threadID: threadID,
                    itemID: "stale-older",
                    text: "stale older",
                    nextCursor: .string("stale-next")
                )
            }

            XCTAssertNil(params?.objectValue?["cursor"])
            return self.threadTurnsListResponse(
                threadID: threadID,
                itemID: "server-fresh",
                text: "server fresh",
                nextCursor: .null
            )
        }

        let olderLoadTask = Task { @MainActor in
            await service.loadOlderThreadHistoryPage(threadId: threadID)
        }

        for _ in 0..<20 where !olderPageStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(olderPageStarted)

        let outcome = try await service.reloadThreadHistoryFromServer(threadId: threadID)
        await olderLoadTask.value

        XCTAssertEqual(outcome, .loadedPaginatedWindow)
        XCTAssertEqual(service.messages(for: threadID).map(\.text), ["server fresh"])
        XCTAssertFalse(service.messages(for: threadID).contains { $0.text == "stale older" })
        XCTAssertNotEqual(service.olderThreadHistoryCursorByThreadID[threadID]?.stringValue, "stale-next")
        XCTAssertNil(service.olderHistoryLoadErrorByThreadID[threadID])
        XCTAssertFalse(service.loadingOlderThreadHistoryIDs.contains(threadID))
    }

    func testReloadThreadHistoryFromServerRejectsRunningThreadWithoutClearingCache() async {
        let service = makeService()
        let threadID = "thread-reload-running"
        let staleMessage = CodexMessage(threadId: threadID, role: .assistant, text: "stale local")

        service.isConnected = true
        service.isInitialized = true
        service.upsertThread(CodexThread(id: threadID, title: "Reload"))
        service.messagesByThread[threadID] = [staleMessage]
        service.runningThreadIDs.insert(threadID)

        var requestCount = 0
        service.requestTransportOverride = { _, _ in
            requestCount += 1
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        do {
            _ = try await service.reloadThreadHistoryFromServer(threadId: threadID)
            XCTFail("Expected running reload to be rejected")
        } catch let error as CodexServiceError {
            XCTAssertEqual(
                error.errorDescription,
                "Wait for the current run to finish before reloading this conversation."
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(service.messages(for: threadID).map(\.text), ["stale local"])
    }

    private func threadReadResponse(
        threadID: String,
        title: String,
        itemID: String,
        text: String
    ) -> RPCMessage {
        RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "thread": .object([
                    "id": .string(threadID),
                    "title": .string(title),
                    "turns": .array([
                        .object([
                            "id": .string("turn-\(itemID)"),
                            "status": .string("completed"),
                            "items": .array([
                                .object([
                                    "id": .string(itemID),
                                    "type": .string("assistantMessage"),
                                    "message": .string(text),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            includeJSONRPC: false
        )
    }

    private func threadTurnsListResponse(
        threadID: String,
        itemID: String,
        text: String,
        nextCursor: JSONValue
    ) -> RPCMessage {
        RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "data": .array([
                    .object([
                        "id": .string("turn-\(itemID)"),
                        "status": .string("completed"),
                        "items": .array([
                            .object([
                                "id": .string(itemID),
                                "type": .string("assistantMessage"),
                                "message": .string(text),
                            ]),
                        ]),
                    ]),
                ]),
                "nextCursor": nextCursor,
            ]),
            includeJSONRPC: false
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceCatchupRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
