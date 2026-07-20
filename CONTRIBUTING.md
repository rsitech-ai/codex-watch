# Contributing

Thank you for helping improve Voice Inbox. The project is publicly maintained
by [RSI Tech](https://rsitech.ai).

## Before opening a change

- Use a focused branch and keep unrelated changes out of the pull request.
- Add or update tests for behavior changes and bug fixes.
- Do not include voice recordings, transcripts, pairing material, Codex task
  identifiers, local paths, credentials, or private compatibility evidence.
- Report security issues through the private process in [SECURITY.md](SECURITY.md).

## Local verification

```bash
swift test --no-parallel
Tests/ReleasePackagingTests/package_bridge_release_contract_test.sh
xcodebuild \
  -project CodexWatch.xcodeproj \
  -scheme CodexWatch \
  -sdk watchsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
Scripts/run-watch-bridge-smoke.sh
```

Run `git diff --check` before submitting. Pull requests should explain the user
impact, the affected trust boundary, and the exact verification performed.

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE).

Questions about public or confidential project matters can be sent to
[info@rsitech.ai](mailto:info@rsitech.ai).
