{
  description = "Stormo — dev shell (auxiliary tooling; Swift toolchain comes from Xcode)";

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
            # Signaling codegen (DD-5 rule 4). This flatc's version MUST equal the
            # `google/flatbuffers` runtime pinned `exact:` in Package.swift — the
            # generated code and the runtime that reads it are one unit; bump both
            # together. Regenerate the committed sources with:
            #   flatc --swift -o Sources/StormoProtocol/Generated Schemas/*.fbs
            pkgs.flatbuffers
          ];
        };
      });
    };
}
