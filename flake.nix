{
  description = "nix-better-gc — size-targeted, oldest-first Nix store GC planner";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAllSystems (pkgs: rec {
        gc-plan = pkgs.callPackage ./default.nix { };
        default = gc-plan;
      });

      apps = forAllSystems (pkgs: rec {
        gc-plan = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.gc-plan}/bin/gc-plan";
        };
        default = gc-plan;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # Dev tooling plus the script's runtime deps, for hacking without `nix build`.
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
