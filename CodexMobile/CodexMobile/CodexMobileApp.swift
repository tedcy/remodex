// FILE: CodexMobileApp.swift
// Purpose: App entry point, RevenueCat setup, and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import RevenueCat
import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    @State private var petCompanionStore: PetCompanionStore
    @State private var petCompanionStatusStore: PetCompanionStatusStore
    @State private var subscriptionService: SubscriptionService

    init() {
        Self.configureRevenueCatIfAvailable()
        let service = CodexService()
        service.configureNotifications()
        _codexService = State(initialValue: service)
        _petCompanionStore = State(initialValue: PetCompanionStore())
        _petCompanionStatusStore = State(initialValue: PetCompanionStatusStore())
        _subscriptionService = State(initialValue: SubscriptionService())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let fixtureConfiguration = CodexUITestFixtureConfiguration.fromProcessArguments() {
                CodexUITestFixtureRootView(configuration: fixtureConfiguration)
                    .environment(codexService)
                    .environment(petCompanionStore)
                    .environment(petCompanionStatusStore)
                    .environment(subscriptionService)
            } else {
                standardRootView
            }
            #else
            standardRootView
            #endif
        }
    }

    private var standardRootView: some View {
            ContentView()
                .environment(codexService)
                .environment(petCompanionStore)
                .environment(petCompanionStatusStore)
                .environment(subscriptionService)
                .task {
                    await subscriptionService.bootstrap()
                }
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
    }

    // Configures RevenueCat once at launch using the client-safe public SDK key.
    private static func configureRevenueCatIfAvailable() {
        guard let apiKey = AppEnvironment.revenueCatPublicAPIKey else {
            assertionFailure("Missing RevenueCat public API key in Info.plist")
            return
        }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
    }
}

#if DEBUG
private struct CodexUITestFixtureConfiguration: Equatable {
    let messageCount: Int
    let autoStream: Bool

    static func fromProcessArguments(_ arguments: [String] = CommandLine.arguments) -> Self? {
        guard arguments.contains("-CodexUITestsFixture") else {
            return nil
        }

        let requestedCount = value(after: "-CodexUITestsMessageCount", in: arguments)
            .flatMap(Int.init) ?? 200
        return Self(
            messageCount: min(max(requestedCount, 1), 5_000),
            autoStream: arguments.contains("-CodexUITestsAutoStream")
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }
}

private struct CodexUITestFixtureRootView: View {
    @Environment(CodexService.self) private var codex
    let configuration: CodexUITestFixtureConfiguration

    @State private var didSeed = false
    @State private var streamTask: Task<Void, Never>?

    private let thread = CodexThread(
        id: "ui-test-fixture-thread",
        title: "Timeline Fixture",
        preview: "Synthetic local transcript",
        createdAt: Date(),
        updatedAt: Date(),
        cwd: "/tmp/remodex-ui-fixture"
    )
    private let streamingMessageID = "ui-test-fixture-streaming-message"

    var body: some View {
        NavigationStack {
            TurnView(
                thread: thread,
                isWakingMacDisplayRecovery: false
            )
        }
        .task {
            seedFixtureIfNeeded()
            startStreamingIfNeeded()
        }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
    }

    @MainActor
    private func seedFixtureIfNeeded() {
        guard !didSeed else {
            return
        }

        didSeed = true
        codex.isConnected = false
        codex.isConnecting = false
        codex.isInitialized = true
        codex.activeThreadId = thread.id
        codex.supportsTurnPagination = false
        codex.threads = [thread]
        codex.hydratedThreadIDs.insert(thread.id)
        codex.initialTurnsLoadedByThreadID.insert(thread.id)
        codex.messagesByThread[thread.id] = makeMessages()
        codex.messageRevisionByThread[thread.id, default: 0] += 1
        codex.refreshThreadTimelineState(for: thread.id)
    }

    @MainActor
    private func startStreamingIfNeeded() {
        guard configuration.autoStream, streamTask == nil else {
            return
        }

        if codex.messagesByThread[thread.id]?.contains(where: { $0.id == streamingMessageID }) != true {
            codex.appendMessage(
                CodexMessage(
                    id: streamingMessageID,
                    threadId: thread.id,
                    role: .assistant,
                    text: "Streaming fixture",
                    turnId: "ui-test-fixture-streaming-turn",
                    isStreaming: true,
                    orderIndex: configuration.messageCount + 1
                )
            )
        }

        streamTask = Task { @MainActor in
            for chunkIndex in 1...80 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else {
                    return
                }
                guard let messageIndex = codex.messagesByThread[thread.id]?.firstIndex(where: {
                    $0.id == streamingMessageID
                }) else {
                    continue
                }
                codex.messagesByThread[thread.id]?[messageIndex].text += "\nStreaming update \(chunkIndex)"
                codex.messagesByThread[thread.id]?[messageIndex].isStreaming = chunkIndex < 80
                codex.messageRevisionByThread[thread.id, default: 0] += 1
                codex.refreshThreadTimelineState(for: thread.id)
            }
        }
    }

    private func makeMessages() -> [CodexMessage] {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<configuration.messageCount).map { index in
            let isUser = index.isMultiple(of: 2)
            let turnID = "ui-test-fixture-turn-\(index / 2)"
            return CodexMessage(
                id: "ui-test-fixture-message-\(index)",
                threadId: thread.id,
                role: isUser ? .user : .assistant,
                text: messageText(index: index, isUser: isUser),
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                turnId: turnID,
                orderIndex: index
            )
        }
    }

    private func messageText(index: Int, isUser: Bool) -> String {
        if isUser {
            return "Fixture prompt \(index): inspect the current implementation and keep the response concise."
        }

        return """
        Fixture response \(index) with enough text to exercise timeline layout and markdown rendering.

        ```swift
        let value\(index) = \(index)
        print(value\(index))
        ```
        """
    }
}
#endif
