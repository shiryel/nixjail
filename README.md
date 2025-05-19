# NixJail 
Sandbox your nixpkgs easily with bwrap!

## Features

- Wraps every binary (inside /bin) of a package with Bwrap automatically  
  > So you don't need to worry about those packages with 2 binaries that do the same thing
- Replaces the Desktop item executable with the NixJail version  
  > So you don't need to worry about Desktop items running the wrong package
- Keeps symbolic links to the original package  
  > Because some packages WILL break trying to find these files
- Makes the result overridable, delegating the override to the original package    
  > Because some nixpkgs configs WILL try to override the package
- Add attr `noBwrap` as the original package to the result's `passthru`  
  > So you can use `PACKAGE.passthru.noBwrap` to use the original package on your config when necessary
- Does not modify the original package, only wrappes it  
  > Because nobody wants to wait for the compiler ;)
- Provides `nixjail.fhs`, an enchanced `buildFHSUserEnvBubblewrap` option
  > To allow you to create FHS enviroments with many packages in a easier way

[See all available config options here](https://shiryel.github.io/nixjail)

## Usage

On your flake.nix add nixjail to `inputs` and `outputs`, eg:
```nix
{
  inputs = {
    # ... other inputs, eg: nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixjail = {
      url = "git+file:/home/shiryel/nixos/nixjail";
      inputs.nixpkgs.follows = "nixpkgs"; # change to your main nixpkgs input name
    };
  };

  outputs = { nixpkgs, ... }@inputs:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosConfigurations.default =
        nixpkgs.lib.nixosSystem {
          # avoid using pkgs, args or specialArgs here, they can conflict with nixpkgs.(...) inside modules
          # see: https://github.com/NixOS/nixpkgs/issues/191910
          modules = [
            inputs.nixjail.nixosModules.nixjail
            # ... other modules
          ];
        };
    };
}
```
Notice that you need to set `nixjail.inputs.nixpkgs.follows` to your main nixpkgs input, because NixJail does not have a default nixpkgs input (like HomeManager) but still expects it

After adding NixJail as a module you can use it anywhere on your config, eg:
```nix
  nixjail.bwrap.profiles = [
    {
      # install many derivations on the same profile
      packages = f: p: {
        prismlauncher = prismlauncher;
        thunderbird = thunderbird;
        # you can also override the derivations of the profile:
        discord = p.discord.override { nss = p.nss_latest; };
      };
      dri = true;
      rwBinds = [ "$HOME/Downloads" ]; # Make sure to use `$HOME` instead of `~`
    }
```
Rebuild your system, the packages will be installed automatically, and use `cat $(which discord)` to see the result ;)

---

## Advanced examples

Here some examples making use of some advanced NixJail options, [read the docs](https://shiryel.github.io/nixjail) before using them

```nix
{
  nixjail = {
    bwrap = {
      defaultHomeDirRoot = "$HOME/nixjail";
      profiles = [
        # Firefox
        {
          packages = f: p: with p; { firefox = firefox; };
          dri = true;
          xdg = true;
          autoBindHome = false;
          rwBinds = [
            { from = "$HOME/nixjail/mozilla"; to = "$HOME/.mozilla"; }
            "$HOME/Downloads"
          ];
        }

        # Lutris
        {
          packages = f: p: with p; {
            lutris = lutris.override {
              extraPkgs = pkgs: [ pkgs.openssl ];
              # Fixes: dxvk::DxvkError
              extraLibraries = pkgs:
                let
                  gl = config.hardware.opengl;
                in
                [
                  pkgs.libjson # FIX: samba json errors
                  gl.package
                  gl.package32
                ] ++ gl.extraPackages ++ gl.extraPackages32;
            };
          };
          dri = true; # required for vulkan
          xdg = true;
          rwBinds = [ "$HOME/Downloads" ];
          extraConfig = [
            # Fix games breaking on wayland
            "--unsetenv WAYLAND_DISPLAY"
            "--unsetenv XDG_SESSION_TYPE"
            "--unsetenv CLUTTER_BACKEND"
            "--unsetenv QT_QPA_PLATFORM"
            "--unsetenv SDL_VIDEODRIVER"
            "--unsetenv SDL_AUDIODRIVER"
            "--unsetenv NIXOS_OZONE_WL"
          ];
        }
      ];
    };

    # run with `code-workspace` on your terminal (this example requires zsh and wayland)
    fhs = {
      defaultHomeDirRoot = "$HOME/nixjail-workspaces";
      profiles = [
        {
          name = "code-workspace";
          runScript = "foot";
          dev = true;
          roBinds = [
            "$HOME/.config/foot/foot.ini"
            "$HOME/.zshrc"
            "$HOME/.zshenv"
            "$HOME/.zlogin"
            "$HOME/.zprofile"
          ];
          targetPkgs =
            (pkgs: with pkgs; [
              foot
            ]);
        }
      ];
    };
  };
}
```

## Is it any good?
Yes.
