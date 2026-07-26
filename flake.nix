{
  description = "PeerMesh — dev shell (auxiliary tooling; Swift toolchain comes from Xcode)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            # Signaling codegen — version pinned via flake.lock (DD-5 rule 4).
            # Regenerate with:
            #   flatc --swift -o Sources/PeerMesh/Signaling/Generated Schemas/signal.fbs
            pkgs.flatbuffers
          ];
        };
      });
    };
}
