// FILE: workspace-file.test.js
// Purpose: Verifies bridge-side local text file previews stay scoped and size-safe.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/workspace-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { pathToFileURL } = require("url");
const { handleWorkspaceMethod } = require("../src/workspace-handler");

const MAX_TEXT_FILE_READ_BYTES = 2 * 1024 * 1024;

function tempDir(t, prefix = "remodex-file-") {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function gitWorkspace(t) {
  const dir = tempDir(t);
  execFileSync("git", ["init"], { cwd: dir, stdio: "ignore" });
  return dir;
}

async function assertWorkspaceError(callback, errorCode) {
  await assert.rejects(
    callback,
    (err) => {
      assert.equal(err.errorCode, errorCode);
      return true;
    }
  );
}

test("workspace/readFile returns text data for a file inside a git workspace", async (t) => {
  const workspace = gitWorkspace(t);
  const filePath = path.join(workspace, "README.md");
  fs.writeFileSync(filePath, "# Notes\n\nHello from Remodex.\n");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: workspace,
    path: filePath,
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.fileName, "README.md");
  assert.equal(result.mimeType, "text/markdown");
  assert.equal(result.kind, "text");
  assert.equal(result.byteLength, fs.statSync(filePath).size);
  assert.equal(typeof result.mtimeMs, "number");
  assert.equal(result.text, "# Notes\n\nHello from Remodex.\n");
  assert.equal(result.truncated, false);
});

test("workspace/readFile accepts relative percent-encoded paths with line suffixes", async (t) => {
  const workspace = gitWorkspace(t);
  const docsDir = path.join(workspace, "Docs");
  fs.mkdirSync(docsDir);
  const filePath = path.join(docsDir, "hello file.md");
  fs.writeFileSync(filePath, "line 1\nline 2\n");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: workspace,
    path: "Docs/hello%20file.md:12:3",
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.text, "line 1\nline 2\n");
});

test("workspace/readFile accepts file URLs", async (t) => {
  const workspace = gitWorkspace(t);
  const filePath = path.join(workspace, "notes.txt");
  fs.writeFileSync(filePath, "plain text");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: workspace,
    path: pathToFileURL(filePath).toString(),
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.mimeType, "text/plain");
  assert.equal(result.text, "plain text");
});

test("workspace/readFile allows files inside a safe non-git cwd", async (t) => {
  const workspace = tempDir(t);
  const filePath = path.join(workspace, "data.json");
  fs.writeFileSync(filePath, "{\"ok\":true}\n");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: workspace,
    path: "data.json",
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.mimeType, "application/json");
  assert.equal(result.text, "{\"ok\":true}\n");
});

test("workspace/readFile rejects broad cwd roots", async (t) => {
  const homeChild = fs.mkdtempSync(path.join(os.homedir(), "remodex-file-"));
  const filePath = path.join(homeChild, "notes.txt");
  fs.writeFileSync(filePath, "secret");
  t.after(() => {
    fs.rmSync(homeChild, { recursive: true, force: true });
  });

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: os.homedir(),
      path: filePath,
    }),
    "file_path_not_allowed"
  );
});

test("workspace/readFile rejects paths outside the workspace", async (t) => {
  const workspace = gitWorkspace(t);
  const externalDir = tempDir(t, "remodex-file-external-");
  const externalPath = path.join(externalDir, "secret.txt");
  fs.writeFileSync(externalPath, "secret");

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: externalPath,
    }),
    "file_path_not_allowed"
  );
});

test("workspace/readFile rejects symlink escapes", async (t) => {
  const workspace = gitWorkspace(t);
  const externalDir = tempDir(t, "remodex-file-secret-");
  const externalPath = path.join(externalDir, "secret.txt");
  const symlinkPath = path.join(workspace, "linked-secret.txt");
  fs.writeFileSync(externalPath, "secret");
  fs.symlinkSync(externalPath, symlinkPath);

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: symlinkPath,
    }),
    "file_path_not_allowed"
  );
});

test("workspace/readFile rejects unsupported file types", async (t) => {
  const workspace = gitWorkspace(t);
  const filePath = path.join(workspace, "preview.png");
  fs.writeFileSync(filePath, "not read through readFile");

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: filePath,
    }),
    "unsupported_file_type"
  );
});

test("workspace/readFile rejects oversized text files", async (t) => {
  const workspace = gitWorkspace(t);
  const filePath = path.join(workspace, "large.log");
  fs.writeFileSync(filePath, Buffer.alloc(MAX_TEXT_FILE_READ_BYTES + 1, "a"));

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: filePath,
    }),
    "file_too_large"
  );
});

test("workspace/readFile rejects directories and missing files", async (t) => {
  const workspace = gitWorkspace(t);
  const directoryPath = path.join(workspace, "folder.txt");
  fs.mkdirSync(directoryPath);

  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: directoryPath,
    }),
    "not_a_file"
  );
  await assertWorkspaceError(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: workspace,
      path: path.join(workspace, "missing.md"),
    }),
    "file_not_found"
  );
});
