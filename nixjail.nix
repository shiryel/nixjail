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

        post_exec = mkOption {
          default = ''"$@"'';
          type = str;
          description = mdDoc "arguments to pass to the packages";
        };

        pre_exec = mkOption {
          default = "";
          type = str;
          description = mdDoc "commands before the exec";
        };

        runWithSystemd = mkOption {
          default = false;
          type = bool;
          description = mdDoc "use systemd-run";
        };

        #
        # BWRAP
        #

        # Namespaces

        shareNamespace = {
          user = mkOption {
            default = false;
            type = bool;
            description = mdDoc ''Share user namespace (otherwise, "root" files will belong to "nobody")'';
          };

          ipc = mkOption {
            default = false;
            type = bool;
            description = mdDoc "Share ipc namespace (POSIX message queues / SYSV IPC)";
          };

          pid = mkOption {
            default = false;
            type = bool;
            description = mdDoc ''
              Share pid namespace.

              NOTE: Enabling pid namespaces allows sending signals to sub-processes, required by plugins like auto-session and persisted from neovim.
              Some processes may also need the following patch to receive signals: https://github.com/containers/bubblewrap/pull/586
            '';
          };

          net = mkOption {
            default = true;
            type = bool;
            description = mdDoc "Share network namespace";
          };

          uts = mkOption {
            default = false;
            type = bool;
            description = mdDoc "Share uts namespace (keeps hostname)";
          };

          cgroup = mkOption {
            default = false;
            type = bool;
            description = mdDoc "Share cgroup namespace";
          };
        };

        # Env

        clearenv = mkOption {
          default = false;
          type = bool;
          description = mdDoc "Unset all environment variables, except for PWD and any that are subsequently set by --setenv";
        };

        # Binds

        autoBindHome = mkOption {
          default = true;
          type = bool;
          description = mdDoc "Automatically creates a home directory on `home_dir_root`";
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
          default = false;
          type = oneOf [ bool (enum [ "ro" ]) ];
          description = mdDoc "If `true` add `--bind-try $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR`";
        };

        tmp = mkOption {
          default = false;
          type = bool;
          description = mdDoc "If `true` add `--bind-try /tmp /tmp`";
        };

        trim_etc = mkOption {
          default = true;
          type = bool;
          description = mdDoc "Only ro-bind the essential on /etc";
        };

        cacert = mkOption {
          default = null;
          type = nullOr package;
          description = mdDoc "replace cacert package. (requires trim_etc = true)";
        };

        resolv = mkOption {
          default = null;
          type = nullOr str;
          description = mdDoc "replace /etc/resolv.conf. (requires trim_etc = true)";
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

        #
        # DBUS PROXY
        #

        dbusProxy =
          let
            # Descriptions from: https://github.com/flatpak/xdg-dbus-proxy/blob/main/xdg-dbus-proxy.xml

            # The policy for the filtering consists of a mapping from well-known names to a policy that is either SEE, TALK or OWN.
            # The default initial policy is that the the user is only allowed to TALK to the bus itself (org.freedesktop.DBus, or
            # no destination specified), and TALK to its own unique ID. All other clients are invisible.
            shared_dbus_options = {
              sees = mkOption {
                default = [ ];
                type = listOf str;
                description = ''
                  - The name/ID is visible in the ListNames reply
                  - The name/ID is visible in the ListActivatableNames repl
                  - You can call GetNameOwner on the name
                  - You can call NameHasOwner on the name
                  - You see NameOwnerChanged signals on the name
                  - You see NameOwnerChanged signals on the ID when the client disconnects
                  - You can call the GetXXX methods on the name/ID to get e.g. the peer pid
                  - You get AccessDenied rather than NameHasNoOwner when sending messages to the name/ID
                '';
              };

              talks = mkOption {
                default = [ ];
                type = listOf str;
                description = ''
                  - You can send any method calls and signals to the name/ID
                  - You will receive broadcast signals from the name/ID (if you have a match rule for them)
                  - You can call StartServiceByName on the name
                '';
              };

              owns = mkOption {
                default = [ ];
                type = listOf str;
                description = ''
                  - You are allowed to call RequestName/ReleaseName/ListQueuedOwners on the name
                '';
              };

              calls = mkOption {
                default = [ ];
                type = listOf str;
                description = ''
                  In addition to the basic SEE/TALK/OWN policy, it is possible to specify more complicated rules about what method calls can be made on and what broadcast signals can be received from well-known names. A rule can restrict the allowed calls/signals to a specific object path or a subtree of object paths, and it can restrict the allowed interface down to an individual method or signal name.

                  Rules are specified with the --call and --broadcast options. The RULE in these options determines what interfaces, methods and object paths are allowed. It must be of the form [METHOD][@PATH], where METHOD can be either '*' or a D-Bus interface, possible with a '.*' suffix, or a fully-qualified method name, and PATH is a D-Bus object path, possible with a '/*' suffix.
                '';
              };

              broadcasts = mkOption {
                default = [ ];
                type = listOf str;
                description = ''
                  In addition to the basic SEE/TALK/OWN policy, it is possible to specify more complicated rules about what method calls can be made on and what broadcast signals can be received from well-known names. A rule can restrict the allowed calls/signals to a specific object path or a subtree of object paths, and it can restrict the allowed interface down to an individual method or signal name.

                  Rules are specified with the --call and --broadcast options. The RULE in these options determines what interfaces, methods and object paths are allowed. It must be of the form [METHOD][@PATH], where METHOD can be either '*' or a D-Bus interface, possible with a '.*' suffix, or a fully-qualified method name, and PATH is a D-Bus object path, possible with a '/*' suffix.
                '';
              };
            };
          in
          {
            enable = mkOption {
              default = false;
              type = bool;
              description = "Enables xdg-dbus-proxy";
            };

            debug = mkOption {
              default = false;
              type = bool;
              description = "Enables xdg-dbus-proxy logs";
            };

            user = shared_dbus_options;
            system = shared_dbus_options;
          };

        #
        # EXTRA
        #

        keepSession = mkOption {
          default = false;
          type = bool;
          description = mdDoc ''
            Fixes "cannot set terminal process group (-1)" by adding `--new-session`
            but is not recommended because of a security issue with TIOCSTI [1]
            [1] - https://wiki.archlinux.org/title/Bubblewrap#New_session
          '';
        };

        ldCache = mkOption {
          default = false;
          type = bool;
          description = mdDoc "Add ld.so.conf and ld.so.cache symlinks (both 32 and 64 bit glibcs)";
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
        defaultHomeDirRoot = with types; mkOption {
          default = "$HOME/nixjail";
          type = str;
          description = mdDoc "Default root dir, used by `homeDirRoot`";
        };
        profiles = with types; mkOption {
          default = [ ];
          description = mdDoc "Configure profiles for the `packages` list, using the further options to configure them with bwrap";
          type = listOf (submodule {
            options = {
              homeDirRoot = mkOption {
                default = cfg.fhs.defaultHomeDirRoot;
                type = str;
                description = mdDoc "Root dir for the `autoBindHome`";
              };

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
        defaultHomeDirRoot = with types; mkOption {
          default = "$HOME/nixjail";
          type = str;
          description = mdDoc "Default root dir, used by `homeDirRoot`";
        };
        profiles = with types; mkOption {
          default = [ ];
          description = mdDoc "Configure profiles for the `packages` list, using the further options to configure them with bwrap";
          type = listOf (submodule {
            options = {
              homeDirRoot = mkOption {
                default = cfg.bwrap.defaultHomeDirRoot;
                type = str;
                description = mdDoc "Root dir for the `autoBindHome`";
              };

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
                description = mdDoc "If `false` it disables the merge of the generated bwrapped package with the original content (like desktop entries, libs and man pages)";
              };

              removeDesktopItems = mkOption {
                default = false;
                type = bool;
                description = mdDoc "Removes all desktop items from derivation, requires `symlinkJoin = false` to work";
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
                # we need to use cfg.pkgs."${package_name}" because _package would be the
                # version BEFORE the overlay IF the package_name is not the same attr as _package
                (mapAttrsToList (package_name: _package: cfg.pkgs."${package_name}"))
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
      lib.mkOrder 1600 ([ fhs_overlays ] ++ bwrap_overlays);
  };
}
