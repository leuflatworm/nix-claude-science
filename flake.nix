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
              $out/bin/claude-science --version
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
