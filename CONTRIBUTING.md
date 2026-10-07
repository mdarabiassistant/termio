# Contributing to Termio

Termio is a terminal-first environment for AI coding agents. The Mac app is
Swift + AppKit/SwiftUI on top of **libghostty** (Ghostty's terminal core); the
sessions themselves live in **`termiod`**, the Rust session host under
`termiod/`. It is a deliberately small, focused tool — prefer clarity over cleverness, keep the
surface area minimal, and don't add features nobody asked for. When in doubt,
open an issue and discuss before writing code.

## Prerequisites

- macOS 14+.
- Swift 6 (Xcode 26).
- Rust (`cargo`) and **Zig 0.16.0 on `PATH` under that exact name**, to build
  `termiod`. The daemon embeds libghostty-vt, which `build.rs` builds with Zig;
  `termiod/DEPLOY.md` has the exact environment. Without them there is no
  session backend, so the app starts but can open no session.
- You do **not** need `zig` for the Swift side: libghostty ships as a prebuilt
  `GhosttyKit.xcframework` via the
  [termio-sh/libghostty-swift](https://github.com/termio-sh/libghostty-swift)
  package. Do not try to build Ghostty from source in this repo.

## Building and running

### Quick loop (bare binary)

```sh
(cd termiod && cargo build)   # the session host — sessions need it
swift build                   # resolves dependencies + compiles
swift run                     # launches the app
```

A bare `swift run` binary has no bundle, so it looks for the daemon at
`termiod/target/{release,debug}/termiod` in the checkout it lives in. Build
`termiod` once and every later `swift run` finds it; `TERMIO_TERMIOD_BIN`
overrides the path.

Run from a macOS GUI session — Termio is a real foreground AppKit app
(bootstrapped by an explicit `NSApplication` in `Sources/termio/App/App.swift`,
not the SwiftUI `App` lifecycle).

### App bundle (Dock icon, Sparkle embedded)

`swift run` produces a bare binary with a generic Dock icon. For a proper
`.app`:

```sh
./scripts/build-app.sh        # ad-hoc-signed release build → ./termio.app
open ./termio.app
```

The script builds `termiod` and bundles it into `Contents/Resources`. Without
`cargo` and `zig` a release build fails outright; a dev build warns and ships
without a daemon, which means it can open no session.

### Dev channel (run beside an installed release)

If you have a released Termio installed, build the side-by-side dev app so you
don't clobber it:

```sh
TERMIO_CHANNEL=dev ./scripts/build-app.sh    # → ./termio-dev.app
open ./termio-dev.app
```

The dev channel gets its own bundle id (`sh.termio.app.dev`), its own state dir
(`~/.termio-dev`), its own companion port (8788), a `termio-dev` CLI, and no
Sparkle update feed, so it can never auto-update itself onto the release channel.

### iOS companion

The iOS app lives in `ios/` (`TermioMobile.xcodeproj`, scheme `TermioMobile`).
`ios/dev-run.sh` builds and installs it pointed at this Mac's companion server.
Shared wire-protocol code lives in `Shared/` and is used by both platforms.

Simulator builds need no signing. For a device build, put your Apple
Development team in a `SharedXcodeSettings/DeveloperSettings.xcconfig` next to
your clone — `ios/Signing.xcconfig` gives the exact path and format. Keeping it
outside the repo means nothing local ever lands in git, and one copy covers
every clone and worktree.

### Web companion

The browser companion is a standalone HTML file. Open `web/companion/dist/index.html`
directly in a browser, choose **Add Machine**, and paste the connection address
from the Mac's **Settings → Mobile**. It needs no web server, hosting, or Node.js
to run. Termio must be running on the Mac with Mobile Access enabled; the page
connects directly to its existing WebSocket service.

Turn off **Direct Attach** to get a `ws://` or `wss://` address. The left pane
groups sessions by machine; select a session to use its terminal on the right.
**Detach** leaves the session running. Connections stay in memory unless
**Remember on this browser** is checked; remembered addresses include the pairing
token. Browser storage for local files may change if the HTML file is moved.

To rebuild the file from source, use Node.js 22, as specified in
`web/companion/.node-version`:

```sh
cd web/companion
npm ci
npm run build                  # one self-contained file: dist/index.html
```

The build embeds xterm.js, application code, and styles. Copy `index.html`
anywhere and open it; there are no companion assets or CDN dependencies.
For development and verification:

```sh
npm run dev                    # optional development server with live reload
npx playwright install chromium
npm test                       # opens the built HTML via file://
```

The browser tests use a WebSocket fixture for the Mac and no HTTP server.
The browser must be able to reach the Mac or its tunnel. This client uses
companion wire v2; it does not speak the separate Direct Attach protocol.
For public static hosting, upload only `dist/index.html` at the site root. The
published artifact contains no saved connections, screenshots, test fixtures,
local environment files, or source maps. Keep the checkout,
`node_modules`, and test results out of the hosting directory.

An HTTPS page requires a reachable `wss://` Mobile address. Each visitor supplies
their own address and pairing token. Saved connections belong to that browser
profile and site origin; the app does not upload them to the website host. The
host serves the static page and can log ordinary page requests. The app contains
no analytics or third-party runtime scripts.

For automatic deployment with Cloudflare Pages, connect this GitHub repository
and use these build settings:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Root directory | `web/companion` |
| Build command | `npm ci && npm run build` |
| Build output directory | `dist` |

Pages reads the Node.js version from `.node-version`. Enable automatic
production deployments and add your custom domain in the Pages dashboard.
For build watch paths, include `web/companion/*` and
`web/landing/public/logo.png`; the logo is embedded from outside the companion
folder. A merge into `main` then triggers a new build and deployment. Build
output stays out of Git, and no GitHub Release or deployment token is needed
for this Git integration.

The `Web companion validation` check builds and tests the companion on every PR.
Require this check in the `main` branch rules before enabling automatic
production deployments; Cloudflare starts builds from pushes independently of
GitHub Actions. The workflow runs on every PR so unrelated changes also report
a result instead of leaving a required check pending.

A Pages project created with Direct Upload cannot switch to Git integration.
Create a Git-connected Pages project to use this deployment flow. See the
[Cloudflare Git integration guide](https://developers.cloudflare.com/pages/configuration/git-integration/)
and [build settings](https://developers.cloudflare.com/pages/configuration/build-configuration/).

## Code conventions

From `AGENTS.md` (the authoritative copy, also what AI coding agents read):

- Prioritize correctness and clarity over micro-optimization.
- No force-unwraps (`!`) or anything that traps — use `guard let` / `if let`
  and surface failures instead of crashing.
- Never silently discard errors: handle, log, or propagate.
- Comments explain *why*, not *what*. No summary/organizational comments.
- Full words for names, no abbreviations.
- Prefer adding to existing files over creating many small ones; a new file is
  for a genuinely new component.

### libghostty specifics

- Termio uses the host-managed `.inMemory` backend: the surface renders bytes
  the app attaches to over the session protocol
  (`Sources/termio/Terminal/Termiod/TermiodClient.swift`). The PTY itself lives
  in the daemon (`termiod/src/pty.rs`), spawned with the `openpty` +
  `login_tty` shape. Do **not** switch the spawn to `posix_spawn` — that PTY
  shape breaks agents' resize repaint (see
  `docs/bug/terminal-resize-no-reflow-HANDOFF.md`).
- One `TerminalViewState` owns one surface; `TermioStore`'s SurfaceCache keeps
  it alive across view rebuilds so shells survive session switching.

### Dependencies and vendored code

Be conservative about new SPM dependencies. In particular, **never add a
library dependency that ships resources**: plain `swift build` generates a
broken `Bundle.module` accessor (it only checks the `.app` root and a
hardcoded build-machine path), so CI-built releases crash at runtime even when
local dev builds work. This shipped as a crash twice (v0.1.0, v0.2.4). Vendor
such code instead, the way `Sources/termio/Editor/Highlightr/` does: include
the upstream license in a vendor `README.md`, route resource lookups through
`Bundle.termioResources`, and list local deviations from upstream in the file
header.

Changes to libghostty itself go to the
[termio-sh/libghostty-swift](https://github.com/termio-sh/libghostty-swift)
fork (as rebased patch files there), not this repo; Termio then bumps the
package version in `Package.swift`.

## Patch conventions

### Branching — trunk-based

`main` is the single trunk and the default branch. There is no `dev` or
`release` branch.

- Branch off the latest `main` for every change, using a `feat/…`, `fix/…`, or
  `chore/…` name:
  `git switch main && git pull --ff-only && git switch -c feat/<slug>`.
- Keep branches **short-lived** — open a PR early and merge or close it quickly.
  Long-lived divergent branches are exactly what this workflow exists to avoid.
- Open the PR against `main`: `gh pr create --base main`.
- For a substantial feature, a git worktree keeps it isolated:
  `git worktree add ../termio-worktrees/<slug> -b feat/<slug> main`.

### Commits

- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/):
  `type(scope): imperative, lowercase summary` — e.g.
  `fix(pty): kill the session's whole process group and reap strays`.
  Common scopes in history: `pty`, `sidebar`, `panes`, `welcome`, `landing`,
  `runbook`, `ios`.
- No `Co-Authored-By` trailers.
- Keep each commit a single logical change; the body (when needed) explains
  why, not what.
- Don't rewrite pushed history on `main` — the release build number is
  `git rev-list --count HEAD`, and Sparkle treats a lower build number as
  older, which breaks auto-update.

### Pull requests

- Titles: imperative, correctly capitalized, **no** conventional-commit
  prefixes, no trailing punctuation.
- Include a `Release Notes:` section in the PR body.

### Docs

Anything under `docs/` carries YAML front matter (`title`, `status`, `type`,
`created`/`updated`); the front matter is the single source of truth for a
doc's status, and the index table in `docs/README.md` is generated from it —
don't edit that table by hand.

## Release flow

Releases are cut by pushing a version tag; nothing in the repo needs editing:

```sh
git tag v0.3.0
git push origin v0.3.0
```

That fires `.github/workflows/release.yml`, which builds the app,
Developer-ID-signs and notarizes it, packages a DMG, signs and merges the
Sparkle appcast, uploads everything to Cloudflare R2
(`downloads.termio.sh`), and records a GitHub Release.

- **The tag is the version**: `v0.3.0` → `CFBundleShortVersionString = 0.3.0`.
- **The build number is the commit count** on `HEAD`, stamped into
  `CFBundleVersion`; it must only ever increase (see the history-rewrite
  warning above).
- Existing installs pick the release up on their next Sparkle check via
  `https://downloads.termio.sh/appcast.xml`.

Details, one-time secret setup, and the manual verification checklist live in
`docs/RELEASING.md` and `docs/runbook/macos-release-runbook.md`. To reproduce
a release-style signed bundle locally:

```sh
SIGN_IDENTITY="Developer ID Application" \
TERMIO_VERSION=0.3.0 TERMIO_BUILD=$(git rev-list --count HEAD) \
  ./scripts/build-app.sh
```

iOS releases run through `.github/workflows/ios.yml` and TestFlight and are
cut separately from the macOS tag flow.
