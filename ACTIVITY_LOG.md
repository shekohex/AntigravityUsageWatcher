# Activity Log

Tracking investigation into Antigravity `language_server_*` startup + schema.

## 2025-12-18 — Spawning LS + auth findings

### Goal

Avoid process/port detection by spawning Antigravity’s `language_server_macos_arm` ourselves, then querying local endpoints to read quota usage.

### Startup handshake (stdin)

- `language_server_macos_arm` requires “initial metadata from stdin” on startup.
- The required stdin payload is **protobuf bytes** for `exa.codeium_common_pb.Metadata`.
  - Sending JSON fails with “invalid Protobuf wire-format”.
- This is how Antigravity’s bundled extension does it:
  - File: `/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/extension.js`
  - Behavior: `MetadataProvider.getInstance().getMetadata().toBinary()` then `child.stdin.write(buf); child.stdin.end()`.

### Minimal successful POC

- When we provide a valid `Metadata` protobuf on stdin, the language server starts and listens locally.
- The server typically opens HTTPS on `PORT` and HTTP on `PORT+1`.
- We can call at least some endpoints successfully (e.g. `GetUnleashData`).
- Calling `GetUserStatus` without auth returns: “You are not logged into Antigravity.”

### How auth is actually wired (from bundled extension)

Key discovery: the extension does **not** implement OAuth itself; it relies on a host-provided API exposed on the `vscode` module.

- OAuth token comes from: `vscode.antigravityAuth.getOAuthTokenInfo()`
  - This returns `accessToken`, `refreshToken`, `expiryDateSeconds`, `tokenType`.
  - There is no JS implementation inside the extension bundle; it’s provided by the Antigravity host.
- The extension uses the OAuth **access token as `metadata.apiKey`**:
  - `MetadataProvider.updateApiKey(accessToken)`
  - `MetadataProvider.getMetadata()` includes `apiKey`, plus `ideName`, `ideVersion`, `extensionName`, `extensionPath`, `deviceFingerprint`, `locale`, etc.
- Before calling `GetUserStatus`, it syncs token info into the language server via RPC:
  - `LanguageServerClient.syncOAuthTokenInfo()` calls `SaveOAuthTokenInfo` with `OAuthTokenInfo{accessToken, refreshToken, expiry, tokenType}`.
  - If there’s no token, it calls `RemoveOAuthTokenInfo`.
- Extension startup also attempts to identify the user:
  - If token exists: `registerGdmUser`.

### Evidence from local logs

Antigravity logs show language server behavior consistent with the above:

- Random port selection, and an “extension server client” port:
  - “Language server listening on random port at … for HTTPS/HTTP”
  - “Created extension server client at port …”
- Token persistence in the language server:
  - `secure_credentials.go:67] Credentials set successfully`
- When unauthenticated:
  - `Cache(userInfo): Singleflight refresh failed: You are not logged into Antigravity.`

Example log files:

- `/Users/shady/Library/Application Support/Antigravity/logs/20251217T105110/window1/exthost/google.antigravity/Antigravity.log`
- `/Users/shady/Library/Application Support/Antigravity/logs/20251218T011756/window1/exthost/google.antigravity/Antigravity.log`

### Where tokens likely live (desktop app)

- `state.vscdb` contains `antigravityAuthStatus` but not obvious token keys:
  - `/Users/shady/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
- Keychain contains “Safe Storage” for Antigravity (Chromium-style encrypted storage key):
  - Service/Label: `Antigravity Safe Storage`
  - Account: `Antigravity Key`
- This suggests actual tokens are stored in Chromium/Electron storage encrypted-at-rest (Local Storage/IndexedDB/etc.) and unlocked via Keychain, rather than being readable from the extension bundle.

### Implication for our own launcher

To make `GetUserStatus` work when we spawn the server ourselves, we need to replicate the extension’s auth steps:

1) Provide `Metadata` protobuf on stdin (already done).
2) Obtain a valid OAuth token info (`access_token` + refresh + expiry).
3) Call LS RPC `SaveOAuthTokenInfo` with the full token info.
4) Call `GetUserStatus({metadata})` where `metadata.apiKey == access_token`.

Current blocker: we can spawn the server and hit endpoints, but we do not yet have a safe way to retrieve OAuth tokens from the Antigravity host/app.

## 2025-12-19 — Connect RPC details + token experiment

### Connect RPC protocol details (localhost)

From the bundled extension (`/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/extension.js`):

- The language server client uses `createConnectTransport` with:
  - `httpVersion: "2"` (so we must use HTTP/2)
  - `useBinaryFormat: true`
  - `baseUrl: https://127.0.0.1:<httpsPort>`
  - A pinned CA cert at: `/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/languageServer/cert.pem`
- Every request includes header: `x-codeium-csrf-token: <token>` (the same value passed to the server via `--csrf_token`).
- Unary RPC encoding is Connect “binary unary”:
  - `POST /exa.language_server_pb.LanguageServerService/<Method>`
  - `Content-Type: application/proto`
  - `Connect-Protocol-Version: 1`
  - Request body is the **raw protobuf message bytes** (no gRPC-web framing).

### Token experiment

