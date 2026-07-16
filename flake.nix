{
  description = "nix-better-gc — size-targeted, oldest-first Nix store GC planner";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # Runtime deps of gc-plan.sh plus the dev tooling (shellcheck, just).
          packages = with pkgs; [
            bash
            just
            shellcheck
            jq
            coreutils   # numfmt, stat, date
            util-linux  # findmnt
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
