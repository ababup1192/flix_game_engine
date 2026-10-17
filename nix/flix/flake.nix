{
  # Flix コンパイラの jar を、Cj-bc/flix.nix にまだ載っていない版で取るための flake。
  # flix.nix の包み方（nixpkgs の flix パッケージ）をそのまま使い、jar の版とハッシュだけ差し替える。
  # flix.nix に同じ版が載ったら、devbox.json を "github:Cj-bc/flix.nix#flix_X_Y_Z" に戻してここを消す。
  # 版を足すときは nix-prefetch-url https://github.com/flix/flix/releases/download/vX.Y.Z/flix.jar で
  # ハッシュを取り、versions に 1 行足す。
  description = "Flix compiler jars not yet in Cj-bc/flix.nix";

  inputs.flix-nix.url = "github:Cj-bc/flix.nix";

  outputs = { self, flix-nix }:
    let
      versions = {
        "0.78.0" = "0mq96fkh2qm5qadakimmh16yfr4zak8xsmb2x8d7asg23xx2ka7n";
      };
      attrName = version: "flix_${builtins.replaceStrings [ "." ] [ "_" ] version}";
      systems = builtins.attrNames flix-nix.packages;
      forSystem = system:
        let
          base = flix-nix.packages.${system}.default;
          fetchurl = flix-nix.inputs.nixpkgs.legacyPackages.${system}.fetchurl;
        in
        builtins.listToAttrs (map
          (version: {
            name = attrName version;
            value = base.overrideAttrs (_: {
              inherit version;
              src = fetchurl {
                url = "https://github.com/flix/flix/releases/download/v${version}/flix.jar";
                sha256 = versions.${version};
              };
            });
          })
          (builtins.attrNames versions));
    in
    {
      packages = builtins.listToAttrs (map (system: { name = system; value = forSystem system; }) systems);
    };
}
