// FILE: WorkspaceTextFilePreviewTests.swift
// Purpose: Verifies local text file preview link parsing and bridge RPC decoding.
// Layer: Unit Test
// Exports: WorkspaceTextFilePreviewTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class WorkspaceTextFilePreviewTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testParserAcceptsFileURLsAndLineSuffixes() {
        let request = WorkspaceTextFileLinkParser.request(
            from: URL(string: "file:///tmp/hello%20file.md:42:7")!,
            currentWorkingDirectory: "/repo"
        )

        XCTAssertEqual(request?.path, "/tmp/hello file.md")
        XCTAssertEqual(request?.currentWorkingDirectory, "/repo")
        XCTAssertEqual(request?.lineNumber, 42)
    }

    func testParserAcceptsAbsoluteAndRelativeLocalPaths() {
        let absolute = WorkspaceTextFileLinkParser.request(
            fromDestination: "/repo/Docs/plan%20notes.md:8",
            currentWorkingDirectory: "/repo"
        )
        let relative = WorkspaceTextFileLinkParser.request(
            fromDestination: "../Docs/plan.md",
            currentWorkingDirectory: "/repo/App"
        )

        XCTAssertEqual(absolute?.path, "/repo/Docs/plan notes.md")
        XCTAssertEqual(absolute?.lineNumber, 8)
        XCTAssertEqual(relative?.path, "../Docs/plan.md")
        XCTAssertEqual(relative?.currentWorkingDirectory, "/repo/App")
    }

    func testParserAcceptsCodePathLineReferences() {
        let relative = WorkspaceTextFileLinkParser.request(
            fromDestination: "Sources/App/File.swift:42",
            currentWorkingDirectory: "/repo"
        )
        let hashLine = WorkspaceTextFileLinkParser.request(
            fromDestination: "Sources/App/File.swift#L43-L50",
            currentWorkingDirectory: "/repo"
        )
        let fileURL = WorkspaceTextFileLinkParser.request(
            from: URL(string: "file:///repo/Sources/App/File.swift#L44")!,
            currentWorkingDirectory: "/repo"
        )
        let bareFile = WorkspaceTextFileLinkParser.request(
            fromDestination: "README.md:12",
            currentWorkingDirectory: "/repo"
        )
        let bareFileURL = WorkspaceTextFileLinkParser.request(
            from: URL(string: "./README.md:13")!,
            currentWorkingDirectory: "/repo"
        )

        XCTAssertEqual(relative?.path, "Sources/App/File.swift")
        XCTAssertEqual(relative?.currentWorkingDirectory, "/repo")
        XCTAssertEqual(relative?.lineNumber, 42)
        XCTAssertEqual(hashLine?.path, "Sources/App/File.swift")
        XCTAssertEqual(hashLine?.lineNumber, 43)
        XCTAssertEqual(fileURL?.path, "/repo/Sources/App/File.swift")
        XCTAssertEqual(fileURL?.lineNumber, 44)
        XCTAssertEqual(bareFile?.path, "README.md")
        XCTAssertEqual(bareFile?.currentWorkingDirectory, "/repo")
        XCTAssertEqual(bareFile?.lineNumber, 12)
        XCTAssertEqual(bareFileURL?.path, "./README.md")
        XCTAssertEqual(bareFileURL?.currentWorkingDirectory, "/repo")
        XCTAssertEqual(bareFileURL?.lineNumber, 13)
    }

    func testMarkdownFormatterLinkifiesCodePathLineReferences() {
        let rendered = MarkdownTextFormatter.renderableText(
            from: "Open `Sources/App/File.swift#L42`, `Sources/App/Other.swift:7`, and `README.md:12`.",
            profile: .assistantProse,
            usesCache: false
        )

        XCTAssertTrue(rendered.contains("[File.swift (line 42)](Sources/App/File.swift:42)"))
        XCTAssertTrue(rendered.contains("[Other.swift (line 7)](Sources/App/Other.swift:7)"))
        XCTAssertTrue(rendered.contains("[README.md (line 12)](./README.md:12)"))
    }

    func testParserIgnoresExternalAndBareRelativeLinks() {
        XCTAssertNil(WorkspaceTextFileLinkParser.request(
            from: URL(string: "https://example.com/README.md")!,
            currentWorkingDirectory: "/repo"
        ))
        XCTAssertNil(WorkspaceTextFileLinkParser.request(
            fromDestination: "README.md",
            currentWorkingDirectory: "/repo"
        ))
        XCTAssertNil(WorkspaceTextFileLinkParser.request(
            fromDestination: "../README.md",
            currentWorkingDirectory: nil
        ))
    }

    func testReadWorkspaceTextFileSendsBridgeRequestAndDecodesText() async throws {
        let service = makeService()
        var recordedMethod: String?
        var recordedParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethod = method
            recordedParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "path": .string("/repo/README.md"),
                    "fileName": .string("README.md"),
                    "mimeType": .string("text/markdown"),
                    "kind": .string("text"),
                    "byteLength": .integer(12),
                    "mtimeMs": .double(123.5),
                    "text": .string("# Hello\n"),
                    "truncated": .bool(false),
                ]),
                includeJSONRPC: false
            )
        }

        let result = try await service.readWorkspaceTextFile(path: "README.md", cwd: "/repo")

        XCTAssertEqual(recordedMethod, "workspace/readFile")
        XCTAssertEqual(recordedParams?["path"], .string("README.md"))
        XCTAssertEqual(recordedParams?["cwd"], .string("/repo"))
        XCTAssertEqual(recordedParams?["mode"], .string("preview"))
        XCTAssertEqual(result.path, "/repo/README.md")
        XCTAssertEqual(result.fileName, "README.md")
        XCTAssertEqual(result.mimeType, "text/markdown")
        XCTAssertTrue(result.isMarkdown)
        XCTAssertEqual(result.byteLength, 12)
        XCTAssertEqual(result.mtimeMs, 123.5)
        XCTAssertEqual(result.text, "# Hello\n")
        XCTAssertFalse(result.truncated)
    }

    private func makeService() -> CodexService {
        let suiteName = "WorkspaceTextFilePreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
