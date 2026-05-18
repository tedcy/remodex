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
