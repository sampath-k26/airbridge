## What does this change?

## How was it tested?
- [ ] `cd macos && swift test`
- [ ] `cd android && ./gradlew :core:test`
- [ ] `scripts/interop-test.sh` (required if anything in the protocol, crypto or transfer code changed)
- [ ] On real devices (describe):

## Checklist
- [ ] Protocol changes update `protocol/SPEC.md`, the test vectors, **and both** the Swift and Kotlin implementations
- [ ] No secrets, keys, personal data or network names in code, logs or docs
- [ ] Docs updated if behaviour changed
