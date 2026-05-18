// FILE: WorkspaceTextFilePreview.swift
// Purpose: Parses local file links and presents bridge-backed text file previews.
// Layer: Turn UI preview service
// Exports: WorkspaceTextFilePreviewRequest, WorkspaceTextFileLinkParser, WorkspaceTextFilePreviewScreen
// Depends on: Foundation, SwiftUI, CodexService workspace file APIs, TurnMarkdownTextRendering

import Foundation
import SwiftUI

struct WorkspaceTextFilePreviewRequest: Identifiable, Equatable, Sendable {
    let path: String
    let currentWorkingDirectory: String?
    let lineNumber: Int?

    var id: String {
        "\(path)|\(currentWorkingDirectory ?? "")|\(lineNumber ?? 0)"
    }

    var fileName: String {
        let basename = (path as NSString).lastPathComponent
        return basename.isEmpty ? path : basename
    }
}

nonisolated enum WorkspaceTextFileLinkParser {
    static func request(
        from url: URL,
        currentWorkingDirectory: String?
    ) -> WorkspaceTextFilePreviewRequest? {
        if url.isFileURL {
            return request(
                fromDestination: url.path,
                currentWorkingDirectory: currentWorkingDirectory
            )
        }

        if let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scheme.isEmpty {
            return nil
        }

        return request(
            fromDestination: url.relativeString,
            currentWorkingDirectory: currentWorkingDirectory
        )
    }

    static func request(
        fromDestination rawDestination: String,
        currentWorkingDirectory: String?
    ) -> WorkspaceTextFilePreviewRequest? {
        var candidate = rawDestination
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'`"))
        guard !candidate.isEmpty else {
            return nil
        }

        if candidate.lowercased().hasPrefix("file://") {
            guard let url = URL(string: candidate), url.isFileURL else {
                return nil
            }
            candidate = url.path
        } else {
            candidate = candidate.removingPercentEncoding ?? candidate
        }

        let split = splitTrailingLineColumn(from: candidate)
        candidate = split.path

        guard !candidate.hasPrefix("//") else {
            return nil
        }
        if candidate.hasPrefix("/") {
            return WorkspaceTextFilePreviewRequest(
                path: candidate,
                currentWorkingDirectory: currentWorkingDirectory,
                lineNumber: split.lineNumber
            )
        }

        guard candidate.hasPrefix("./") || candidate.hasPrefix("../"),
              let cwd = currentWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else {
            return nil
        }

        return WorkspaceTextFilePreviewRequest(
            path: candidate,
            currentWorkingDirectory: cwd,
            lineNumber: split.lineNumber
        )
    }

    private static func splitTrailingLineColumn(from value: String) -> (path: String, lineNumber: Int?) {
        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        let pattern = #"^(.+):(\d+)(?::\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: fullRange),
              match.numberOfRanges >= 3 else {
            return (value, nil)
        }

        let pathValue = nsValue.substring(with: match.range(at: 1))
        guard !pathValue.isEmpty,
              let lineNumber = Int(nsValue.substring(with: match.range(at: 2))),
              lineNumber > 0 else {
            return (value, nil)
        }

        return (pathValue, lineNumber)
    }
}

struct WorkspaceTextFilePreviewScreen: View {
    let request: WorkspaceTextFilePreviewRequest
    let onDismiss: () -> Void

    @Environment(CodexService.self) private var codex
    @State private var isLoading = false
    @State private var result: WorkspaceTextFileReadResult?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                Divider()

                content
            }
        }
        .task(id: request.id) {
            await loadPreview()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onDismiss()
            } label: {
                RemodexIcon.image(systemName: "xmark")
                    .font(AppFont.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .adaptiveGlass(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(result?.fileName ?? request.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(result?.path ?? request.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let lineNumber = request.lineNumber {
                        Text("Line \(lineNumber)")
                            .lineLimit(1)
                    }
                    if let result {
                        Text(Self.formattedByteCount(result.byteLength))
                            .lineLimit(1)
                    }
                }
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            previewContent(result)
        } else {
            loadingOrErrorContent
        }
    }

    @ViewBuilder
    private func previewContent(_ result: WorkspaceTextFileReadResult) -> some View {
        if result.isMarkdown {
            ScrollView {
                MarkdownTextView(
                    text: result.text,
                    profile: .assistantProse,
                    enablesSelection: true,
                    constrainsToAvailableWidth: true,
                    usesCaches: false
                )
                .padding(18)
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(result.text)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(18)
            }
        }
    }

    private var loadingOrErrorContent: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            if isLoading || errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                Text(request.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                RemodexIcon.image(systemName: "doc.text")
                    .font(AppFont.system(size: 32, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(request.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                Button {
                    Task { await loadPreview(force: true) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(AppFont.subheadline(weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .adaptiveGlass(.regular, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    @MainActor
    private func loadPreview(force: Bool = false) async {
        guard !isLoading else { return }
        if result != nil, !force {
            return
        }

        isLoading = true
        errorMessage = nil
        if force {
            result = nil
        }
        defer { isLoading = false }

        do {
            result = try await codex.readWorkspaceTextFile(
                path: request.path,
                cwd: request.currentWorkingDirectory
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
