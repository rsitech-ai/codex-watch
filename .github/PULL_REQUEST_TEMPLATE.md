## Summary

- User-visible change:
- Trust boundary affected (Watch queue, pairing, Speech, Inbox, none):

## Honesty

- Hardware status is one of `physical-watch-proven`, `blocked:external`, or `unverified`.
- Codex copy names the local App Server Inbox, not ChatGPT.app.
- This PR does not include audio, transcripts, pairing material, or private paths.

## Test plan

- [ ] `Scripts/run-swift-package-tests.sh`
- [ ] Watch simulator tests when the Watch UI or protocol changed
- [ ] `Scripts/run-watch-bridge-smoke.sh` when bridge delivery changed
