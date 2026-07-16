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
  src = ./.;

  nativeBuildInputs = [ makeWrapper shellcheck ];
  dontConfigure = true;

  # Lint at build time (doubles as CI), then install a wrapped `gc-plan` with
  # every runtime dependency on PATH. findmnt (util-linux) is included so atime
  # detection prefers it over the /proc/mounts fallback.
  buildPhase = ''
    runHook preBuild
    shellcheck gc-plan.sh
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 gc-plan.sh "$out/bin/gc-plan"
    patchShebangs "$out/bin/gc-plan"
    wrapProgram "$out/bin/gc-plan" \
      --prefix PATH : ${lib.makeBinPath [
        nix        # nix, nix-store
        jq
        coreutils  # numfmt, stat, date, sort, tr, wc, mktemp
        gawk
        findutils  # xargs
        util-linux # findmnt
      ]}
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
