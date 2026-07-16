# Package definition for gc-plan, in callPackage form.
# Imported by flake.nix (`pkgs.callPackage ./default.nix {}`) and usable directly
# by non-flake consumers:
#   nix-build -E '(import <nixpkgs> {}).callPackage ./default.nix {}'
{ lib
, stdenv
, makeWrapper
, shellcheck
, nix
, jq
, coreutils
, gawk
, findutils
, util-linux
}:

stdenv.mkDerivation {
  pname = "gc-plan";
  version = "0.1.0";
  # Narrow src to just the script, so README/docs/flake edits don't rebuild it.
  src = ./gc-plan.sh;
  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ makeWrapper shellcheck ];

  # Lint at build time (doubles as CI), then install a wrapped `gc-plan` with
  # every runtime dependency on PATH.
  buildPhase = ''
    runHook preBuild
    shellcheck "$src"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/gc-plan"
    patchShebangs "$out/bin/gc-plan"
    wrapProgram "$out/bin/gc-plan" \
      --prefix PATH : ${lib.makeBinPath ([
        nix        # nix, nix-store
        jq
        coreutils  # numfmt, stat, date, sort, tr, wc, mktemp
        gawk
        findutils  # xargs
      ] ++ lib.optionals stdenv.hostPlatform.isLinux [
        util-linux # `mount` for atime detection; macOS uses system /sbin/mount
      ])}
    runHook postInstall
  '';

  meta = {
    description = "Size-targeted, oldest-first (LRU-ish) Nix store GC planner";
    homepage = "https://github.com/eisbaw/nix-better-gc";
    license = lib.licenses.mit;
    mainProgram = "gc-plan";
    platforms = lib.platforms.unix;
  };
}
