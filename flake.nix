# NixJail --- Bwrap wrapper for nixpkgs
# Copyright (C) 2023 Shiryel <contact@shiryel.com>
#
# This library is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this library. If not, see <https://www.gnu.org/licenses/>.

{
  description = "Bwrap wrapper for nixpkgs";

  outputs = { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      nixosModules.nixjail = {
        imports = [ ./nixjail.nix ];
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
    };
}
