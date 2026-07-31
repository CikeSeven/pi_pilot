# P2P Self-Pairing Handoff

## Working Directory and Branch

- Worktree: `/home/sisct/Code/projects/FlutterProjects/PiPilot-p2p-self-pairing`
- Branch: `feature/p2p-self-pairing`
- Base implementation commit: `a331cb0 fix: isolate p2p pairing changes`
- Self-pairing protocol commit: `c83fe0c feat: allow p2p pairing without preregistration`

Do not switch branches in the original `PiPilot` worktree. It is being used by the separate
`feat/multi-device-state` work. Continue only in this dedicated worktree.

## Goal

Remove server-side device preregistration. A bridge host creates an in-memory room using its
`deviceId` and pairing Key. A phone joins only when it presents the same `deviceId` and Key.
The rendezvous server validates Key strength and keeps only a SHA-256 digest in room state.

## Completed

- Removed the `devices` map from `RendezvousConfig` and `rendezvous/config.example.json`.
- Added `rendezvous/src/key_policy.ts`:
  - pairing Key: 16-128 printable ASCII characters;
  - at least three of lowercase, uppercase, digits, and symbols;
  - device ID: `^[A-Za-z0-9._-]{3,64}$`.
- Changed rendezvous hello authentication:
  - host sends `{ type, role, deviceId, secret }`;
  - server validates the device ID and Key policy;
  - server stores only `sha256(secret)` in the in-memory room;
  - guest sends the same fields and is compared with `timingSafeEqual`;
  - no Key is written to disk or logs.
- Updated bridge and Flutter signaling clients to send `secret` in hello.
- Updated bridge, rendezvous, and Flutter signaling tests for the new protocol.
- Updated `bridge/README.md` with the no-preregistration setup, Key policy, WSS requirement,
  and security implications.

## Verification Already Run

- `cd rendezvous && npm run typecheck && npm test`: 8/8 passed.
- `cd bridge && npm run typecheck && npm test`: 107/107 passed.
- `flutter test test/p2p_signaling_test.dart`: 23/23 passed.
- `git diff --check`: passed before the protocol commit.

A full Flutter test run in the shared worktree failed because the concurrent multi-device work
had changed `PiSessionNotifier.connect` and providers without updating all callers. Those errors
were unrelated to this branch. Re-run the full suite from this isolated worktree after finishing.

## Remaining Work

1. Add shared Flutter-side policy helpers, preferably in `lib/core/p2p_signaling.dart`, mirroring
   the server's device ID and pairing Key rules. Add focused Dart tests for all boundaries.
2. Update `lib/ui/settings/settings_sections.dart`:
   - reject invalid device IDs while P2P is enabled;
   - reject Keys outside 16-128 printable ASCII characters or with fewer than three classes;
   - preserve the Key exactly rather than trimming it silently;
   - replace the old `devices` table hint with self-pairing wording.
3. Consider validating bridge configuration before opening the signaling socket so weak Keys fail
   with a clear local log instead of repeated server reconnect rejection. Keep server validation
   authoritative.
4. Add `rendezvous/README.md` with:
   - deployment and reverse-proxy example;
   - a config example without `devices`;
   - the Key policy;
   - explicit statement that all devices are accepted dynamically;
   - WSS and operator-visibility warning;
   - optional STUN/TURN setup.
5. Search for stale protocol wording and fields:

   ```bash
   rg -n "devices 表|devices table|unknown_device|bad_secret|挑战-应答|永不上行|pairingResponse|config\\.devices" \
     bridge lib rendezvous test -g '!node_modules/**'
   ```

6. Run formatting and full verification:

   ```bash
   dart format lib test
   flutter test
   cd bridge && npm run typecheck && npm test
   cd ../rendezvous && npm run typecheck && npm test
   cd .. && git diff --check
   ```

7. Commit remaining UI, documentation, and test changes on `feature/p2p-self-pairing` only.

## Compatibility and Security Notes

- This changes the signaling wire protocol. Old clients send `response`; new clients send
  `secret`. Bridge, App, and rendezvous must be deployed together unless explicit compatibility
  handling is added.
- Public signaling must use authenticated WSS. Plain `ws://` remains allowed only for loopback
  development by the App and bridge URL validators.
- The rendezvous process receives the Key in the WSS hello frame. It does not persist or log it,
  but the signaling operator can inspect process memory or traffic after TLS termination.
- Device IDs are first-come, first-served while a host is online. After the host disconnects, the
  room is deleted and another host can claim the same device ID with any compliant Key. This is
  intentional for no-preregistration operation and should be documented for users.
- One host may serve multiple phones. Only one host can hold a device ID at a time.
- `bridge.token` still authenticates access to the hub over the DataChannel and is separate from
  the P2P pairing Key.
