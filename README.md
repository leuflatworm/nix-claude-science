# nix-claude-science

Unofficial Nix flake for `claude-science` — the CLI binary behind
[Claude Science](https://claude.com/docs/claude-science), Anthropic's
scientific AI workbench (released as a beta on 2026-06-30).

> **Not an official Anthropic product.** This project is not affiliated
> with, endorsed by, or sponsored by Anthropic, PBC. "Claude" is a
> registered trademark of Anthropic, PBC. This repository packages an
> unmodified upstream binary for easier installation on Nix/NixOS; it does
> not alter, extract, or reimplement any part of Claude Science's
> authentication, networking, or sandboxing behavior.

## Packaging note: `dontStrip` is required (Bun single-file payload)

`claude-science` is a [Bun](https://bun.sh) `--compile` single-file
executable: the application bundle is appended **after** the ELF and located
via a trailer at end-of-file. stdenv's default `fixup` strips ELF binaries,
which rewrites/truncates the file and drops that appended payload. A stripped
`claude-science` then silently degrades to the **bare Bun runtime** —
`--version` prints Bun's `1.3.13`, `--help` prints Bun's CLI, and every
subcommand is Bun's:

```console
# what a STRIPPED (broken) build does — this flake sets dontStrip to prevent it:
$ claude-science --version
1.3.13                         # Bun's version, not claude-science's
$ claude-science --help
Bun is a fast JavaScript runtime, package manager, bundler, and test runner. ...
```

So `flake.nix` sets **`dontStrip = true;`** (`autoPatchelfHook`'s
set-interpreter/set-rpath is fine — only `strip` corrupts the payload). With
that, the build produces the real CLI:

```console
$ claude-science --version
claude-science 0.1.15-dev.20260701.t220242.shaaa553de (release, public)
$ claude-science --help
claude-science — run Claude on your data, locally, in your browser
```

As a backstop, `installCheckPhase` **fails the build if the packaged binary
ever runs as bare Bun again** (detected via Bun's help banner / its
`<x.y.z>+<hash>` version string), so a future regression that re-strips or
otherwise truncates the payload can't silently ship a non-functional command.

> Historical note: the same "boots into Bun's CLI" symptom has appeared
> upstream in the sibling Claude Code project as a genuine build regression
> ([anthropics/claude-code#28325](https://github.com/anthropics/claude-code/issues/28325),
> [#63402](https://github.com/anthropics/claude-code/issues/63402)). Here,
> though, the cause was local — stripping a good upstream binary — not a bad
> upstream artifact.

## What this is

Anthropic distributes `claude-science` via a shell installer
(`curl -fsSL https://claude.ai/install-claude-science.sh | bash`) that
downloads a single platform binary from a public Google Cloud Storage
bucket and verifies it against a checksum in `manifest.json`. This flake
does the same fetch-and-verify, declaratively, so the binary can be
installed and updated the way you'd expect on Nix/NixOS.

**This repo does not vendor the binary.** `flake.nix` only contains a URL
and a sha256 hash; Nix fetches the real binary from Anthropic's own
distribution endpoint at build time, exactly like the shell installer does.
Only the packaging code here (`flake.nix`, `scripts/update.sh`, the CI
workflow) is covered by this repo's [LICENSE](./LICENSE) — the binary
itself remains subject to Anthropic's own Consumer/Commercial Terms of
Service.

Confirmed by inspecting the actual `linux-x64` binary (2026-07-04,
v0.1.15): it's a normal dynamically-linked glibc ELF executable
(`interpreter /lib64/ld-linux-x86-64.so.2`, depending only on
`libc`/`libpthread`/`libdl`/`libm`) — not an Electron app, and not
distributed via a macOS-DMG-extraction hack the way Claude Desktop on
Linux currently is. `autoPatchelfHook` is sufficient to make it run — but
see the packaging note above: it must be paired with `dontStrip = true` so
the appended Bun application payload survives the build.

## Usage

```bash
# Run without installing
nix run github:leuflatworm/nix-claude-science

# Install into your profile
nix profile install github:leuflatworm/nix-claude-science

# Or add to a flake-based NixOS/Home Manager config
inputs.claude-science.url = "github:leuflatworm/nix-claude-science";
# ... then reference inputs.claude-science.packages.${system}.default
```

A `devShell` is also provided (`nix develop`) that puts `bwrap` and
`socat` on `PATH` without installing the package — useful for testing the
upstream installer script directly or for debugging sandbox startup
issues in isolation.

## Runtime requirements (Linux)

`claude-science` spawns a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox for code execution, and uses `socat` for the sandbox's network
bridging. This flake wraps the binary so both are on `PATH` automatically
— you don't need to install them system-wide.

The sandbox also needs the kernel to permit unprivileged user namespaces.
This is on by default on most NixOS configurations, but if you're running
a hardened profile that disables it, you'll need something like:

```nix
boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
```

(Check your actual kernel/config before assuming this is needed — don't
add it speculatively.)

## Known unknowns / not yet verified

- **Sandbox internals on non-FHS systems.** Bubblewrap itself works fine
  on NixOS (it's just namespaces), but if `claude-science`'s sandbox setup
  hard-codes bind-mounts of typical FHS paths (e.g. `/usr`, `/lib`) for the
  code it executes inside the sandbox, that could behave unexpectedly on
  NixOS. This has not been tested end-to-end yet.
- **How the ~5GB "starter" Python/R environments are built** on first run
  is not documented publicly as of this writing, so whether that step
  itself assumes an FHS layout is also unverified.
- Please open an issue with what you find if you test this — this
  packaging is new and those two points are the main open risk areas.

## Unsupported platforms (upstream, not a limitation of this flake)

As of the current release, Anthropic's own installer explicitly rejects:
- `linux-arm64` ("binaries aren't published yet")
- musl-based Linux distributions, e.g. Alpine ("the linux-x64 binary is
  glibc-linked")

This flake can't work around either of those since no binary exists for
those targets.

## Updating

`scripts/update.sh` reproduces the `stable → sha8 → manifest.json`
resolution from Anthropic's own installer and rewrites `release.json`. A
scheduled GitHub Actions workflow (`.github/workflows/update.yml`) runs it
hourly, and only commits + pushes when the release actually changed (after
confirming the new hashes resolve via `nix build`).

## License

The packaging code in this repository (`flake.nix`, `scripts/`, CI config)
is licensed under the [MIT License](./LICENSE). The `claude-science`
binary itself is Anthropic's proprietary software, distributed under
Anthropic's own terms — this license does not apply to it.
