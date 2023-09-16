{ config, lib, pkgs, ... }@inputs:

with builtins;

let
  my_lib = lib // (import ./libs.nix inputs);
  cfg = config.nixjail;
in
with my_lib;
{
  options.nixjail =
    let
      bind_from_to = with types; {
        options = {
          from = mkOption { type = str; };
          to = mkOption { type = str; };
        };
      };

      shared_options = with types; {
        install = mkOption {
          default = true;
          type = bool;
          description = mdDoc "Add package to `environment.systemPackages`";
        };

        homeDirRoot = mkOption {
          default = "$HOME/bwrap";
          type = str;
          description = mdDoc "Root for the `autoBindHome`";
        };

        autoBindHome = mkOption {
          default = true;
          type = bool;
          description = mdDoc "Automatically creates a home directory on `home_dir_root`";
        };

        args = mkOption {
          default = ''"$@"'';
          type = str;
          description = mdDoc "arguments to pass to the packages";
        };

        dri = mkOption {
          default = false;
          type = bool;
          description = mdDoc "If `true` add `--dev-bind-try /dev/dri /dev/dri`";
        };

        dev = mkOption {
          default = false;
          type = bool;
          description = mdDoc "If `true` add `--dev-bind-try /dev /dev`";
        };

        xdg = mkOption {
          default = "ro";
          type = oneOf [ bool (enum [ "ro" ]) ];
          description = mdDoc "If `true` add `--bind-try $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR`";
        };

        net = mkOption {
          default = false;
          type = bool;
          description = mdDoc "If `true` add `--share-net`";
        };

        tmp = mkOption {
          default = false;
          type = bool;
          description = mdDoc "If `true` add `--bind-try /tmp /tmp`";
        };

        rwBinds = mkOption {
          default = [ ];
          type = listOf (oneOf [ str (submodule bind_from_to) ]);
          description = mdDoc "Adds `--bind-try $(readlink -mn $${cfg.from} $${cfg.to})`";
        };

        roBinds = mkOption {
          default = [ ];
          type = listOf (oneOf [ str (submodule bind_from_to) ]);
          description = mdDoc "Adds `--ro-bind-try $(readlink -mn $${cfg.from} $${cfg.to})`";
        };

        defaultBinds = mkOption {
          default = true;
          type = bool;
          description = mdDoc ''
            Adds the following read-only binds:

            "$HOME/.config/mimeapps.list"
            "$HOME/.local/share/applications/mimeapps.list"
            "$HOME/.config/dconf"
            "$HOME/.config/gtk-3.0/settings.ini"
            "$HOME/.config/gtk-4.0/settings.ini"
            "$HOME/.gtkrc-2.0"
          '';
        };

        unshareAll = mkOption {
          default = true;
          type = bool;
          description = mdDoc "If `false` removes `--unshare-all`, not recommended!";
        };

        keepSession = mkOption {
          default = false;
          type = bool;
          description = mdDoc ''
            Fixes "cannot set terminal process group (-1)" by adding `--new-session`
            but is not recommended because of a security issue with TIOCSTI [1]
            [1] - https://wiki.archlinux.org/title/Bubblewrap#New_session
          '';
        };

        extraConfig = mkOption {
          default = [ ];
          type = listOf str;
          description = mdDoc "Extra configs for `bwrap`";
        };
      };
    in
    {
      pkgs = mkOption {
        default = pkgs;
        internal = true;
      };
      fhs = {
        profiles = with types; mkOption {
          default = [ ];
          description = mdDoc "Configure profiles for the `packages` list, using the further options to configure them with bwrap";
          type = listOf (submodule {
            options = {
              name = mkOption {
                default = null;
                type = str;
                description = mdDoc "Name of the FHS";
              };

              runScript = mkOption {
                default = "$TERM";
                type = str;
                description = mdDoc "Script to run when starting FHS";
              };

              profile = mkOption {
                default = "";
                type = str;
                description = mdDoc "Script to run when configuring FHS";
              };

              targetPkgs = mkOption {
                default = pkgs: [ ];
                type = functionTo (listOf package);
                description = mdDoc "Packages that will only be installed once-matching the host's architecture (64bit on x86_64 and 32bit on x86)";
              };

              multiPkgs = mkOption {
                default = pkgs: [ ];
                type = functionTo (listOf package);
                description = mdDoc ''
                  Packages installed once on x86 systems and twice on x86_64 systems.
                  On x86 they are merged with packages from targetPkgs.
                  On x86_64 they are added to targetPkgs and in addition their 32bit versions are also installed. 
                  The final directory structure looks as follows:
                  /lib32 will include 32bit libraries from multiPkgs
                  /lib64 will include 64bit libraries from multiPkgs and targetPkgs /lib will link to /lib32
                '';
              };
            } // shared_options;
          });
        };
      };

      bwrap = {
        profiles = with types; mkOption {
          default = [ ];
          description = mdDoc "Configure profiles for the `packages` list, using the further options to configure them with bwrap";
          type = listOf (submodule {
            options = {
              packages = mkOption {
                default = final: prev: { };
                type = mkOptionType {
                  name = "nixpkgs-overlay";
                  description = "nixpkgs overlay";
                  check = lib.isFunction;
                  merge = lib.mergeOneOption;
                };
                description = mdDoc "Packages to be wrapped with bwrap using the configs on the profile";
              };

              symlinkJoin = mkOption {
                default = true;
                type = bool;
                description = mdDoc "If `false` it will disable the merge of the generated bwrapped package with the original content (like desktop entries, libs and man pages)";
              };

              ldCache = mkOption {
                default = false;
                type = bool;
                description = mdDoc "Add ld.so.conf and ld.so.cache symlinks (both 32 and 64 bit glibcs)";
              };
            } // shared_options;
          });
        };
      };
    };

  config = {
    environment.systemPackages =
      let
        bwrap_packages = pipe cfg.bwrap.profiles [
          # map by profile
          (map ({ install, packages, ... }@profile:
            # list of packages names for the `environment.systemPackages` attr
            (if install then
              pipe (packages cfg.pkgs cfg.pkgs) [
                (mapAttrsToList (_package_name: package: package))
              ]
            else
              [ ]))
          )
          lists.flatten
        ];

        fhs_packages = pipe cfg.fhs.profiles [
          # map by profile
          (map ({ install, name, ... }@profile:
            # list of packages names for the `environment.systemPackages` attr
            (if install then
              [ cfg.pkgs.${name} ]
            else
              [ ]))
          )
          lists.flatten
        ];
      in
      assert isList bwrap_packages;
      assert isList fhs_packages;
      bwrap_packages ++ fhs_packages;

    # FIXME:
    # if nixpkgs /pkgs/top-level/aliases.nix has an alias: X = Y;
    # and the user create an overlay like: { Y = X; }
    # them we will have an infinite recursion on the `checkInPkgs` function
    nixpkgs.overlays =
      let
        bwrap_overlays = pipe cfg.bwrap.profiles [
          # map by profile
          (map ({ packages, ... }@profile:
            # list of functions for the `nixpkgs.overlays` attr
            (final: prev: pipe (packages final prev) [
              (mapAttrsToList (package_name: package: {
                name = package_name;
                value = bwrapIt ((removeAttrs profile [ "install" "packages" ]) // { inherit package; name = package_name; });
              }))
              listToAttrs
            ]))
          )
          lists.flatten
        ];

        fhs_overlays = final: prev: pipe cfg.fhs.profiles [
          # map by profile
          (map ({ name, ... }@profile:
            {
              name = name;
              value = (fhsIt (removeAttrs profile [ "install" ]));
            })
          )
          listToAttrs
        ];
      in
      assert isList bwrap_overlays;
      assert isFunction fhs_overlays;
      # order matters
      [ fhs_overlays ] ++ bwrap_overlays;
  };
}
