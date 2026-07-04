{
  description = ''
    Unofficial Nix packaging for claude-science (the "operon" CLI binary
    behind Anthropic's Claude Science AI workbench, beta as of 2026-06-30).

    NOT an official Anthropic product. Not affiliated with, endorsed by, or
    sponsored by Anthropic, PBC. "Claude" is a trademark of Anthropic, PBC.

    This flake does not vendor or redistribute the upstream binary. It only
    fetches it, at build time, from Anthropic's own public distribution
    endpoint (the same one used by install-claude-science.sh), and verifies
    it against the sha256 published in Anthropic's own manifest.json. The
    binary itself remains subject to Anthropic's Consumer/Commercial Terms
    of Service; only the packaging code in this repository (this flake,
    scripts/update.sh, the CI workflow) is licensed by this project -- see
    LICENSE.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ]
      (system:
        let
          # allowUnfree is set on this flake's own nixpkgs instance so the
          # package evaluates for anyone who pulls it, without them needing
          # NIXPKGS_ALLOW_UNFREE / --impure or a global allowUnfree in their
          # own config. Consuming this flake IS the opt-in to the unfree
          # upstream binary; this instance only ever builds claude-science, so
          # there is no collateral effect on the consumer's other packages.
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          lib = pkgs.lib;

          # Updated by scripts/update.sh (see .github/workflows/update.yml),
          # which mirrors the stable -> sha8 -> manifest.json resolution
          # performed by install-claude-science.sh itself.
          release = builtins.fromJSON (builtins.readFile ./release.json);

          # Maps Nix system strings to the platform suffix Anthropic uses
          # in its "operon-<platform>" binary names. linux-arm64 and musl
          # are intentionally omitted: the upstream installer hard-rejects
          # them as of 2026-07 ("linux-arm64 binaries aren't published yet",
          # "musl-based distributions ... aren't supported yet").
          platformMap = {
            x86_64-linux = "linux-x64";
            aarch64-darwin = "darwin-arm64";
            x86_64-darwin = "darwin-x64";
          };

          platform = platformMap.${system}
            or (throw "claude-science: no upstream binary published for ${system}");

          baseUrl =
            "https://storage.googleapis.com/operon-dist-cf94a20e-f71c-413c-bd00-9e12b1fedf59/operon-releases";

          sha256 = release.sha256.${system}
            or (throw "claude-science: release.json has no sha256 for ${system}; run scripts/update.sh");

          src = pkgs.fetchurl {
            url = "${baseUrl}/${release.sha8}/operon-${platform}";
            inherit sha256;
          };

          isLinux = lib.hasSuffix "linux" system;

          # Confirmed 2026-07-04 via `file` / `ldd` on the actual linux-x64
          # binary: dynamically linked, glibc, interpreter
          # /lib64/ld-linux-x86-64.so.2, deps limited to libc/libpthread/
          # libdl/libm. autoPatchelfHook is sufficient; no FHS/Electron/
          # asar patching is needed (unlike Claude Desktop on Linux).
          runtimeDeps = lib.optionals isLinux [ pkgs.bubblewrap pkgs.socat ];

          # NixOS sandbox fix. claude-science runs code-exec kernels inside its
          # own bubblewrap sandbox, and that bwrap invocation binds only FHS
          # dirs (/usr, /bin, /lib, ...) into the namespace -- never /nix/store
          # or /run/current-system. On NixOS every executable and its glibc/
          # dynamic-loader live under /nix/store, so nothing is reachable inside
          # the sandbox and kernels die with:
          #   bwrap: execvp /run/current-system/sw/bin/bash: No such file or directory
          # (confirmed 2026-07-04 even with those paths present on the host).
          #
          # We can't patch the upstream binary, but it locates `bwrap` via the
          # PATH we inject in postFixup -- so we shadow bwrap with this shim,
          # which prepends the missing read-only binds before the app's own
          # args. This keeps the sandbox (and its default-deny network / file
          # approval model) intact, unlike --dangerously-no-sandbox.
          #
          # Prepending is safe here precisely because the app never binds /nix
          # or /run itself (that is the whole bug), so our early binds can't be
          # shadowed by a later parent bind. If CLAUDE_SCIENCE_BWRAP_LOG is set,
          # the raw invocation is appended there first, to diagnose cases where
          # a different bind position or path is needed.
          bwrapShim = pkgs.writeShellScriptBin "bwrap" ''
            if [ -n "''${CLAUDE_SCIENCE_BWRAP_LOG:-}" ]; then
              { printf '%q ' "$@"; echo; } >> "$CLAUDE_SCIENCE_BWRAP_LOG" 2>/dev/null || true
            fi
            exec ${pkgs.bubblewrap}/bin/bwrap \
              --ro-bind /nix/store /nix/store \
              --ro-bind-try /run/current-system /run/current-system \
              --ro-bind-try /run/opengl-driver /run/opengl-driver \
              "$@"
          '';

          # What actually goes on claude-science's PATH: the shim (as `bwrap`)
          # instead of raw bubblewrap, plus socat for the sandbox net bridge.
          wrapperDeps = lib.optionals isLinux [ bwrapShim pkgs.socat ];

        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "claude-science";
            version = release.version;
            inherit src;
            dontUnpack = true;

            # CRITICAL: claude-science is a Bun `--compile` single-file
            # executable -- the application bundle is appended AFTER the ELF and
            # located via a trailer at end-of-file. stdenv's default fixup strips
            # the ELF, which rewrites/truncates it and drops that appended
            # payload; the binary then silently degrades to the bare Bun runtime
            # (`--version` reports Bun's 1.3.13, `--help` prints Bun's CLI). Bun
            # standalone binaries are also already stripped upstream, so there is
            # nothing to gain here. Confirmed 2026-07-04: `strip` alone turns the
            # working v0.1.15 binary into raw Bun. autoPatchelfHook's
            # set-interpreter/set-rpath does NOT harm the payload; only strip does.
            dontStrip = true;

            nativeBuildInputs =
              lib.optionals isLinux [ pkgs.autoPatchelfHook ] ++ [ pkgs.makeWrapper ];
            buildInputs = lib.optionals isLinux [ pkgs.stdenv.cc.cc.lib ];

            installPhase = ''
              runHook preInstall
              install -Dm755 $src $out/bin/.claude-science-unwrapped
              runHook postInstall
            '';

            postFixup =
              if isLinux then ''
                wrapProgram $out/bin/.claude-science-unwrapped \
                  --prefix PATH : ${lib.makeBinPath wrapperDeps}
                mv $out/bin/.claude-science-unwrapped $out/bin/claude-science
              '' else ''
                mv $out/bin/.claude-science-unwrapped $out/bin/claude-science
              '';

            # The sandbox (bubblewrap) is only invoked when claude-science
            # actually runs a job; unlike the installer, the Nix build
            # itself never needs bwrap/socat present at build time.
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck

              # Regression guard for the Bun single-file payload (see dontStrip
              # above). If the appended application bundle is ever lost -- e.g. a
              # future change re-enables strip, or a fixup step rewrites the ELF
              # and truncates the trailer -- the binary silently degrades to the
              # bare Bun runtime: `--version` prints Bun's "<x.y.z>+<hash>" and
              # `--help` prints Bun's CLI. That still exits 0, so a naive smoke
              # test would pass and ship a non-functional `claude-science`. Detect
              # the degraded state explicitly and FAIL the build instead.
              help="$($out/bin/claude-science --help 2>&1 || true)"
              ver="$($out/bin/claude-science --version 2>&1 || true)"
              echo "claude-science --version -> $ver"

              # Signal 1: Bun's help banner is unmistakable; the real CLI's help
              # ("run Claude on your data ...") never contains it.
              # Signal 2: Bun reports a "<x.y.z>+<hash>" version; the real CLI
              # reports the manifest version ("$version", e.g. 0.1.15).
              if printf '%s' "$help" | grep -qiE 'Bun is a fast JavaScript runtime' \
                 || printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]+$'; then
                echo "" >&2
                echo "ERROR: the packaged claude-science ($version, operon-${platform})" >&2
                echo "runs as the bare Bun runtime, not the CLI -- the Bun-compiled" >&2
                echo "payload was lost during the build (almost always a strip step" >&2
                echo "rewriting the ELF; keep dontStrip = true). Refusing to install a" >&2
                echo "non-functional 'claude-science' command." >&2
                exit 1
              fi

              runHook postInstallCheck
            '';

            meta = {
              description =
                "Unofficial packaging of claude-science, the CLI behind Anthropic's Claude Science AI workbench (beta)";
              homepage = "https://claude.com/docs/claude-science";
              license = lib.licenses.unfree; # upstream binary; see flake description re: packaging license
              platforms = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
              maintainers = [ ];
              mainProgram = "claude-science";
            };
          };

          apps.default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/claude-science";
          };

          # `nix develop` gives you bwrap/socat on PATH without installing
          # the package itself -- handy for testing the upstream installer
          # script or debugging sandbox startup failures.
          devShells.default = pkgs.mkShell {
            packages = runtimeDeps;
          };
        });
}
