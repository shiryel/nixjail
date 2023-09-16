{
  description = "A very basic flake";

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosModules.nixjail = {
      imports = [ ./nixjail.nix ];
      #nixpkgs.overlays = [
      #  (f: p: {
      #    #lib = prev.lib // (import ./libs.nix prev);
      #    lib = p.lib.extend (_: _:
      #      (import ./libs.nix p)
      #    );
      #  })
      #];
    };
  };
}
