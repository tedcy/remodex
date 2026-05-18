// FILE: CodexService+WorkspaceFiles.swift
// Purpose: Fetches local workspace text files through the paired bridge on demand.
// Layer: Service Extension
// Exports: WorkspaceTextFileReadResult, CodexService.readWorkspaceTextFile
// Depends on: Foundation, CodexService, JSONValue

import Foundation

struct WorkspaceTextFileReadResult: Equatable, Sendable {
    let path: String
    let fileName: String
    let mimeType: String
    let kind: String
    let byteLength: Int
    let mtimeMs: Double?
    let text: String
    let truncated: Bool

    var isMarkdown: Bool {
        let lowerName = fileName.lowercased()
        return mimeType == "text/markdown"
            || lowerName.hasSuffix(".md")
            || lowerName.hasSuffix(".markdown")
            || lowerName == "readme"
    }
}

extension CodexService {
    func readWorkspaceTextFile(
        path: String,
        cwd: String?
    ) async throws -> WorkspaceTextFileReadResult {
        var params: RPCObject = [
            "path": .string(path),
            "mode": .string("preview"),
        ]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }

        let response = try await sendRequest(method: "workspace/readFile", params: .object(params))
        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("File preview response was missing a result.")
        }
        guard result["kind"]?.stringValue == "text",
              let text = result["text"]?.stringValue else {
            throw CodexServiceError.invalidResponse("File preview response did not include text.")
        }

        return WorkspaceTextFileReadResult(
            path: result["path"]?.stringValue ?? path,
            fileName: result["fileName"]?.stringValue ?? (path as NSString).lastPathComponent,
            mimeType: result["mimeType"]?.stringValue ?? "text/plain",
            kind: result["kind"]?.stringValue ?? "text",
            byteLength: result["byteLength"]?.intValue ?? Data(text.utf8).count,
            mtimeMs: result["mtimeMs"]?.doubleValue,
            text: text,
            truncated: result["truncated"]?.boolValue ?? false
        )
    }
}
