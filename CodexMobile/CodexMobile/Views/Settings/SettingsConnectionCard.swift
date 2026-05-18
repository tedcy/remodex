// FILE: SettingsConnectionCard.swift
// Purpose: Presents paired-computer connection state and connection actions.
// Layer: Settings UI component
// Exports: SettingsConnectionCard
// Depends on: SwiftUI, CodexService connection state, SettingsSupportCards

import SwiftUI

private struct NewConnectionActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var newConnectionAction: (() -> Void)? {
        get { self[NewConnectionActionKey.self] }
        set { self[NewConnectionActionKey.self] = newValue }
    }
}

struct SettingsConnectionCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.newConnectionAction) private var newConnectionAction
    @Environment(\.reconnectAction) private var reconnectAction
    @State private var isShowingComputerNameSheet = false
    @State private var switchingHostDeviceId: String?
    @State private var forgettingHostDeviceId: String?

    private let settingsAccentColor = Color.primary

    var body: some View {
        SettingsCard(title: "Connection") {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedComputerCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: {
                        isShowingComputerNameSheet = true
                    }
                )
            } else {
                Text("No paired computer")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if let newConnectionAction {
                SettingsButton("New Connection") {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    newConnectionAction()
                }
            }

            if !codex.trustedHostPresentations.isEmpty {
                Text("Saved Hosts")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(codex.trustedHostPresentations) { host in
                    SettingsTrustedHostRow(
                        host: host,
                        isSwitching: switchingHostDeviceId == host.id,
                        isForgetting: forgettingHostDeviceId == host.id,
                        connectionStatusLabel: host.isActive ? connectionStatusLabel : nil,
                        canSelect: canSelectTrustedHost(host),
                        canForget: canForgetTrustedHost(host),
                        onSelect: {
                            switchTrustedHost(host)
                        },
                        onForget: {
                            forgetTrustedHost(host)
                        }
                    )
                }
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectionProgressLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                Text(message)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }

            if codex.supportsKeepAwakeWhileBridgeRuns {
                Toggle("Keep computer reachable", isOn: keepMacAwakeWhileBridgeRunsBinding)
                    .tint(settingsAccentColor)

                Text(codex.keepMacAwakeWhileBridgeRuns
                     ? "Uses the host computer's keep-awake support while the bridge is running so the computer stays reachable even if the display turns off. Best while charging."
                     : "The computer can go back to sleeping normally when the bridge is idle.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                if !codex.isConnected {
                    Text("Saved on this iPhone. It will sync to the paired computer the next time the bridge reconnects.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if codex.isConnected {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            } else if codex.hasReconnectCandidate {
                if let reconnectAction {
                    SettingsButton("Reconnect") {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        reconnectAction()
                    }
                }

                SettingsButton("Forget Pair", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    codex.forgetReconnectCandidate()
                }
            }
        }
        .sheet(isPresented: $isShowingComputerNameSheet) {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsComputerNameSheet(
                    nickname: sidebarComputerNicknameBinding(for: trustedPairPresentation),
                    currentName: trustedPairPresentation.name,
                    systemName: trustedPairPresentation.systemName ?? trustedPairPresentation.name
                )
            }
        }
    }

    private var keepMacAwakeWhileBridgeRunsBinding: Binding<Bool> {
        Binding(
            get: { codex.keepMacAwakeWhileBridgeRuns },
            set: { nextValue in
                codex.setKeepMacAwakeWhileBridgeRunsPreference(nextValue)
                Task { @MainActor in
                    await codex.syncBridgeKeepMacAwakePreferenceIfNeeded(showFailureInUI: true)
                }
            }
        )
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return "offline"
        case .connecting:
            return "connecting"
        case .loadingChats:
            return "loading chats"
        case .syncing:
            return "syncing"
        case .connected:
            return "connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay..."
        case .loadingChats:
            return "Loading chats..."
        case .syncing:
            return "Syncing workspace..."
        case .offline, .connected:
            return ""
        }
    }

    // MARK: - Actions

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }

    private func switchTrustedHost(_ host: CodexTrustedHostPresentation) {
        guard canSelectTrustedHost(host) else {
            return
        }

        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        switchingHostDeviceId = host.id

        Task { @MainActor in
            await codex.selectTrustedHost(deviceId: host.id)
            switchingHostDeviceId = nil
            if codex.hasReconnectCandidate {
                reconnectAction?()
            }
        }
    }

    private func forgetTrustedHost(_ host: CodexTrustedHostPresentation) {
        guard canForgetTrustedHost(host) else {
            return
        }

        HapticFeedback.shared.triggerImpactFeedback()
        forgettingHostDeviceId = host.id

        Task { @MainActor in
            if host.isActive, codex.isConnecting || codex.isConnected {
                await codex.disconnect()
            }
            codex.forgetTrustedMac(deviceId: host.id)
            forgettingHostDeviceId = nil
        }
    }

    private func canSelectTrustedHost(_ host: CodexTrustedHostPresentation) -> Bool {
        !host.isActive
            && switchingHostDeviceId == nil
            && forgettingHostDeviceId == nil
    }

    private func canForgetTrustedHost(_ host: CodexTrustedHostPresentation) -> Bool {
        (!host.isActive || !codex.isConnected)
            && switchingHostDeviceId == nil
            && forgettingHostDeviceId == nil
    }

    // Writes nicknames against the active trusted computer so switching pairs does not reuse the wrong alias.
    private func sidebarComputerNicknameBinding(for presentation: CodexTrustedPairPresentation) -> Binding<String> {
        Binding(
            get: { SidebarComputerNicknameStore.nickname(for: presentation.deviceId) },
            set: { SidebarComputerNicknameStore.setNickname($0, for: presentation.deviceId) }
        )
    }
}

private struct SettingsTrustedHostRow: View {
    let host: CodexTrustedHostPresentation
    let isSwitching: Bool
    let isForgetting: Bool
    let connectionStatusLabel: String?
    let canSelect: Bool
    let canForget: Bool
    let onSelect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemodexIcon.image(systemName: "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(host.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let detail = host.detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailingStatus

            Button(action: onForget) {
                if isForgetting {
                    ProgressView()
                } else {
                    RemodexIcon.image(systemName: "trash")
                        .font(AppFont.caption(weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canForget ? Color.red : Color.secondary.opacity(0.45))
            .disabled(!canForget)
            .accessibilityLabel("Forget \(host.name)")
        }
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isSwitching {
            ProgressView()
        } else if host.isActive {
            if let connectionStatusLabel {
                SettingsStatusPill(label: connectionStatusLabel.capitalized)
            }
            RemodexIcon.image(systemName: "checkmark")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Button("Switch", action: onSelect)
                .font(AppFont.caption(weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(canSelect ? Color.secondary : Color.secondary.opacity(0.45))
                .disabled(!canSelect)
        }
    }

    private var accessibilityLabel: String {
        host.isActive ? "\(host.name), selected host" : "Switch to \(host.name)"
    }
}
