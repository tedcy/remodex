// FILE: WorkspaceTextFilePreview.swift
// Purpose: Parses local file links and presents bridge-backed text file previews.
// Layer: Turn UI preview service
// Exports: WorkspaceTextFilePreviewRequest, WorkspaceTextFileLinkParser, WorkspaceTextFilePreviewScreen
// Depends on: Foundation, SwiftUI, CodexService workspace file APIs, TurnMarkdownTextRendering

import Foundation
import SwiftUI
import UIKit

struct WorkspaceTextFilePreviewRequest: Identifiable, Equatable, Sendable {
    let path: String
    let currentWorkingDirectory: String?
    let lineNumber: Int?

    var id: String {
        "\(path)|\(currentWorkingDirectory ?? "")|\(lineNumber ?? 0)"
    }

    var fileName: String {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalizedPath as NSString).lastPathComponent
        return basename.isEmpty ? path : basename
    }
}

private struct WorkspaceTextFileLine: Identifiable, Equatable {
    let number: Int
    let text: String

    var id: Int { number }
}

nonisolated enum WorkspaceTextFileLinkParser {
    static func request(
        from url: URL,
        currentWorkingDirectory: String?
    ) -> WorkspaceTextFilePreviewRequest? {
        if url.isFileURL {
            var destination = url.path
            if let fragmentLineNumber = lineNumber(fromFragment: url.fragment) {
                destination += "#L\(fragmentLineNumber)"
            }
            return request(fromDestination: destination, currentWorkingDirectory: currentWorkingDirectory)
        }

        if let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scheme.isEmpty {
            if isWindowsDriveScheme(scheme) {
                return request(
                    fromDestination: url.relativeString,
                    currentWorkingDirectory: currentWorkingDirectory
                )
            }
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

        var urlFragmentLineNumber: Int?
        if candidate.lowercased().hasPrefix("file://") {
            guard let url = URL(string: candidate), url.isFileURL else {
                return nil
            }
            urlFragmentLineNumber = lineNumber(fromFragment: url.fragment)
            candidate = url.path
        } else {
            candidate = candidate.removingPercentEncoding ?? candidate
        }

        let split = splitTrailingLineReference(from: candidate)
        candidate = split.path
        let lineNumber = urlFragmentLineNumber ?? split.lineNumber

        guard !hasNetworkURLScheme(candidate) else { return nil }
        guard !candidate.hasPrefix("//") else { return nil }
        if isWindowsAbsolutePath(candidate) {
            return WorkspaceTextFilePreviewRequest(
                path: candidate,
                currentWorkingDirectory: currentWorkingDirectory,
                lineNumber: lineNumber
            )
        }
        if candidate.hasPrefix("/") {
            return WorkspaceTextFilePreviewRequest(
                path: candidate,
                currentWorkingDirectory: currentWorkingDirectory,
                lineNumber: lineNumber
            )
        }

        guard isRelativeWorkspacePath(candidate, lineNumber: lineNumber),
              let cwd = currentWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else {
            return nil
        }

        return WorkspaceTextFilePreviewRequest(
            path: candidate,
            currentWorkingDirectory: cwd,
            lineNumber: lineNumber
        )
    }

    private static func splitTrailingLineReference(from value: String) -> (path: String, lineNumber: Int?) {
        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        let pattern = #"^(.+?)(?::(\d+)(?::\d+)?|#L(\d+)(?:-L?\d+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: fullRange),
              match.numberOfRanges >= 4 else {
            return (value, nil)
        }

        let pathValue = nsValue.substring(with: match.range(at: 1))
        let lineRange = match.range(at: 2).location != NSNotFound
            ? match.range(at: 2)
            : match.range(at: 3)
        guard !pathValue.isEmpty,
              lineRange.location != NSNotFound,
              let lineNumber = Int(nsValue.substring(with: lineRange)),
              lineNumber > 0 else {
            return (value, nil)
        }

        return (pathValue, lineNumber)
    }

    private static func lineNumber(fromFragment fragment: String?) -> Int? {
        guard let fragment, !fragment.isEmpty else {
            return nil
        }

        let nsFragment = fragment as NSString
        let fullRange = NSRange(location: 0, length: nsFragment.length)
        let pattern = #"^L(\d+)(?:-L?\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fragment, range: fullRange),
              match.numberOfRanges >= 2,
              let lineNumber = Int(nsFragment.substring(with: match.range(at: 1))),
              lineNumber > 0 else {
            return nil
        }

        return lineNumber
    }

    private static func isRelativeWorkspacePath(_ candidate: String, lineNumber: Int?) -> Bool {
        candidate.hasPrefix("./")
            || candidate.hasPrefix("../")
            || candidate.hasPrefix(".\\")
            || candidate.hasPrefix("..\\")
            || (candidate.contains("/") && !candidate.hasPrefix("~"))
            || (candidate.contains("\\") && !candidate.hasPrefix("~"))
            || (lineNumber != nil && isBareFileName(candidate))
    }

    private static func isBareFileName(_ candidate: String) -> Bool {
        !candidate.contains("/")
            && !candidate.contains("\\")
            && !candidate.hasPrefix("~")
            && !((candidate as NSString).pathExtension.isEmpty)
    }

    private static func hasNetworkURLScheme(_ candidate: String) -> Bool {
        let nsCandidate = candidate as NSString
        let fullRange = NSRange(location: 0, length: nsCandidate.length)
        let pattern = #"^[A-Za-z][A-Za-z0-9+.-]*://"#
        return (try? NSRegularExpression(pattern: pattern))?
            .firstMatch(in: candidate, range: fullRange) != nil
    }

    private static func isWindowsDriveScheme(_ scheme: String) -> Bool {
        guard scheme.count == 1, let scalar = scheme.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isWindowsAbsolutePath(_ candidate: String) -> Bool {
        let nsCandidate = candidate as NSString
        let fullRange = NSRange(location: 0, length: nsCandidate.length)
        let pattern = #"^[A-Za-z]:(?!//)[\\/].+"#
        return (try? NSRegularExpression(pattern: pattern))?
            .firstMatch(in: candidate, range: fullRange) != nil
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
        if result.isMarkdown, request.lineNumber == nil {
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
            codePreviewContent(result)
        }
    }

    @ViewBuilder
    private func codePreviewContent(_ result: WorkspaceTextFileReadResult) -> some View {
        let lines = Self.codeLines(from: result.text)
        let targetLineNumber = request.lineNumber.flatMap { requestedLine in
            lines.contains { $0.number == requestedLine } ? requestedLine : nil
        }

        if let targetLineNumber {
            GeometryReader { geometry in
                let lineNumberWidth = Self.lineNumberColumnWidth(for: lines.count)
                let contentWidth = max(
                    geometry.size.width,
                    Self.codePreviewContentWidth(lines: lines, lineNumberWidth: lineNumberWidth)
                )

                ScrollView(.horizontal) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines) { line in
                                    codeLineRow(
                                        line,
                                        lineNumberWidth: lineNumberWidth,
                                        isTarget: line.number == targetLineNumber
                                    )
                                    .id(line.number)
                                }
                            }
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .frame(width: contentWidth, height: geometry.size.height)
                        .onAppear {
                            scrollToTargetLine(targetLineNumber, proxy: proxy)
                        }
                        .onChange(of: targetLineNumber) { _, nextTarget in
                            scrollToTargetLine(nextTarget, proxy: proxy)
                        }
                    }
                    .frame(width: contentWidth, height: geometry.size.height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
        } else {
            plainCodePreviewContent(result.text)
        }
    }

    private func plainCodePreviewContent(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? " " : text)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(18)
        }
    }

    private func codeLineRow(
        _ line: WorkspaceTextFileLine,
        lineNumberWidth: CGFloat,
        isTarget: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(line.number)")
                .font(AppFont.mono(.caption2))
                .foregroundStyle(isTarget ? .primary : .tertiary)
                .frame(width: lineNumberWidth, alignment: .trailing)
                .textSelection(.disabled)

            Text(line.text.isEmpty ? " " : line.text)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .background {
            if isTarget {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }

    private func scrollToTargetLine(
        _ lineNumber: Int?,
        proxy: ScrollViewProxy
    ) {
        guard let lineNumber else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(lineNumber, anchor: .top)
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

    private static func codeLines(from text: String) -> [WorkspaceTextFileLine] {
        let rawLines = text.components(separatedBy: .newlines)
        let displayLines = rawLines.isEmpty ? [""] : rawLines
        return displayLines.enumerated().map { index, line in
            WorkspaceTextFileLine(number: index + 1, text: line)
        }
    }

    private static func lineNumberColumnWidth(for lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(1, lineCount)).count)
        return CGFloat(digits) * 8 + 12
    }

    private static func codePreviewContentWidth(
        lines: [WorkspaceTextFileLine],
        lineNumberWidth: CGFloat
    ) -> CGFloat {
        let textFont = AppFont.monoUIFont(size: 11, textStyle: .caption1)
        let widestCodeText = lines
            .lazy
            .map { line in
                codeLineTextWidth(line.text.isEmpty ? " " : line.text, font: textFont)
            }
            .max() ?? 0

        return ceil(18 + lineNumberWidth + 12 + widestCodeText + 14)
    }

    private static func codeLineTextWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
