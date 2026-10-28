# Source export guardrails

These standard-library Python tools prepare a separate, reviewed source checkout. They do not stage, commit, publish, install software or access devices. The destination repository must already exist.

Use `prepare_export.py --help` for options. A plan reads Git-tracked and non-ignored source files, applies the documented asset and credential exclusions, and records a SHA-256 manifest plus redacted scan, link and binary reports in `--report`. Use a report directory outside the source tree. Always review those reports.

Copying requires `--apply --confirm-frozen --expected-digest` with the exact fingerprint from the current plan. Pause source edits first. Any source change invalidates that fingerprint. Existing destination files outside the plan, symlinks, credential findings and broken Markdown links block copying.

The root `public-assets.json` is the explicit allowlist for original public artwork and reviewed Studio interface captures. Inherited images, game and firmware archives, console keys, credentials, signing material, generated products and optional translator debug symbols are excluded. The checked shader translator runtime remains included with third-party notices. This automated policy is an aid to review, not a claim that an arbitrary input repository is safe to publish.

Run the synthetic guard tests with:

```sh
python3 -m unittest discover -s tools/maintainers -p 'test_prepare_export.py'
```

The original import used a separate presentation overlay. Subsequent exports can use this repository root as `--draft`; they must preserve its LICENSE, attribution, notices and asset allowlist. Never export game resources or private account data to a public repository.
