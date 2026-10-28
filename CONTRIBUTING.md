# Contributing

Contributions should make a real workflow or game configuration more reliable and leave enough evidence for another person to reproduce the result.

## Start with a small, observable problem

Before changing the host or a game profile, reproduce the issue and identify the incorrect behavior: a failing input, service result, instruction, resource layout, thread state or graphics operation. Prefer a general mechanism when the evidence supports one. Keep game/build-specific knowledge in the corresponding profile and gate fixed addresses by the correct build ID.

Discuss a large feature or a new platform before implementing it. Android and Windows are research targets after Apple stability; they are not drop-in rebuilds of the Apple host.

## Useful bug reports

Include:

1. Studio/engine revision and whether you used a packaged app or a source checkout.
2. Game title ID, display version, update/DLC information and build ID when available.
3. Mac/device model, OS version and selected destination. Include firmware-resource catalog version if relevant.
4. Steps, expected result and actual result, with a minimal redacted log or crash excerpt.
5. For multiplayer: **LAN, LDN or Nextendo**, both peers' game versions, the topology and the last observed state. State whether a room was found, a connection was made or a complete match was played.
6. Whether the same result occurs with a clean test save/cache. Back up personal saves before isolating a test.

Do not upload game packages, extracted assets, console keys, firmware archives, account tokens, OAuth callback URLs, provisioning credentials or personal saves. Redact credentials and personal information before sharing logs or screenshots. File paths and player names can also identify a person; inspect what you attach.

## Development checks

Studio uses Swift 6 and macOS 14+. From the Studio directory:

```sh
swift test
swift build
```

Run the focused host/tool tests appropriate to your change as well. A protocol change needs malformed-input and lifecycle coverage; a concurrency change needs meaningful pause/cancel/reuse scenarios. A passing mock or loopback fixture does not establish physical console or iPhone interoperability.

For a game compatibility change, record the exact game/update/profile, target platform, test scope and known limitations. Screenshots must come from the tested build; label mockups as mockups and do not substitute them for validation evidence.

## Pull requests

- Explain the concrete problem and resulting behavior.
- Keep changes focused and avoid unrelated generated files.
- State how the change was checked and what remains untested.
- Include the documentation/profile updates needed to reproduce the result.
- Preserve upstream authorship, copyright notices and third-party licenses. Attribute adapted code and comply with its license; a reference protocol does not grant permission to copy an implementation under a different license.

Changes to authentication must keep tokens out of logs, observed UI state, game bundles and source. Preserve certificate and signed-catalog verification. Do not mark a title online-ready merely because authentication or catalog eligibility succeeded.

## Documentation and conduct

Use English for code, comments and technical documentation. Add user-facing translations through the existing localization files. Prefer clear, testable descriptions over compatibility claims without evidence.

Be respectful of contributors, upstream projects, services and players. Report security-sensitive account or credential issues privately through the repository maintainer's available security contact rather than placing secrets in a public issue.
