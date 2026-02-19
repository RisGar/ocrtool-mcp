{
  description = "macOS native OCR tool implementing Model Context Protocol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    {
      packages = nixpkgs.lib.genAttrs nixpkgs.lib.platforms.darwin (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "ocrtool-mcp";
            version = "1.0.0";

            src = ./.;

            nativeBuildInputs = [
              pkgs.swift
              pkgs.swiftpm
            ];

            buildPhase = ''
              swift build -c release --disable-sandbox
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp .build/release/ocrtool-mcp $out/bin/
            '';

            meta = with pkgs.lib; {
              description = "macOS native OCR tool implementing Model Context Protocol";
              homepage = "https://github.com/ihugang/ocrtool-mcp";
              license = licenses.mit;
              platforms = platforms.darwin;
              mainProgram = "ocrtool-mcp";
            };
          };
        }
      );

      devShells = nixpkgs.lib.genAttrs nixpkgs.lib.platforms.darwin (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.swift
              pkgs.swiftpm
            ];
          };
        }
      );
    };
}
