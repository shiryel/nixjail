{
  description = "A very basic flake";

  outputs = { self, nixpkgs, ... }@inputs:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      nixosModules.nixjail = {
        imports = [ ./nixjail.nix ];
        #nixpkgs.overlays = [
        #  (f: p: {
        #    lib = p.lib.extend (_: _:
        #      (import ./libs.nix p)
        #    );
        #  })
        #];
      };

      # when using "packages" `nix flake show` gives "error: expected a derivation"
      # to build docs use: nix build .\#legacyPackages.x86_64-linux.docs.optionsJSON
      legacyPackages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          eval = lib.evalModules {
            modules = [
              { _module.check = false; }
              ./nixjail.nix
            ];
          };
        in
        with builtins;
        with lib;
        {
          docs = pkgs.buildPackages.nixosOptionsDoc {
            options = eval.options;

            transformOptions =
              let
                prefix_to_strip = (map (p: "${toString p}/") ([ ./. ]));
                strip_prefixes = flip (foldr removePrefix) prefix_to_strip;
                fix_urls = (x: if x == "nixjail.nix" then { url = "https://github.com/shiryel/nixjail/blob/master/${x}"; name = "<shiryel/nixjail>"; } else x);
              in
              opt: opt // {
                declarations = map
                  (d: pipe d [
                    strip_prefixes
                    fix_urls
                  ])
                  opt.declarations;
              };
          };
        }
      );

      #defaultPackage = forAllSystems (system: self.packages.${system}.default);
    };
}
