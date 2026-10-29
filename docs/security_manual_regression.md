> Last updated: 2026-10-29

# SSH Security Manual Regression Checklist

Use this checklist before a security-sensitive release. Record concrete device
and server details, then mark each scenario pass/fail with notes.

## Test Matrix

- Test date:
- App version/build:
- Device and OS:
- Server types:
- Network:
- Tester:

## Host Key and Credentials

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Add a password server with an unknown host key, then cancel trust | Save/connect fails and the key is not persisted |  |  |
| Add the same server and trust the host key | Save/connect succeeds and future connects do not prompt again |  |  |
| Edit host or port | Stored host key fingerprint is cleared and next connect prompts again |  |  |
| Edit only username/password/private key | Stored host key fingerprint is preserved |  |  |
| Server host key changes after trust | Connect is blocked; old fingerprint is not overwritten |  |  |
| Plain SSH connect/disconnect/reconnect | Connects normally and host key policy is enforced every time |  |  |
| tmux connect/attach/disconnect | tmux attach works; unexpected disconnect asks app reconnect instead of background credential reuse |  |  |

## Android protected credentials

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Enable biometric protection on a saved connection | Strong biometric CryptoObject authentication is required; only a verified ciphertext envelope replaces the old credential keys |  |  |
| Open a protected connection editor | Password and private key remain hidden until one explicit complete-pair unlock; backgrounding or leaving clears the displayed secrets |  |  |
| Cancel authentication, close its route or background the Activity | No decrypted secret is published to the closed route, no stale envelope is committed, and a late native success cannot override cancellation |  |  |
| Change the host or credential revision while a biometric or Host Key confirmation is pending | Authentication fails closed before credentials reach the changed target; first explicit Host Key trust may enrich only that same immutable target |  |  |
| Invoke a noninteractive command or automatic reconnect using protected credentials | No implicit prompt or legacy credential fallback; the caller must return to an explicit foreground unlock flow |  |  |
| Edit protected credentials, then fail persistence | Opaque ciphertext snapshot restores the prior protected revision; no plaintext rollback record is created |  |  |
| Lose/invalidate the key, change biometric enrollment, remove screen lock, or corrupt the protected record | Typed locked/invalidated/corrupt failure; no replacement key or old plaintext is silently selected |  |  |
| Interrupt enabling protection after envelope verification but before old-key cleanup | Protected status remains authoritative; ordinary getters reject access and cleanup can be retried |  |  |
| Delete a protected connection with a storage/Keystore failure | Cleanup ledger/tombstone preserves the outstanding cleanup work; retry does not lose retired key revisions |  |  |
| Use Android below API 30 or a device without available strong biometrics | Feature is unavailable or reports a typed readiness failure; the App's existing unprotected behavior continues |  |  |
| Export a backup after protecting credentials | Password, private key and decrypted pair remain excluded from export and diagnostics |  |  |

## SFTP

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| First SFTP connect to unknown host key | User confirmation is required |  |  |
| Trusted host SFTP browse/download/preview/edit | Works normally |  |  |
| Fingerprint mismatch during SFTP | Operation is blocked |  |  |
| Keep a file/editor page open, then rebind the same connection ID to another host | The old page cannot preview, save, download, or delete on the new target |  |  |
| Preview/edit ordinary remote file | Local cache file is encrypted |  |  |
| Preview/edit secret path such as `.env` or `.ssh/id_rsa` | No local cache file is written |  |  |
| Trigger SFTP failures with sensitive remote/local paths and secret-bearing exception text | Logs contain only operation, stable code, counts, connection ID, and irreversible path hashes |  |  |
| Delete a saved connection | SFTP session, remembered path, and cache are cleared |  |  |

## Android document access (SAF)

