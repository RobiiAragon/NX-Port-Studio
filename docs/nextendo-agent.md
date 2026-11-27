# Nextendo agent for Mac

**Status: all three phases (credential broker, shared social for ports, and the hub) are implemented and unit-tested; I have not run them with a game yet.** I gave every Mac port one shared Nextendo session through a small XPC agent shipped inside NX Port Studio. iOS is out of scope: each iPhone app keeps its own integration ([mobile setup](reference/services.md#mobile-nextendo-setup-without-a-desktop-handoff)), because iOS has no resident helper process and no channel between separately signed apps. The mechanism and its checks are recorded in [the services reference](reference/services.md#every-mac-port-asks-for-keychain-access-and-renews-the-account-by-itself).

## Why

Before the agent, each Mac port was its own Nextendo client:

- **Every port read the Keychain item itself.** `read_credentials` in `dm/host/hle_nextendo_apple.m` and `NextendoKeychainStore` in `PortCore/NextendoAccount.swift` both open `org.nxnative.nextendo.account`. Ports are ad-hoc signed by default (`MAC_SIGN` in `scripts/build_ipa_from_nsp.py`), so each port, and each rebuild of a port, is a new code identity to the Keychain. That is why the [explicit access sheet](reference/services.md#explicit-mac-access-to-the-saved-nextendo-account) exists.
- **Every launch renewed.** `dm_mac_prepare_game_account` (`dm/mac/GameAccount.swift`) calls `prepareGameAccount(forceGameRefresh: true)` on each boot. Refresh-token rotation between processes is serialized only by the `account-renewal.lock` file lease.
- **Sign-out did not reach running ports.** The [passive presence entry](reference/services.md#passive-presence-publication-reads-a-protected-account) records that a sign-out in Studio had no notification channel to a running port.
- **Cold-launch presence can fail** until the game performs an explicit account read (same entry).
- **Nothing is online without a game.** Friends coming online, invitations and notification delivery are still open ([friends and presence](reference/services.md#nextendo-friends-and-sdk-application-presence)), and they need a process that stays alive between games.

## Goals and non-goals

Goals:

1. One owner of renewal for every Mac port: the agent. *(phase 1, done)*
2. Ports receive only what the host needs to sign in (the NEX record), never the refresh token. *(phase 1, done)*
3. Sign-out and account changes reach running ports at once. *(phase 1, done)*
4. One friends snapshot and one presence shared by every port; ports hold no OAuth bearer. *(phase 2, done; Studio reads it in phase 3)*
5. Studio shows friends online and friend requests, and the Mac notifies when no game is running; a session closed on the website signs this Mac out. *(phase 3, done)*

Non-goals:

- **Matchmaking and peer-to-peer.** They stay in the game's own Pia/NEX code over the host's sockets (`hle_net_backend.c`). The agent changes none of that.
- **Replacing the in-process path.** A port must keep working with no Studio installed: the Mac launcher already says "no Studio needed" (`dm/mac/Launcher.swift`). When the agent is missing, stopped or refuses a port, the port behaves exactly as before.
- iOS, Nintendo servers, console identities.

## Architecture

```
NX Port Studio.app
├── Contents/MacOS/NXPortStudio            UI: build, library, Nextendo page, sign-in and sign-out
├── Contents/Library/LoginItems/NX Port Studio Agent.app
│       windowless (LSUIElement), Swift, links PortCore (Sources/PortStudioAgent);
│       an app of its own so its notifications have a bundle
└── Contents/Library/LaunchAgents/org.nxnative.portstudio.agent.plist
        RunAtLoad, KeepAlive on a crash
        MachServices: org.nxnative.portstudio.agent        ports
                      org.nxnative.portstudio.agent.admin  Studio only

Port.app (host) ──XPC──► agent ──HTTPS──► nextendo.network
Studio UI       ──XPC──► agent
```

- **Packaging.** `macOS/NXPortStudio/scripts/package_app.sh` builds the agent app (bundle identifier `org.nxnative.portstudio.agent`), writes the launchd plist and signs the agent app before Studio. Once registered, launchd starts the agent at login, because the hub polls while no game runs.
- **Registration.** The Nextendo page has a **Keep Nextendo connected** switch (`StudioModel+NextendoAgent.swift`). It calls `SMAppService.agent(plistName:)`. If macOS asks for approval, the page links to Login Items. Turning it off unregisters the agent, and ports go back to signing in by themselves. A debug `swift run` has no plist, so the switch says it needs the packaged app. I checked on my Mac that `SMAppService` accepts the ad-hoc signed bundle and starts the agent without asking for approval. Three things I found doing that:
  - **A never-registered agent is `.notFound`.** `SMAppService` reports `.notFound`, not `.notRegistered`, for an agent that was never registered. So Studio decides that the agent is available from the plist and the agent app in its own bundle, and treats both statuses as off. Before, the switch stayed disabled.
  - **Updating Studio needs a new registration.** launchd keeps a launch constraint (`LWCR`, a cdhash list) for the agent that was registered. After Studio is replaced, launchd refuses the new agent: `Launch Constraint Violation`, exit 78 (`EX_CONFIG`). Studio stores the cdhash of the agent it registered (`NextendoAgentRegisteredCDHash` in its defaults). At launch, if the bundled agent differs, it unregisters and registers again. **Open, workaround:** registering right after the removal sometimes still keeps the old constraint, and I do not know why. So Studio checks that the agent answers `status` and, if it does not, removes and registers it again after 2 s, up to three times. Turning the switch off and on by hand clears it too.
  - **A cdhash needs only the code directory.** `NextendoAgentCode.cdhash(of:)` validates the signature with `kSecCSDoNotValidateResources`. With the default flags it hashed every sealed resource of a port, many GB each, and registering 6 installed ports took minutes. Without the resources it takes about 0.02 s per port. XPC checks the cdhash again on every connection.
- **Who touches the Keychain.** Studio still signs in and out itself, as before, and then reports the change to the agent (`accountDidChange`). For every port that connects, the agent does the boot renewal with the same `NextendoAccountService`, so the agent and Studio coordinate through the existing file lease. A port served by the agent reads no Keychain item and runs no renewal. macOS asks once for the agent instead of once per port and per rebuild. With an ad-hoc Studio, that becomes one prompt per Studio update; a Developer ID signature removes even that.

## Peer validation

The agent hands out a game credential, so every connection is checked by code signature, never by PID or bundle ID. The check is `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+) with a `cdhash H"…"` requirement:

- **Studio, administrator service.** At launch the agent reads the cdhash of the Studio bundle that contains it, four levels up from the agent app (`NextendoAgentServer.studioBundle`). Only that exact Studio can register ports and report account changes. Outside a signed `.app`, the agent refuses every administrator.
- **Studio checks the agent too.** Studio's client requires the cdhash of the agent app inside its own bundle.
- **Ports.** Studio registers each Mac port's cdhash after installing it (`MacPortBuildSession.install` → `registerPortWithNextendoAgent`). Turning the switch on also registers the ports already installed in `/Applications` and `~/Applications` (apps whose `Info.plist` has `DMPrimaryHost` and `DMTitleID`). A rebuilt port is registered again on install; the 512 most recent cdhashes are kept.
- **Where the allowlist lives.** It is the agent's own Keychain item, `org.nxnative.portstudio.agent.peers`, not a file another process could edit.
- **Unregistered ports.** A port that is not registered is refused, and it signs in by itself as before.
- **Team ID.** Ports signed with a Developer ID team (`MAC_SIGN`) are registered by cdhash like the rest. A team requirement is not implemented.
- **What a port does not check.** A port does not verify the agent's identity. A fake agent registered under the same Mach name could hand it a bogus record, which the host still validates, but the port sends the agent nothing secret.

## Protocol

`PortCore/NextendoAgent.swift`, compiled into Studio, the agent and every Mac port. No reply carries a refresh token or an access token. `protocolVersion` is 2, and the agent accepts only its own version. A port built for version 1 therefore keeps its own path, where its record still has the OAuth grant.

| Call | Side | What it does |
|---|---|---|
| `hello(version, titleID, gameVersion)` | port | Protocol check (`protocolVersion` 2). |
| `gameCredential(renew:)` | port | With `renew`, runs the same coalesced `prepareGameAccount(forceGameRefresh: true)` a port ran at boot; a failed renewal keeps the stored record. Replies with status, the schema-1 record **without** its `renewal` object (`encodedForPort`, at most 64 KiB) and the account generation. |
| `social(resource, body)` | port | One `me`, `friends` or `presence` request, which the agent sends with its own OAuth grant (scopes `identity`, `friends`, `presence`). Replies with status, HTTP status and the body on 2xx (at most 1 MiB). See [Shared social](#shared-social). |
| `accountChanged(generation)` | port, exported | The agent pushes this after Studio reports a change. The port fetches the record again without renewing. |
| `registerPeer(cdhash)` | Studio | Adds a port's code to the allowlist. |
| `accountDidChange()` | Studio | Bumps the generation, drops the old account's snapshots and presence, and pushes the generation to the connected ports. Studio sends it after sign-in, a new game credential and sign-out. The agent bumps the generation too, keeping the presence, when its own renewal replaces the stored record. |
| `status()` | Studio | Protocol version, registered ports, connected ports. |
| `friends()` | Studio | The account's friends body (images omitted), from the shared snapshot. |
| `answerFriendRequest(pid, accept)` | Studio | `POST /api/friends/accept` or `/decline` with `{pid}`; drops the shared snapshot. |
| `setNotifications(enabled)`, `notifications()` | Studio | The agent's notification switch, kept in its own preferences. Turning it on asks macOS for permission; a refusal leaves it off. |

Statuses: `ok`, `signedOut`, `unavailable`, `versionMismatch`, `refused`, `failed`.

## Host side

- `dm/mac/AgentClient.swift` is compiled into each port's `DMMacBootstrap.dylib` (`dm/mac/pack_app.py` `swift_sources`). It exports `dm_mac_agent_prepare` and `dm_mac_agent_credential`.
- `dm_mac_bundle_prepare_account` (`dm/host/bundle_mac.c`) asks the agent first, only in Nextendo/automatic mode, on the guest worker, for at most 5 s. If the agent answers `ok` or `signedOut`, the host installs the agent's record through `dm_nextendo_set_credential_provider` and skips its own renewal.
- **Signed out.** `signedOut` means Studio signed out, so the port does not fall back to the Keychain: it stays signed out like the rest.
- **No answer.** If the agent does not answer, refuses the port or reports a version mismatch, the port prints one `[RED] launcher:` line and runs its own path unchanged.
- **`DM_NEXTENDO_AGENT=0`** skips the agent.
- **Account API.** With the record, the host also installs `dm_nextendo_set_api_provider` (`dm_mac_agent_api`). The record has no OAuth grant, so in that mode `api_request` sends no bearer. It checks the same resource and body rules, then hands `me`, `friends` and `presence` to the agent. The guest thread is marked as waiting while the agent answers (at most 15 s).
  - `dm_nextendo_api_identity` binds the API caches to the NEX record instead of the grant.
  - Passive presence may read the memory provider when it has no snapshot yet, so a port can publish "playing" at boot.
  - Without the agent, all of this is unchanged.
- The provider copies the cached record; it never reads storage. On `accountChanged`, the client replaces the record and calls `dm_nextendo_account_invalidate_social()`, so passive presence stops using the old account. The host's `decode_credential` validates the record exactly as it validates the Keychain copy (`renewal` was already optional).

## Shared social

The agent is one Nextendo client for the account, so it arbitrates what the ports would otherwise do separately (`NextendoAgentAccount.social`):

- **Friends.** One snapshot for every port, at most 15 s old. Concurrent requests share one fetch, and a failed answer is not cached. Each port keeps its own 30 s cache in the host on top of that (`hle_nextendo_social_apple.m`).
- **Me.** Its answer is kept for the account's generation.
- **Presence.** Nextendo keeps one presence per account, so two open games used to overwrite each other every 45 s. The agent remembers each port's latest body and when it last changed.
  - What it sends is the most recently changed one.
  - A port's unchanged 45 s refresh keeps that presence alive instead of replacing it.
  - When the port whose presence is shown quits, the next newest is sent at once.
  - Without a port, nothing is sent and the provider expires the presence after 90 s, as it did when a game quit.
- **Renewal.** Before a request, if the access token expires within 60 s, the agent runs the shared, non-forced preparation. If that replaces the stored record, the agent pushes the new generation, so a long session never outlives its NEX proof.

## Hub

`NextendoAgentHub` runs inside the agent for as long as it runs. Nextendo has no push channel, so all of it is polling:

- **Friends.** Once a minute it reads the shared snapshot, the same one ports use, so a running game adds no request. Studio's **Friends** panel shows who is online, with the name of my installed port for their title, and incoming requests with **Accept** and **Decline**.
- **Notifications.** They are off until I turn them on in that panel. The agent then posts one when a friend comes online and one when a request arrives. The first snapshot of an account only sets what is already true, so signing in or starting the Mac notifies nothing. A friend who stays online is not notified again.
- **Backoff.** A 429 skips the next four polls, and a failure or a 5xx skips one.
- **Revocation.** While a game is open, each poll also asks `GET /api/session-status` with the game token. The [developer guide](https://wiki.nextendo.network/developers) documents that route for the NEX token. The server keys revocation on the device's play session and IP, and lists a closed session as revoked until it expires. So only a change that the agent sees itself, from `false` to `true`, counts. Then the agent signs this Mac out as Studio would, pushes the change to the open ports and, with notifications on, says so. A session that was closed earlier and still shows as revoked never signs a new account out.
- **Not done.** There is no menu bar item: the panel and the notifications cover what I need. Game invitations are not implemented, because the provider has no invitation route.

## What the mirror told me

I read my mirror of the NextendoNetwork account server (`nextendo-account`, snapshot of 2026-10-12, PolyForm Shield 1.0.0) for protocol facts only. I copied no code. Its license forbids using the software to provide a competing product, so I keep to facts and write my own implementation.

- **No push channel.** There is no WebSocket or event stream: friends and presence are polled (`/api/friends`, `/api/presence`), and a presence older than 90 s expires (`presenceTTL`). This matches what I [measured with Splatoon 3](reference/services.md#a-game-that-never-publishes-presence-stays-offline-to-its-friends).
- **Revocation.** `/api/session-status` returns `revoked` for the play session of this device's IP, and a revoked session stays listed until it is pruned after 45 days. Phase 3 polls it only while a game is open and acts only on a change it saw.
- **Friends.** `GET /api/friends` returns `{friends, requests, sent}`. Each presence carries `status`, `app_id`, `app_field` and `app_detail`, with no game name. `POST /api/friends/accept` and `/decline` take `{pid}`.
- **An older OAuth contract.** That snapshot's `/api/oauth/token` issues one-hour access tokens and no refresh token. The current [developer guide](https://wiki.nextendo.network/developers) documents refresh-token rotation, which is what Studio implements. I follow the live guide where the two differ.

## Phases

1. **Credential broker.** *Done in code.* I checked a packaged Studio with the switch on, and the agent registered again after an update. Remaining acceptance:
   - a registered port that gets its credential with no Keychain dialog;
   - a sign-out in Studio that reaches the open port;
   - a port without the agent behaving as before.
2. **Shared social.** *Done in code.* `me`, `friends` and presence go through the agent (`social`), with one friends snapshot and one presence for every port. `hle_nextendo_api_apple.m` has the agent transport, so ports hold no OAuth bearer. Phase 1 alone would have left an agent-served port without friends or presence, because its record has no grant. Remaining acceptance:
   - a friend list in a game served by the agent;
   - my presence seen by a friend;
   - two games open at once showing the newer one.
3. **Hub.** *Done in code.* See [Hub](#hub). I checked the Friends panel with a real friend in a game, the agent app's notification permission prompt, a notification the agent posted when a friend request arrived, and that request accepted from Studio (`POST /api/friends/accept` answered 200, and the request left the panel). Remaining acceptance:
   - a friend coming online while no game runs;
   - a session closed on the website while a game is open.

## Checks

These need no game:

- `swift test --filter NextendoAgentTests` (in `macOS/NXPortStudio`). It covers:
  - the port record (no renewal grant, NEX only, unexpired, size bound);
  - the requirement builder and the bounded allowlist;
  - account status from the store, including a failed renewal that keeps the stored record;
  - real XPC over anonymous listeners with the real code-signing check against the test process's own cdhash: a registered port gets its record and the pushed generation, while an unregistered port, a foreign administrator and an empty allowlist are refused;
  - an admin call that times out;
  - social: one shared friends snapshot with the agent's bearer and `images=0`, refused resources and bodies, account states and HTTP failures, presence selection across ports, caches cleared on an account change, and an expiring grant renewed once before the request, with the new record pushed.
- `python3 -m unittest dm/tools/tests/test_mac_game_account.py` runs the actual `bundle_mac.c` with fixture bootstraps:
  - an answering agent installs the provider, skips renewal and wires invalidation;
  - a short buffer fails;
  - local modes never ask the agent;
  - a silent agent and `DM_NEXTENDO_AGENT=0` both fall back to the port's own renewal.
- `swift test --filter NextendoAgentHubTests` covers:
  - decoding the friends view;
  - notifications only for changes after an account's first snapshot, and only with the switch and permission;
  - the 429 pause;
  - revocation acting only on a change seen while a game is open;
  - friend request answers;
  - the notification languages;
  - finding Studio from the agent app.
- `make -C dm/host/tests nextendo-api nextendo-social` (and their `-sanitize` variants):
  - the transport mode sends no bearer and makes no HTTP request from the port;
  - a NEX-only record authorizes no API without the transport, and does with it;
  - passive presence starts from the memory provider;
  - invalidation, sign-out and offline mode stop it.
- `dm/tools/tests/test_nsp_mac_app.py` packs the new sources into the bootstrap.

On my Mac with the packaged app, I checked that the switch registers the agent, that the agent runs under launchd, that it is registered again after Studio is replaced, that the Friends panel shows a real friend in a game, and that a friend request is notified and can be accepted from that panel. The agent logs failed provider requests, answers over its limit, HTTP errors and a missing OAuth grant under the subsystem `org.nxnative.portstudio.agent`:

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "org.nxnative.portstudio.agent"'
```

These still need a game, and I have no test dumps right now: a real NEX sign-in with the agent's record, a friend seeing my presence, and an online match.
