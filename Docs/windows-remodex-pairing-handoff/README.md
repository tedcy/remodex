# Windows Remodex Pairing Handoff

This folder captures the working remote Windows setup for Remodex pairing and autostart.

It is intentionally isolated from the product source tree because this was a local runtime fix on the remote Windows machine, not a general release change.

## Remote Context

- Remote Windows user: `tedcy`
- Remote runtime root: `C:\Users\tedcy\remodex`
- Desktop entry: `C:\Users\tedcy\Desktop\Remodex-Pairing-Code.cmd`
- Run logs: `C:\Users\tedcy\remodex\logs\bridge-autostart-YYYYMMDD-HHMMSS.log`
- QR page: `C:\Users\tedcy\remodex\logs\pairing-qr.html`
- Relay config: `C:\Users\tedcy\remodex\relay.env`
- Current SSH path used during setup: `ssh -p 2223 tedcy@127.0.0.1`

## Files

- `files/Remodex-Pairing-Code.cmd`
  - The only Remodex-related desktop entry the user should click.
  - Runs `restart-remodex-and-show-log.ps1`.

- `files/restart-remodex-and-show-log.ps1`
  - Stops the old Remodex bridge process tree.
  - Lets `start-remodex-local.ps1` load the relay from local config.
  - Creates a timestamped run log and clears the stale QR page.
  - Treats stale PID files as non-fatal.
  - Starts Remodex hidden in the background with `Win32_Process.Create`, so SSH-launched runs are not tied to the SSH session.
  - Waits for a fresh QR page and short pairing code from the current run.
  - Opens `pairing-qr.html` for scanning.
  - Prints the pairing code and waits for Enter unless `-NoPause` is passed.
  - Pressing Enter only closes the display window; the hidden bridge keeps running.

- `files/autostart-remodex.cmd`
  - The command run at Windows logon by the hidden VBS wrapper from the Startup folder.
  - Lets `start-remodex-local.ps1` load the relay from local config.
  - Exits when an existing `remodex.js run` process is already alive, so repeated logon starts do not create duplicate Remodex chains.
  - Writes a timestamped run log.
  - Keeps `REMODEX_PRINT_PAIRING_JSON=0` so logs do not contain the full bearer-like QR payload.

- `files/autostart-remodex-hidden.vbs`
  - Hidden wrapper used from the Windows Startup folder.

- `files/start-remodex-local.ps1`
  - Main local runtime launcher.
  - Finds Node/Codex, sets local Remodex environment, then runs the bridge.
  - Loads `%USERPROFILE%\remodex\relay.env` into process environment before computing the relay URL.
  - Uses the bundled local relay only when no configured relay is present or `REMODEX_RELAY` points at a local relay URL.

- `files/relay.env.example`
  - Sample local relay config. Copy it to `C:\Users\tedcy\remodex\relay.env` and replace the placeholder relay URL.
  - Do not commit the filled `relay.env` file.

- `files/phodex-bridge-src-qr.js`
  - Runtime copy of the bridge QR helper after the local fix.
  - Adds `REMODEX_PAIRING_QR_HTML`.
  - When that env var is set, the bridge writes a static HTML page containing a real SVG QR code.
  - The terminal QR is still printed by the bridge, but the restart script filters it from the display log because terminal QR rendering was unreliable for scanning.

## Restore Or Apply

Copy files back to these remote paths:

```text
files/Remodex-Pairing-Code.cmd              -> C:\Users\tedcy\Desktop\Remodex-Pairing-Code.cmd
files/restart-remodex-and-show-log.ps1      -> C:\Users\tedcy\remodex\restart-remodex-and-show-log.ps1
files/autostart-remodex.cmd                 -> C:\Users\tedcy\remodex\autostart-remodex.cmd
files/autostart-remodex-hidden.vbs          -> C:\Users\tedcy\remodex\autostart-remodex-hidden.vbs
files/start-remodex-local.ps1               -> C:\Users\tedcy\remodex\start-remodex-local.ps1
files/relay.env.example                     -> C:\Users\tedcy\remodex\relay.env (edit after copying)
files/phodex-bridge-src-qr.js               -> C:\Users\tedcy\remodex\runtime\phodex-bridge\src\qr.js
files/autostart-remodex-hidden.vbs          -> %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\RemodexBridgeAutoStart.vbs
```

The Startup folder entry should run:

```text
wscript.exe C:\Users\tedcy\remodex\autostart-remodex-hidden.vbs
```

SSH should use the same restart script as the desktop entry:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\tedcy\remodex\restart-remodex-and-show-log.ps1 -NoPause
```

## Expected User Flow

1. User double-clicks `Remodex-Pairing-Code.cmd` on the remote Windows desktop.
2. A browser or image viewer opens `pairing-qr.html`.
3. User scans that real QR page from the iPhone app.
4. If scanning fails, user pastes the pairing code printed in the terminal.
5. User presses Enter in the terminal to close the display window.
6. Background Remodex continues running.

## Verification

Run this on the remote Windows machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\tedcy\remodex\restart-remodex-and-show-log.ps1 -NoPause
```

Expected:

- `C:\Users\tedcy\remodex\logs\pairing-qr.html` exists.
- Terminal output includes `PAIRING CODE: ...`.
- Terminal output includes `QR image: C:\Users\tedcy\remodex\logs\pairing-qr.html`.
- Terminal output includes the relay URL loaded from `C:\Users\tedcy\remodex\relay.env`.

## Why This Exists

Terminal QR output was not reliable on the remote Windows console:

- wrong code page produced `鈻...` mojibake;
- UTF-8 fixed the mojibake but the terminal-rendered block QR still did not scan reliably;
- using a real SVG QR inside an HTML page avoids font, line-height, console zoom, and anti-aliasing problems.

The log display still shows the short pairing code as a fallback.

## Safety Notes

- Do not enable `REMODEX_PRINT_PAIRING_JSON=1` for normal use.
- Do not commit the filled `relay.env` file; it is local machine configuration.
- Do not commit logs from `C:\Users\tedcy\remodex\logs`; live pairing payloads and session identifiers can appear there.
- Pairing codes expire quickly and are not stable configuration.
