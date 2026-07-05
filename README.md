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

### NixOS (recommended): the flake's module

Everything claude-science needs on the host is bundled into
`nixosModules.default` — you should not need any other host-side settings
(no `bash`/`coreutils`/`cacert` in `systemPackages`, no `envfs`, no
`/bin/bash` symlink rules, no `SSL_CERT_FILE`, no global `allowUnfree`):

```nix
# flake.nix of your system config
{
  inputs.claude-science.url = "github:leuflatworm/nix-claude-science";

  outputs = { nixpkgs, claude-science, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        claude-science.nixosModules.default   # ← this line
      ];
    };
  };
}
```

The module installs the package and enables
[`nix-ld`](https://github.com/nix-community/nix-ld) (claude-science
downloads `micromamba` — a generic-Linux binary — at runtime, and nix-ld
provides the `/lib64/ld-linux-x86-64.so.2` loader it expects).

Then:

```bash
claude-science serve --no-browser   # headless; open the printed login URL
claude-science url                  # fresh single-use login link (~3 min)
```

### Other ways

```bash
# Run without installing
nix run github:leuflatworm/nix-claude-science

# Install into your profile
nix profile install github:leuflatworm/nix-claude-science
# (non-NixOS-module installs still need programs.nix-ld.enable = true,
#  or an FHS distro, for the runtime-downloaded micromamba)
```

A `devShell` is also provided (`nix develop`) that puts `bwrap` and
`socat` on `PATH` without installing the package — useful for testing the
upstream installer script directly or for debugging sandbox startup
issues in isolation.

## NixOS sandbox support: what this flake actually fixes

**Status: working end-to-end on NixOS with the sandbox ENABLED**
(verified 2026-07-05, v0.1.15: conda env creation, pip/conda package
installs, all bundled stdio MCP connectors, kernels). No
`--dangerously-no-sandbox` needed.

Upstream claude-science runs its code-exec kernels inside a
[bubblewrap](https://github.com/containers/bubblewrap) sandbox whose bind
list assumes an FHS distro: it binds `/usr`, `/bin`, `/lib64`, rebuilds
`/etc` from a `--tmpfs`, and re-binds a hand-picked set of `/etc` entries
(`/etc/ssl`, `/etc/passwd`, ...). On NixOS nearly all of that is empty or
a dangling symlink, so out of the box every kernel dies with errors like:

```
bwrap: execvp /run/current-system/sw/bin/bash: No such file or directory
error    libmamba No CA certificates found on system, aborting
```

This flake fixes that **inside the package** — the binary locates `bwrap`
via the `PATH` its wrapper injects, so we shadow it with a shim that
rewrites the sandbox's bind list. Layer by layer:

| # | Problem on NixOS | Fix (where) |
|---|---|---|
| 1 | `strip` destroys the Bun single-file payload → binary degrades to bare Bun | `dontStrip` + install-check guard (flake) |
| 2 | Sandbox can't reach `/nix/store` / `/run/current-system` → no shell, no libs | bwrap shim adds `--ro-bind`s (flake) |
| 3 | `--tmpfs /etc` orphans NixOS's `/etc/static` symlink farm → CA certs dangle, TLS fails | shim splices `/etc/static` bind **after** the app's own binds, just before bwrap's `--` terminator (flake) |
| 4 | The `--disable-userns` capability probe breaks if binds are spliced into its read-only root | shim detects the probe (no `--tmpfs /etc`) and only prepends there (flake) |
| 5 | `/bin` & `/usr/bin` are near-empty in the sandbox → no `sh`, `mkdir`, `tar`, `git`, ... (kernel setup and `edit_file` fail) | shim binds a curated `buildEnv` (bash, coreutils, grep/sed/awk, tar/gzip/xz/zstd, git, curl, ...) over `/bin` and `/usr/bin` (flake) |
| 6 | Runtime-downloaded `micromamba` is a generic-Linux ELF expecting `/lib64/ld-linux-x86-64.so.2` | `programs.nix-ld.enable` (NixOS module) |
| 7 | `sharp` (image processing) is a prebuilt `.node` module dlopen'd at runtime; its `libstdc++.so.6` can't resolve — autoPatchelf can't reach a runtime-unpacked file, nix-ld doesn't intercept `dlopen`, and `DT_RUNPATH` isn't consulted for dlopen'd objects' deps | append gcc's lib dir and convert the executable's RUNPATH → `RPATH` (`patchelf --force-rpath`), which **is** in every dlopen's search scope — process-local, no `LD_LIBRARY_PATH` leaking into sandbox kernels (flake) |

The shim never weakens the sandbox's security model: network stays
default-deny behind the app's socat proxy with per-host approval cards,
and file access still goes through approvals. The added binds are
world-readable system paths (`/nix/store` is already readable by every
local process).

For debugging, the shim logs every raw bwrap invocation to
`/tmp/claude-science-bwrap.log` (override with `CLAUDE_SCIENCE_BWRAP_LOG`).

The sandbox also needs the kernel to permit unprivileged user namespaces.
This is on by default on most NixOS configurations, but if you're running
a hardened profile that disables it, you'll need something like:

```nix
boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;
```

(Check your actual kernel/config before assuming this is needed — don't
add it speculatively.)

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
