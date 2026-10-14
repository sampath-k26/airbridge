# Contributing to AirBridge

Thanks for helping! Bug reports, fixes, device test results and docs improvements are all
welcome.

## How changes get in

1. **Fork** the repository and create a branch from `main`.
2. Make your change, with tests where possible.
3. Open a **pull request**. CI runs the Swift tests, the Kotlin tests, the Android build and
   the Swift ⇄ Kotlin interop check. They must pass.
4. The maintainer reviews and merges. Nobody pushes to `main` directly.

## Building and testing

See [`docs/installation.md`](docs/installation.md) and [`docs/testing.md`](docs/testing.md).

```bash
cd macos && swift test
cd android && ./gradlew :core:test :app:assembleDebug
scripts/interop-test.sh
```

## Rules

* **Protocol changes** must update `protocol/SPEC.md` (the source of truth), the shared test
  vectors in `protocol/test-vectors/`, and **both** implementations (Swift and Kotlin) in the
  same pull request.
* **Never commit secrets**: signing keys, keystores, passwords, tokens, personal data or
  network names. Pushes containing known secret formats are blocked automatically.
* **Security issues** go through [SECURITY.md](SECURITY.md), not public issues.
* Keep the existing style of the surrounding code. Keep docs honest: only report test
  results you actually ran.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
