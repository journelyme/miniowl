# Contributing to miniowl

Thanks for taking a look. miniowl is a solo-maintained side project, so PRs
move at evenings-and-weekends pace.

## Before you open a PR

- For **bugs**, file an issue first if there isn't one already. Repro steps help.
- For **features**, file an issue describing the founder workflow you're trying to fix.
  miniowl stays small on purpose — see the README for the explicit anti-feature list.
- For **security issues**, do not open a public issue. See
  [SECURITY.md](SECURITY.md).

## Building locally

```bash
git clone git@github.com:journelyme/miniowl.git
cd miniowl
open Package.swift   # opens the SwiftPM project in Xcode
```

Requires macOS 14+ and Xcode with Swift 5.9 toolchain.

## House rules

- **Privacy is non-negotiable.** `scripts/check-privacy.sh` runs in CI and blocks
  any new code that touches keystrokes, clipboard, pasteboard, screen pixels, or
  window contents. If you have a legitimate need, raise it in the PR description
  and we'll discuss.
- **No new dependencies without a discussion.** miniowl currently has zero third-party
  Swift packages outside the standard library. Adding one is a real decision.
- **Keep PRs small.** One concern per PR. Refactors and features in the same PR get
  asked to split.

## License

By submitting a PR you agree to license your contribution under the project's
[MIT License](LICENSE).
