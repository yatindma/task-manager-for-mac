# Contributing

Thanks for looking. Issues and PRs are both welcome.

## Reporting a wrong number

This app reads low-level system counters, and they differ between Macs. If a number
looks wrong, include:

- Your Mac's chip (Apple Silicon or Intel) and macOS version
- What **Activity Monitor** says for the same process
- Whether the privileged helper is installed (Settings shows this)

That comparison has already caught real bugs — including one where every process
reported 41× too little CPU on Apple Silicon and looked entirely plausible while
doing it.

## Building

```bash
git clone https://github.com/yatindma/task-manager-for-mac.git
cd task-manager-for-mac
./build.sh
open "Task Manager.app"
```

Xcode must be installed. SwiftUI's `@State` is a macro and its compiler plugin ships
only inside Xcode — a Command Line Tools toolchain fails with *"plugin for module
'SwiftUIMacros' not found"*. `build.sh` points `DEVELOPER_DIR` at Xcode itself, so you
do not need `sudo xcode-select -s`.

## Ground rules

**Never invent a number.** If macOS doesn't publish something, show an em-dash or 0 and
say why — in the code, and in [docs/limitations.md](docs/limitations.md). A plausible
fake number is worse than a visible gap, because nobody can tell it's wrong.

**Never hardcode for one Mac.** No literal core counts, RAM sizes, clock speeds, MB/s
thresholds, or interface names. Everything derives from the hardware at runtime. This
has to be right on a 4-core Intel and a 16-core M-series alike.

**Verify against the machine, not the docs.** Two of the worst bugs here were things
the documentation states incorrectly. If you're touching a sampler, measure it — pin a
core, compare with `ps`, check against Activity Monitor.

**Public APIs only.** No private frameworks. If that means a feature can't exist, it
can't exist.

**Match the file you're in.** `WinTheme` owns every colour, metric, font and formatter —
never hardcode a hex. Comments explain constraints, not mechanics.

## Versioning

[Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

| Bump | When | Example |
|:--|:--|:--|
| **PATCH** — `1.0.1` | A bug fix that changes no behaviour anyone relied on | A CPU figure was wrong; now it's right |
| **MINOR** — `1.1.0` | A new capability, backwards compatible | A new column; a new context-menu action |
| **MAJOR** — `2.0.0` | A break in something users depend on | Settings reset; the helper protocol changes incompatibly |

Two extra rules specific to this project:

- **`tmhelper` has its own version** (`helperVersion` in `Sources/tmhelper/main.swift`).
  Bump it whenever the wire protocol changes. The app checks it on connect and refuses a
  mismatched helper, so a stale setuid binary can never be spoken to with the wrong
  protocol. Bumping it forces users through the install prompt again — do not bump it
  casually.
- **The app version lives in `Resources/Info.plist`** (`CFBundleShortVersionString` and
  `CFBundleVersion`). Both must be updated, and the release tag must match:
  `Info.plist` says `1.2.0` → tag is `v1.2.0`.

### Cutting a release

```bash
# 1. Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist
# 2. Commit that bump on its own
git commit -am "chore: 1.2.0"

# 3. Build and package
./build.sh release
./make-dmg.sh

# 4. Tag and publish — the tag must match Info.plist
git tag v1.2.0 && git push --tags
gh release create v1.2.0 TaskManager.dmg --title "v1.2.0" --notes "..."
```

The README's download button points at `releases/latest/download/TaskManager.dmg`, which
GitHub resolves to whatever the newest release is — so it never needs editing. Keep the
asset named exactly `TaskManager.dmg` or that link breaks.

## Commit messages

```
<type>: <description>
```

`feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.
