// FILE: qr.js
// Purpose: Prints the bridge pairing payload as both QR and a short terminal-friendly pairing code.
// Layer: CLI helper
// Exports: SHORT_PAIRING_CODE_ALPHABET, SHORT_PAIRING_CODE_LENGTH, createShortPairingCode, printQR
// Depends on: crypto, qrcode-terminal

const { randomBytes } = require("crypto");
const fs = require("fs");
const path = require("path");
const qrcode = require("qrcode-terminal");
const QRCode = require(path.join(path.dirname(require.resolve("qrcode-terminal")), "..", "vendor", "QRCode"));
const QRErrorCorrectLevel = require(path.join(path.dirname(require.resolve("qrcode-terminal")), "..", "vendor", "QRCode", "QRErrorCorrectLevel"));

const SHORT_PAIRING_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const SHORT_PAIRING_CODE_LENGTH = 10;

// Generates a short-lived human-friendly pairing token for reconnect flows.
function createShortPairingCode({
  length = SHORT_PAIRING_CODE_LENGTH,
  randomBytesImpl = randomBytes,
} = {}) {
  const resolvedLength = Number.isInteger(length) && length > 0 ? length : SHORT_PAIRING_CODE_LENGTH;
  const bytes = randomBytesImpl(resolvedLength);
  let code = "";
  for (let index = 0; index < resolvedLength; index += 1) {
    code += SHORT_PAIRING_CODE_ALPHABET[bytes[index] % SHORT_PAIRING_CODE_ALPHABET.length];
  }
  return code;
}

function normalizePairingSession(pairingSessionOrPayload) {
  if (pairingSessionOrPayload?.pairingPayload) {
    return {
      pairingPayload: pairingSessionOrPayload.pairingPayload,
      pairingCode: typeof pairingSessionOrPayload.pairingCode === "string"
        ? pairingSessionOrPayload.pairingCode.trim()
        : "",
    };
  }

  return {
    pairingPayload: pairingSessionOrPayload,
    pairingCode: "",
  };
}

function printQR(pairingSessionOrPayload, options = {}) {
  const { pairingPayload, pairingCode } = normalizePairingSession(pairingSessionOrPayload);
  const payload = JSON.stringify(pairingPayload);
  const sessionId = typeof pairingPayload?.sessionId === "string" ? pairingPayload.sessionId.trim() : "";
  const sessionIdShort = sessionId.length > 12 ? `${sessionId.slice(0, 8)}…` : sessionId;
  const env = options.env || process.env;

  writePairingQrHtml({ payload, pairingPayload, pairingCode, env });

  console.log("\nScan this QR with the iPhone:\n");
  qrcode.generate(payload, { small: true });
  if (pairingCode) {
    console.log("Or paste this pairing code in the iPhone app:\n");
    console.log(pairingCode);
  }
  console.log(`\nSession ID: ${sessionIdShort || "(none)"}`);
  console.log(`Device ID: ${pairingPayload.macDeviceId}`);
  console.log(`Expires: ${new Date(pairingPayload.expiresAt).toISOString()}\n`);

  if (shouldPrintPairingJson({ env, explicitValue: options.printPairingJson })) {
    // Opt-in only: this is the same bearer-like payload as the QR scan target.
    console.log("Pairing JSON (debug only; same sensitive bytes as the QR):\n");
    console.log(`${payload}\n`);
  }
}

function shouldPrintPairingJson({ env = process.env, explicitValue } = {}) {
  if (typeof explicitValue === "boolean") {
    return explicitValue;
  }

  const rawValue = env?.REMODEX_PRINT_PAIRING_JSON || env?.PHODEX_PRINT_PAIRING_JSON || "";
  return ["1", "true", "yes", "on"].includes(String(rawValue).trim().toLowerCase());
}

function writePairingQrHtml({ payload, pairingPayload, pairingCode, env = process.env }) {
  const outputPath = env?.REMODEX_PAIRING_QR_HTML || env?.PHODEX_PAIRING_QR_HTML || "";
  if (!outputPath) {
    return;
  }

  try {
    const expiresAt = Number.isFinite(pairingPayload?.expiresAt)
      ? new Date(pairingPayload.expiresAt).toISOString()
      : "";
    const html = [
      "<!doctype html>",
      '<html lang="en">',
      "<head>",
      '<meta charset="utf-8">',
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
      "<title>Remodex Pairing QR</title>",
      "<style>",
      "html,body{margin:0;min-height:100%;background:#f4f4f5;color:#111;font-family:Segoe UI,Arial,sans-serif}",
      "body{display:grid;place-items:center;padding:28px}",
      ".wrap{background:white;border:1px solid #d4d4d8;padding:24px;max-width:820px;text-align:center}",
      ".qr{display:block;width:min(78vmin,720px);height:min(78vmin,720px);margin:0 auto}",
      ".code{font:700 32px Consolas,monospace;letter-spacing:4px;margin-top:18px}",
      ".meta{font-size:15px;color:#52525b;margin-top:8px}",
      "</style>",
      "</head>",
      "<body>",
      '<main class="wrap">',
      createPairingQrSvg(payload),
      pairingCode ? `<div class="code">${escapeHtml(pairingCode)}</div>` : "",
      expiresAt ? `<div class="meta">Expires: ${escapeHtml(expiresAt)}</div>` : "",
      "</main>",
      "</body>",
      "</html>",
      "",
    ].join("\n");

    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, html, "utf8");
    console.log(`[remodex] Pairing QR image: ${outputPath}`);
  } catch (error) {
    console.warn(`[remodex] Could not write pairing QR image: ${error?.message || error}`);
  }
}

function createPairingQrSvg(payload) {
  const qr = new QRCode(-1, QRErrorCorrectLevel.L);
  qr.addData(payload);
  qr.make();

  const moduleCount = qr.getModuleCount();
  const quietZone = 4;
  const scale = 10;
  const size = (moduleCount + quietZone * 2) * scale;
  const rects = [
    `<rect width="${size}" height="${size}" fill="#fff"/>`,
  ];

  for (let row = 0; row < moduleCount; row += 1) {
    for (let col = 0; col < moduleCount; col += 1) {
      if (qr.isDark(row, col)) {
        rects.push(`<rect x="${(col + quietZone) * scale}" y="${(row + quietZone) * scale}" width="${scale}" height="${scale}"/>`);
      }
    }
  }

  return `<svg class="qr" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges" role="img" aria-label="Remodex pairing QR">${rects.join("")}</svg>`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

module.exports = {
  SHORT_PAIRING_CODE_ALPHABET,
  SHORT_PAIRING_CODE_LENGTH,
  createShortPairingCode,
  printQR,
  shouldPrintPairingJson,
};