Use public test documents on an emulator or a dedicated test device. A system
picker grant covers the selected document and requested mode only. SAF does not
mount SFTP servers in the system Files app; the independent DocumentsProvider
stage requires its own background connection and descriptor lifecycle.

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Cancel open/save, including while a prior selected document remains in use | No new transfer; prior document remains usable and its grant is unchanged |  |  |
| Open two different documents or read/write leases for one document | Each operation uses only its URI and mode; releasing one does not revoke another |  |  |
| Select a file from local storage and a cloud provider with unknown size | Bounded streaming preserves bytes; the caller's byte ceiling applies while reading |  |  |
| Move/delete the selected document or revoke access before copying | Typed failure, no remote upload and no success notification; temporary files and owned grants are released |  |  |
| Switch SFTP connection, host binding, or directory while the picker or source copy is pending | The pending upload fails closed instead of writing into the newly selected target |  |  |
| Cancel or destroy the Activity during a picker/copy | Pending calls terminate and late cache results are cleaned; no stale Activity publishes success |  |  |
| Export an empty file, then force provider I/O failure during a larger save | Empty file saves correctly; failed save never reports success, including repeated close; external provider may retain an empty/partial target |  |  |
| Send two same-name LAN documents, then wait for native hashing/transfer and retry a failed send | Distinct sandbox sources remain available to their history records and cannot overwrite each other |  |  |
| Attempt LAN export using a path outside the sandbox or a symlink pointing outside it | Export is denied, the write lease is aborted, and outside bytes never reach the document |  |  |
| Inspect diagnostics after provider exceptions containing document names/URIs | Only stable operation/error metadata is visible; document bytes, names, paths and URIs are absent |  |  |

## System Admin and Monitor

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Users/Services/Ports/Applications with unknown host key | Confirmation or blocking occurs before SSH execution |  |  |
| Trusted Linux server admin tabs | Data loads for the selected server only |  |  |
| Switch selected admin server | All non-monitor tabs use the shared selected server |  |  |
| Start monitor on untrusted server | Confirmation or blocking occurs before sampling |  |  |
| Trusted Linux/Windows monitor sampling | Sampling works and does not mix selected servers |  |  |

## AI Tools

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| `run_command` reads `~/.ssh/id_rsa`, `/etc/shadow`, `.env`, or environment | Blocked before execution |  |  |
| `run_command` reads logs such as `journalctl` | Requires user approval |  |  |
| `run_command` uses a lookalike diagnostic name such as `lswhatever` or `cmd /c dirx` | Requires user approval; prefix matching cannot mark it read-only |  |  |
| PowerShell uses `-EncodedCommand`, `-File`, a non-allowlisted first cmdlet, or a write-capable pipeline cmdlet | Requires user approval; only exact diagnostic cmdlets and read-only pipeline segments are read-only |  |  |
| SFTP AI read/download ordinary path | Requires user approval |  |  |
| SFTP AI read/download secret path | Blocked before execution |  |  |
| External MCP in `reviewConfiguredTools` with a configured risky Tool | Enters approval queue only when dynamic approval request exists |  |  |
| External MCP in `reviewConfiguredTools` with an unconfigured Tool | Executes only after hard checks; no queue entry |  |  |
| External MCP Tool not selected for exposure | Omitted from `tools/list`; known-name `tools/call` is denied before approval or execution |  |  |
| Local MCP Console exposure change | Takes effect without server restart and rejects pending MCP approvals |  |  |
| External MCP in `trustedAgent` with a bound target | Executes through target-bound `executeApproved`; queue remains empty |  |  |
| Switching MCP mode or regenerating Token with pending approvals | All pending requests rejected; none auto-execute |  |  |
| MCP handler/server/activity persistence throws an exception containing a token | JSON-RPC, UI state, and logs expose only stable error codes and error type; token and stack are absent |  |  |
| Unknown host key from AI tool path | Not auto-trusted |  |  |
| Fingerprint mismatch from AI tool path | Blocked |  |  |
| WebView reads localhost/private/metadata/file/data/javascript URL | Blocked |  |  |
| Public WebView URL resolves to mixed public/private answers, redirects to private/metadata, or rebinds on a later hop | Blocked before the private address is connected; every hop is resolved again and pinned to its validated IP |  |  |
| Proxied WebView page contains remote scripts/images/forms or a forged `data:text/html` navigation | Only escaped text and validated links render; no remote subresource loads and the forged navigation is blocked |  |  |
| WebView page contains password/token/secret form | Text is not returned to AI |  |  |

## Backup, Logs, and Android Background

| Scenario | Expected result | Result | Notes |
| --- | --- | --- | --- |
| Export backup | Passwords, private keys, API keys, and tokens are absent |  |  |
| Import hand-edited backup with credentials/API keys | Credentials are ignored and secure-storage keys are cleared |  |  |
| Import oversized/malformed backup | Import is rejected |  |  |
| Logs include Authorization/Cookie/token/private key/URL query secret | UI and `app.log` show redacted values only |  |  |
| Android background SSH starts | WakeLock/WifiLock are acquired with timeout |  |  |
| Disconnect/stop/failure paths | Locks are released or time out |  |  |
| Background notification default | Server names are hidden unless the setting is enabled |  |  |

## Known Issues

- None recorded.