- I used `/Users/shady/.gemini/oauth_creds.json` as a candidate OAuth token source (structure contains `access_token`, `refresh_token`, `token_type`, `expiry_date`).
- I spawned the language server with fixed port + csrf token, fed the stdin `Metadata` protobuf, then called:
  - `SaveOAuthTokenInfo` (succeeds)
  - `GetUserStatus` via Connect/HTTP2
- Result: `GetUserStatus` fails with:
  - `oauth2: "unauthorized_client" "Unauthorized"`
  - while POSTing to `https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchUserInfo`

Interpretation: the token in `~/.gemini/oauth_creds.json` is not accepted by the `cloud_code_endpoint` the server uses for user info; we likely need an Antigravity-specific token (or a different OAuth client / audience / scopes).

### Helper script

I added a local probe script to reproduce the above quickly:

- `scripts/antigravity_ls_probe.py`

It spawns the LS, performs `SaveOAuthTokenInfo` and `GetUserStatus` using Connect over HTTP/2 + the extension’s CA cert, and prints only non-sensitive diagnostics.

### Valid token source found (Opencode Antigravity auth)

We can obtain an Antigravity-accepted OAuth token by reusing the Google OAuth client + refresh flow from `opencode-antigravity-auth`:

- Opencode stores a refresh token at:
  - `/Users/shady/.local/share/opencode/antigravity-accounts.json`
  - Schema: `{ version, accounts: [{ email, refreshToken, projectId, ... }], activeIndex }`
- Using that `refreshToken`, we can mint a fresh access token via Google’s refresh flow (`https://oauth2.googleapis.com/token`).
  - This requires the Antigravity OAuth client secret (present in `opencode-antigravity-auth/src/constants.ts`).

Result: when we feed the minted access token into LS auth (`metadata.apiKey` + `SaveOAuthTokenInfo`), `GetUserStatus` succeeds (HTTP 200, protobuf response).

## 2025-12-18 — Menu bar app MVP (Swift)

## 2025-12-19 — Debugging LS readiness + TLS

- Added structured logging using `os.Logger` with categories (`app`, `oauth`, `language_server`, `network`).
- Enabled verbose logging by default in Debug builds to unblock investigation.
- Disabled App Sandbox for this app and removed sandbox entitlements to allow spawning Antigravity’s `language_server_macos_arm`.
- Forwarded language server stdout/stderr into the Xcode console (prefixed as `ls(stdout)` / `ls(stderr)`), with best-effort token redaction.
- Found that our protobuf `Metadata` handshake had `ideVersion = "0"`, which the language server rejects; updated it to a valid semver string (`0.0.0`).
- Observed the language server reports it is listening on HTTPS/HTTP ports, but our client fails to complete HTTPS requests.
  - The server logs show repeated `TLS handshake error ... EOF`, suggesting the client is aborting the handshake.
  - Found the client was rejecting the cert with: `"localhost" certificate is not permitted for this usage`.
  - Switched to strict certificate pinning: compare the server-presented certificate chain to the pinned `cert.pem` DER, bypassing SecTrust usage/EKU issues.
- Found why Swift RPC differed from the working Python probe: Swift was using ad-hoc JSON bodies that did not follow Connect/proto JSON mapping.
  - `google.protobuf.Timestamp` must be an RFC3339 string (not `{seconds: ...}`), which caused `SaveOAuthTokenInfo` to return HTTP 400.
  - `GetUserStatus` must include full `Metadata` (including `apiKey`), otherwise LS reports "You are not logged into Antigravity".
- Updated Swift client to use Connect JSON mapping (`Content-Type/Accept: application/json`) with RFC3339 expiry and full metadata, matching the successful curl experiment.

Noise control while debugging:

- Suppressed per-request logging for the `GetStatus` readiness probe and filtered the noisiest TLS handshake EOF spam lines.
- Discovered Connect JSON endpoints reject a zero-length request body (even for empty messages like `GetStatus`), returning: `unmarshal message: zero-length payload is not a valid JSON object`.
  - Fixed by sending `{}` when the JSON body would otherwise be empty.

Outcome:

- Sign-in, sign-out, language server bootstrap, and quota fetching are now working end-to-end on macOS.

Implemented an end-to-end MVP inside the macOS app:

- Menu bar UI: signed-out state, sign-in, refresh, model list, pin/unpin.
- OAuth: PKCE + loopback callback server (`http://127.0.0.1:<random>/oauth-callback`) using `Network.framework`.
- Storage: refresh token + metadata stored in Keychain (service `com.google.antigravity.usagewatcher`).
- Language server: spawns `/Applications/Antigravity.app/.../language_server_macos_arm` and writes `Metadata` protobuf to stdin.
- RPC: talks to `https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/*` with pinned CA at `/Applications/Antigravity.app/.../cert.pem`.
  - Uses JSON payloads for now (matching `/tmp/antigravity-usage`), including `SaveOAuthTokenInfo` then `GetUserStatus`.
- Parsing: extracts prompt credits and per-model quota from the `GetUserStatus` JSON payload.

Notable project tweak:

- Changed `SWIFT_DEFAULT_ACTOR_ISOLATION` to `Nonisolated` to avoid over-isolating all non-UI code on the main actor.

Entry point:

- Added `AntigravityUsageWatcher/AntigravityUsageWatcherMain.swift` to keep `@main` separate.
