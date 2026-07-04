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
          pkgs = import nixpkgs { inherit system; };
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

        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "claude-science";
            version = release.version;
            inherit src;
            dontUnpack = true;

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
                  --prefix PATH : ${lib.makeBinPath runtimeDeps}
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

              # claude-science is a Bun-compiled single-file executable. Upstream
              # has, more than once, shipped the RAW Bun runtime instead of the
              # app-embedded binary: with the launcher not embedded, Bun falls
              # through to its own CLI, so the "binary" is just `bun`. This is a
              # known area:packaging regression in the sibling claude-code project
              # (anthropics/claude-code#28325 on linux, #63402 on windows), and it
              # is exactly the state of operon-linux-x64 v0.1.15 as of 2026-07-04.
              #
              # A raw-Bun build still exits 0 on `--version`, so a naive smoke test
              # passes and silently installs a non-functional CLI. Detect it
              # explicitly and FAIL the build instead -- this also makes the CI
              # update workflow refuse to bump release.json to a mis-built upstream
              # release, and only go green once a real app binary is published.
              help="$($out/bin/claude-science --help 2>&1 || true)"
              ver="$($out/bin/claude-science --version 2>&1 || true)"
              echo "claude-science --version -> $ver"

              # Signal 1: Bun's help banner is unmistakable and app-specific text
              # will never contain it.
              # Signal 2: Bun reports a "<x.y.z>+<hash>" version; the real CLI
              # reports the manifest version ("$version", e.g. 0.1.15) with no +hash.
              if printf '%s' "$help" | grep -qiE 'Bun is a fast JavaScript runtime' \
                 || printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]+$'; then
                echo "" >&2
                echo "ERROR: upstream release $version (operon-${platform}) is a raw Bun" >&2
                echo "runtime, NOT the claude-science CLI -- running it drops into Bun's" >&2
                echo "own command line. This is the known area:packaging regression from" >&2
                echo "anthropics/claude-code#28325 / #63402 (the launcher was not embedded" >&2
                echo "into the Bun single-file executable). Refusing to package a build" >&2
                echo "that would install a non-functional 'claude-science' command." >&2
                echo "" >&2
                echo "This is an upstream defect, not a packaging bug here: wait for a" >&2
                echo "corrected release (scripts/update.sh will pick it up) or pin an older" >&2
                echo "known-good sha8 in release.json." >&2
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
