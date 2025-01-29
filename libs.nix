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

# TODO: some times when using nixjail with an overlay the nixos
# will use the overlay instead of the nixjail result, an workaround
# is the usage of { new_name = package; } instead of { package = package; }

{ config, lib, pkgs, ... }:

with builtins;
with lib;

let
  pkgsi686Linux = pkgs.pkgsi686Linux;
in
rec {

  ##################
  # HIGH LEVEL API #
  ##################

  # NOTE: Remember to follow the binding order from $HOME/
  # eg: $HOME/ $HOME/.config $HOME/.config/*
  bwrapIt = args:
    makeOverridable
      (override_attrs:
        let
          _args = (bwrapItArgs args);
          _bwrapped_derivation = (bwrapDerivataion _args override_attrs);
        in
        if _args.symlinkJoin
        # make man pages, desktop entries and libs available
        then
          pkgs.symlinkJoin
            {
              name = "${_args.package.name}-bwraplink";
              paths = [ _bwrapped_derivation (maybeOverride _args.package override_attrs) ];
              passthru = _bwrapped_derivation.passthru;
            }
        else _bwrapped_derivation
      )
      { };

  fhsIt = args:
    let
      _args = fhsItArgs args;
    in
    fhsUserEnv _args;

  #################################
  # CONFIG FOR BOTH BWRAP AND FHS #
  #################################

  genericArgs = (
    { name ? null
    , pre_exec ? ""
    , post_exec ? ''"$@"''
      # BWRAP
    , rwBinds ? [ ] # [string] | [{from: string; to: string;}]
    , roBinds ? [ ] # [string] | [{from: string; to: string;}]
    , autoBindHome ? true
    , homeDirRoot ? "$HOME/nixjail"
    , defaultBinds ? true
    , trim_etc ? true
    , cacert ? null
    , resolv ? null
    , dri ? false # video acceleration
    , dev ? false # Vulkan support / devices usage
    , xdg ? false # true | false | "ro"
    , net ? false
    , tmp ? false # some tray icons needs it
    , ipc ? false
    , unshareAll ? true
      # DBUS PROXY
    , dbusProxy ? { }
      # EXTRA
      # Fixes "cannot set terminal process group (-1)" but is 
      # not recommended because of a security issue with TIOCSTI [1]
      # [1] - https://wiki.archlinux.org/title/Bubblewrap#New_session
    , keepSession ? false
    , ldCache ? false
    , extraConfig ? [ ]
    }:
      assert isString name;
      assert isString pre_exec;
      assert isString post_exec;
      # BWRAP
      assert isList rwBinds;
      assert isList roBinds;
      assert isBool autoBindHome;
      assert isString homeDirRoot;
      assert isBool defaultBinds;
      assert cacert == null || (isDerivation cacert && trim_etc == true);
      assert resolv == null || (isString resolv && trim_etc == true);
      assert isBool dri;
      assert isBool dev;
      assert asserts.assertOneOf "bwrap.xdg" xdg [ "ro" true false ];
      assert isBool net;
      assert isBool tmp;
      assert isBool ipc;
      assert isBool unshareAll;
      # DBUS PROXY
      assert isAttrs dbusProxy;
      # EXTRA
      assert isBool keepSession;
      assert isBool ldCache;
      assert isList extraConfig;
      let
        # eg: hello_world-test -> HelloWorldTest
        _normalized_name = pipe name [
          (split "[^[:alpha:]|[:digit:]]") # split when not (a-Z or 0-9)
          (filter isString)
          (map (x: (lib.toUpper (substring 0 1 x)) + (substring 1 (-1) x)))
          (lib.concatStrings)
        ];

        #########
        # BWRAP #
        #########

        _auto_bind_home =
          if autoBindHome then [{
            from = "${homeDirRoot}/${name}";
            to = "$HOME";
          }]
          else
            [ ];

        # Normalizes to [{from: string; to: string;}]
        _normalize_binds = map
          (x:
            if x ? from && x ? to
            then x
            else { from = x; to = x; });

        # Bwrap can't bind symlinks correctly, it needs canonicalized paths [1]
        # `readlink -m` solves this issue
        # [1] - https://github.com/containers/bubblewrap/issues/195
        _rwBinds = pipe (_auto_bind_home ++ rwBinds) [
          _normalize_binds
          # Sometimes a program will call itself, and their home will be "new" without the
          # files that it was working with (or without the file of others programs that uses
          # the same bwrap environment, like steam, steam-run and protontricks). To fix this
          # problem we bind the bwrap environment inside itself, so it will be available in case
          # the program call itself (and create a new bwrap)
          (b: b ++ (map (x: if isList (match "${lib.strings.escapeRegex homeDirRoot}.*" x.from) then [{ from = x.from; to = x.from; }] else [ ]) b))
          lists.flatten
          (map (x: ''--bind-try "$(${pkgs.coreutils}/bin/readlink -mn "${x.from}")" "${x.to}"''))
          (concatStringsSep "\n    ")
        ];

        _extra_roBinds =
          if defaultBinds then [
            "$HOME/.config/mimeapps.list"
            "$HOME/.local/share/applications/mimeapps.list"
            "$HOME/.config/dconf"
            "$HOME/.config/gtk-2.0/gtkrc"
            "$HOME/.config/gtk-2.0/gtkfilechooser.ini"
            "$HOME/.config/gtk-3.0/settings.ini"
            "$HOME/.config/gtk-3.0/bookmarks"
            "$HOME/.config/gtk-4.0/settings.ini"
            "$HOME/.config/gtk-4.0/bookmarks"
            "$HOME/.config/Kvantum/kvantum.kvconfig"
            "$HOME/.config/Kvantum/Dracula-Solid"
            "/etc/nvim/snippets/"
          ] else [ ];

        _roBinds = pipe (roBinds ++ _extra_roBinds) [
          _normalize_binds
          (map (x: ''--ro-bind-try "$(${pkgs.coreutils}/bin/readlink -mn "${x.from}")" "${x.to}"''))
          (concatStringsSep "\n    ")
        ];

        # mkdir -p (only if `homeDirRoot` is on the name)
        _mkdir = pipe (_auto_bind_home ++ rwBinds) [
          _normalize_binds
          (map (x: if isList (match "${lib.strings.escapeRegex homeDirRoot}.*" x.from) then ''mkdir -p "${x.from}"'' else ""))
          (concatStringsSep "\n")
        ];

        _dev_or_dri =
          if dri || dev then
            (if dev then
              "--dev-bind-try /dev /dev"
            else
              "--dev /dev --dev-bind-try /dev/dri /dev/dri")
          else "--dev /dev";

        # read-only by default (--ro-bind /run /run)
        _xdg =
          if xdg == "ro" then "--ro-bind-try $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR" else
          if xdg then "--bind-try $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR" else ''
            # audio / video
            --ro-bind-try $XDG_RUNTIME_DIR/pulse $XDG_RUNTIME_DIR/pulse 
            $(for file in `ls "$XDG_RUNTIME_DIR/"{pipewire,wayland}-*`; do echo "--ro-bind $file $file"; done)
          '';

        _net = if net then "--share-net" else "";
        _tmp = if tmp then "--bind-try /tmp /tmp" else "--tmpfs /tmp";
        _ipc = if ipc then "" else "--unshare-ipc";
        _unshare = if unshareAll then "--unshare-all" else "";

        #
        # ETC
        #

        _trim_etc_entries =
          let
            files = [
              # NixOS Compatibility
              "nix" # mainly for nixUnstable users, but also for access to nix/netrc
              # Shells
              "shells"
              "bashrc"
              "zshenv"
              "zshrc"
              "zinputrc"
              "zprofile"
              # Users, Groups, NSS
              "passwd"
              "group"
              "shadow"
              "hosts"
              #"resolv.conf"
              "nsswitch.conf"
              # User profiles
              "profiles"
              # Sudo & Su
              "login.defs"
              "sudoers"
              "sudoers.d"
              # Time
              "localtime"
              "zoneinfo"
              # Other Core Stuff
              "machine-id"
              "os-release"
              # PAM
              "pam.d"
              # Fonts
              "fonts"
              # ALSA
              "alsa"
              "asound.conf"
            ];
          in
          pipe files [
            (map (path: ''--ro-bind-try "/etc/${path}" "/etc/${path}"''))
            (concatStringsSep "\n  ")
          ];

        # https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/security/ca.nix
        _cacert_path = "${cacert}/etc/ssl/certs/ca-bundle.crt";

        _resolv =
          if resolv != null then
            "--ro-bind ${pkgs.writeText "resolv.conf" resolv} /etc/resolv.conf"
          else
            "--ro-bind /etc/resolv.conf /etc/resolv.conf";

        _etc =
          if trim_etc then
            if cacert != null then ''
              --tmpfs /etc/ssl/certs
              --tmpfs /etc/pki/tls/certs
              --ro-bind ${_cacert_path} /etc/ssl/certs/ca-certificates.crt
              --ro-bind ${_cacert_path} /etc/ssl/certs/ca-bundle.crt
              --ro-bind ${_cacert_path} /etc/pki/tls/certs/ca-bundle.crt
              --ro-bind /etc/static /etc/static
              --tmpfs /etc/static/ssl/certs
              --tmpfs /etc/static/pki/tls/certs
              --ro-bind ${_cacert_path} /etc/static/ssl/certs/ca-certificates.crt
              --ro-bind ${_cacert_path} /etc/static/ssl/certs/ca-bundle.crt
              --ro-bind ${_cacert_path} /etc/static/pki/tls/certs/ca-bundle.crt
              ${_resolv}
              ${_trim_etc_entries}
            '' else
              ''
                --ro-bind /etc/static /etc/static
                --ro-bind /etc/ssl /etc/ssl
                --ro-bind /etc/pki /etc/pki
                --ro-bind /etc/resolv.conf /etc/resolv.conf
                ${_resolv}
                ${_trim_etc_entries}
              ''
          else
            "--ro-bind /etc /etc";

        ################
        # FLATPAK INFO #
        ################
        # without /.flatpak-info, programs will not use the XDG Desktop Portal
        # and instead will try to use the "default" portals, requiring that
        # DBUS-PROXY be configured like:
        #
        #   dbusProxy = {
        #     user = {
        #       talks = [
        #         "org.freedesktop.Notifications"
        #         "org.kde.StatusNotifierWatcher"
        #         # see: https://github.com/RalfJung/bubblebox/blob/master/profiles.py
        #         "org.mozilla.firefox.*"
        #         "org.mozilla.firefox_beta.*"
        #       ];
        #       #calls = [ "org.mozilla.firefox.*=@/org/mozilla/firefox/Remote" ];
        #     };
        #   };
        #   roBinds = [{ from = "$HOME/bwrap/mozilla/firefox/profiles.ini"; to = "$HOME/.mozilla/firefox/profiles.ini"; }];
        #
        # So when using dbus-proxy we add the flatpak-info to be able to use the portals on
        # https://flatpak.github.io/xdg-desktop-portal/docs/api-reference.html

        _flatpak_info_data = pkgs.writeText "flatpak-info" (lib.generators.toINI { } {
          Application = {
            name = "com.nixjail.${_normalized_name}";
            runtime = "runtime/com.nixjail.Platform/${pkgs.hostPlatform.parsed.cpu.name}";
          };
          Context.shared = concatStringsSep ";" ((lib.optional net "network") ++ (lib.optional ipc "ipc"));
          "Session Bus Policy" =
            let
              mapPolicies = policies: type: builtins.map (x: { name = x; value = type; }) policies;
            in
            builtins.listToAttrs (
              (mapPolicies dbusProxy.user.sees "see") ++
              (mapPolicies dbusProxy.user.talks "talk") ++
              (mapPolicies dbusProxy.user.owns "own")
            );
        });

        _flatpak_info = if dbusProxy.enable then "--ro-bind ${_flatpak_info_data} /.flatpak_info" else "";

        ##############
        # DBUS PROXY #
        ##############

        _dbus_args = optionalString dbusProxy.enable (concatStringsSep "\n" [
          (concatMapStrings (x: ''--see="${x}" '') dbusProxy.user.sees)
          (concatMapStrings (x: ''--talk="${x}" '') dbusProxy.user.talks)
          (concatMapStrings (x: ''--own="${x}" '') dbusProxy.user.owns)
          (concatMapStrings (x: ''--call="${x}" '') dbusProxy.user.calls)
          (concatMapStrings (x: ''--broadcast="${x}" '') dbusProxy.user.broadcasts)
        ]);
        _dbus_system_args = optionalString dbusProxy.enable (concatStringsSep "" [
          (concatMapStrings (x: ''--see="${x}" '') dbusProxy.system.sees)
          (concatMapStrings (x: ''--talk="${x}" '') dbusProxy.system.talks)
          (concatMapStrings (x: ''--own="${x}" '') dbusProxy.system.owns)
          (concatMapStrings (x: ''--call="${x}" '') dbusProxy.system.calls)
          (concatMapStrings (x: ''--broadcast="${x}" '') dbusProxy.system.broadcasts)
        ]);

        _dbus_proxy = optionalString dbusProxy.enable ''
          bwrap_cmd=(
            ${getBin pkgs.bubblewrap}/bin/bwrap
            --tmpfs /
            --ro-bind-try /nix /nix
            --ro-bind-try /etc /etc # required for /etc/xdg/xdg-desktop-portal/portals.conf
            --bind $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR
            --bind /run/dbus/system_bus_socket /run/dbus/system_bus_socket
            ${_flatpak_info}
            --new-session
            --unshare-all
            --die-with-parent
            --clearenv
            --
          )

          dbus_cmd=(
            ${getBin pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy
            $DBUS_SESSION_BUS_ADDRESS $XDG_RUNTIME_DIR/dbus-proxy-${name}-bus
            --filter ${optionalString dbusProxy.debug "--log"}
            ${_dbus_args}
          )

          dbus_system_cmd=(
            ${getBin pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy
            "unix:path=/run/dbus/system_bus_socket" "$XDG_RUNTIME_DIR/dbus-proxy-${name}-system_bus"
            --filter ${optionalString dbusProxy.debug "--log"}
            ${_dbus_system_args}
          )

          exec ''${bwrap_cmd[@]} ''${dbus_cmd[@]} &
          exec ''${bwrap_cmd[@]} ''${dbus_system_cmd[@]} &

          while ! test -S "$XDG_RUNTIME_DIR/dbus-proxy-${name}-bus"; do sleep 0.1; done
          while ! test -S "$XDG_RUNTIME_DIR/dbus-proxy-${name}-system_bus"; do sleep 0.1; done
        '';

        _dbus_binds =
          if dbusProxy.enable then ''
            --bind $XDG_RUNTIME_DIR/dbus-proxy-${name}-bus $XDG_RUNTIME_DIR/bus
            --bind $XDG_RUNTIME_DIR/dbus-proxy-${name}-system_bus /run/dbus/system_bus_socket
          '' else
            ''
              --ro-bind-try /run/dbus/system_bus_socket /run/dbus/system_bus_socket
              --ro-bind $XDG_RUNTIME_DIR/bus $XDG_RUNTIME_DIR/bus
            '';

        #########
        # EXTRA #
        #########

        # ldCache code adapted from: https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/build-fhsenv-bubblewrap/default.nix#L195
        #
        # Our glibc will look for the cache in its own path in `/nix/store`.
        # As such, we need a cache to exist there, because pressure-vessel
        # depends on the existence of an ld cache.
        # Also, the cache needs to go to both 32 and 64 bit glibcs, for games
        # of both architectures to work.
        _ldCache =
          if ldCache then
            ''
              --tmpfs ${pkgs.glibc}/etc
              --symlink /etc/ld.so.conf ${pkgs.glibc}/etc/ld.so.conf
              --symlink /etc/ld.so.cache ${pkgs.glibc}/etc/ld.so.cache
              --ro-bind-try ${pkgs.glibc}/etc/rpc ${pkgs.glibc}/etc/rpc
              --remount-ro ${pkgs.glibc}/etc
              --tmpfs ${pkgsi686Linux.glibc}/etc
              --symlink /etc/ld.so.conf ${pkgsi686Linux.glibc}/etc/ld.so.conf
              --symlink /etc/ld.so.cache ${pkgsi686Linux.glibc}/etc/ld.so.cache
              --ro-bind-try ${pkgsi686Linux.glibc}/etc/rpc ${pkgsi686Linux.glibc}/etc/rpc
              --remount-ro ${pkgsi686Linux.glibc}/etc
            ''
          else
            "";

        _new_session = if keepSession then "" else "--new-session";
        _extraConfig = concatStringsSep " " extraConfig;
      in
      {
        inherit name pre_exec post_exec;
        rwBinds = _rwBinds;
        roBinds = _roBinds;
        mkdir = _mkdir;
        dev_or_dri = _dev_or_dri;
        xdg = _xdg;
        net = _net;
        tmp = _tmp;
        ipc = _ipc;
        unshare = _unshare;
        flatpak_info = _flatpak_info;
        dbusProxy = _dbus_proxy;
        dbusBinds = _dbus_binds;
        new_session = _new_session;
        etc = _etc;
        ldCache = _ldCache;
        extraConfig = _extraConfig;
      }
  );

  # only tries to override when necessary, otherwise it
  # would fail with packages that can't override
  maybeOverride = (package: override_attrs:
    if (override_attrs == { })
    then package
    else
      (
        if package?override
        then package.override override_attrs
        else throw "package ${package} is not overridable"
      )
  );

  ##########################
  # BWRAP HELPER FUNCTIONS #
  ##########################

  bwrapItArgs = (
    { package ? null
    , symlinkJoin ? true
    , removeDesktopItems ? false
    , ...
    }@args:
      assert package != null;
      assert isBool removeDesktopItems;
      assert isBool symlinkJoin;
      (genericArgs (removeAttrs args [ "package" "symlinkJoin" "removeDesktopItems" ])) // {
        inherit package symlinkJoin removeDesktopItems;
      }
  );

  bwrapDerivataion =
    { package
    , dbusProxy
    , mkdir
    , xdg
    , etc
    , ldCache
    , new_session
    , unshare
    , dev_or_dri
    , net
    , tmp
    , ipc
    , rwBinds
    , roBinds
    , flatpak_info
    , dbusBinds
    , extraConfig
    , pre_exec
    , post_exec
    , removeDesktopItems
    , ...
    }: override_attrs:
    let
      _package = maybeOverride package override_attrs;
      _main_program = if _package.meta ? mainProgram then _package.meta.mainProgram else _package.name;

      _bwrap_script = path_var: ''
        # We need to split this script in 2 EOFs, because of how the $ interact with bash and nix
        # in the case of this EOF, we set the envs that will be used by the next EOF
        cat << EOF > "$out_path"
          #!${pkgs.stdenv.shell} -e
          #set -eux -o pipefail

          _path="${path_var}"
          _i="$i"
        EOF

        # this EOF is special, 'EOF' escapes all $ by default, preventing unexpected iteractions
        # and making sure that they will only be interpreted when running the generated script
        cat << 'EOF' >> "$out_path"
          # Run xdg-dbux-proxy so we can bind it later
          ${dbusProxy}

          ${mkdir}
          cmd=(
            ${getBin pkgs.bubblewrap}/bin/bwrap
            --tmpfs /
            --tmpfs /run
            --tmpfs /home
            --proc /proc
            --ro-bind-try /run/booted-system /run/booted-system
            --ro-bind-try /run/current-system /run/current-system
            --ro-bind-try /run/opengl-driver /run/opengl-driver
            --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32
            ${xdg}
            # fix sh and bash for some scripts
            --ro-bind-try ${pkgs.bash}/bin/sh /bin/sh
            --ro-bind-try ${pkgs.bash}/bin/bash /bin/bash
            --ro-bind-try /nix /nix
            --ro-bind-try /sys /sys
            --ro-bind-try /var /var
            --ro-bind-try /usr /usr
            ${etc}
            --die-with-parent
            ${ldCache}
            ${new_session}
            ${unshare}
            ${dev_or_dri}
            ${net}
            ${ipc}
            ${tmp}
            # https://github.com/flatpak/flatpak/blob/be2de97e862e5ca223da40a895e54e7bf24dbfb9/common/flatpak-run.c#L285
            --tmpfs /tmp/.X11-unix
            ${rwBinds}
            ${roBinds}
            ${dbusBinds}
            ${flatpak_info}
            ${extraConfig}
            --
            ${pre_exec} "$_path/$_i" ${post_exec}
          )
          #exec -a "$0" "''${cmd[@]}"
          exec "''${cmd[@]}"
        EOF
      '';
    in
    pkgs.stdenv.mkDerivation {
      name = "${_package.name}-bwrap";
      passthru = _package.passthru // { noBwrap = _package; };
      buildCommand = ''
        #
        # Copy and bwrap all binaries
        #
        bin_path="${_package}/bin"
        desktop_path="${_package}/share/applications"

        for i in $(${pkgs.coreutils}/bin/ls $bin_path); do
          mkdir -p "$out/bin"
          out_path="$out/bin/$i"

          ${_bwrap_script "$bin_path"}

          chmod +x "$out_path"
        done
      '' + (if removeDesktopItems
      then ""
      else ''
        for i in $(${pkgs.coreutils}/bin/ls $desktop_path); do
          mkdir -p "$out/share/applications"
          out_path="$out/share/applications/$i"

          cp $desktop_path/$i $out_path
          substituteInPlace $out_path --replace "${_package}" "$out"
          substituteInPlace $out_path --replace "Exec=${_main_program}" "Exec=$out/bin/${_main_program}"
        done
      '');
    };

  ##########################
  # FHS HELPER FUNCTIONS #
  ##########################

  fhsItArgs = (
    { runScript ? "$TERM"
    , profile ? ""
    , targetPkgs ? pkgs: [ ]
    , multiPkgs ? pkgs: [ ]
    , ...
    }@args:
      assert isString runScript;
      assert isFunction targetPkgs;
      assert isFunction multiPkgs;
      assert isString profile;

      (genericArgs (removeAttrs args [ "runScript" "profile" "targetPkgs" "multiPkgs" ])) // {
        inherit runScript profile targetPkgs multiPkgs;
      }
  );

  # based on: https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/build-fhsenv-bubblewrap/default.nix
  fhsUserEnv =
    { name
    , dbusProxy
    , mkdir
    , runScript
    , pre_exec
    , post_exec
    , targetPkgs
    , multiPkgs
    , profile
    , xdg
    , etc
    , new_session
    , unshare
    , dev_or_dri
    , net
    , tmp
    , ipc
    , rwBinds
    , roBinds
    , flatpak_info
    , dbusBinds
    , ldCache
    , extraConfig
    , ...
    }:
    let
      # not the same as pkgs.buildFHSEnv
      buildFHSEnv = pkgs.callPackage "${config.nixpkgs.flake.source}/pkgs/build-support/build-fhsenv-bubblewrap/buildFHSEnv.nix" { };
      fhsenv = buildFHSEnv {
        inherit name targetPkgs multiPkgs profile;
        extraOutputsToInstall = [ "dev" ];
      };

      bwrap_script = ''
        cmd=(
          ${getBin pkgs.bubblewrap}/bin/bwrap
          --tmpfs /
          --tmpfs /run
          --tmpfs /home
          --proc /proc
          --ro-bind-try /run/booted-system /run/booted-system
          --ro-bind-try /run/current-system /run/current-system
          --ro-bind-try /run/opengl-driver /run/opengl-driver
          --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32
          ${xdg}
          --ro-bind-try ${pkgs.coreutils}/bin/env /bin/env
          --ro-bind-try ${pkgs.bash}/bin/sh /bin/sh
          --ro-bind-try ${pkgs.bash}/bin/bash /bin/bash
          --ro-bind-try ${fhsenv}/sbin /sbin
          --ro-bind-try ${fhsenv}/lib /lib
          --ro-bind-try ${fhsenv}/lib64 /lib64
          --ro-bind-try ${fhsenv}/lib32 /lib32
          --ro-bind-try ${fhsenv}/usr /usr
          --ro-bind-try /nix /nix
          --ro-bind-try /sys /sys
          --ro-bind-try /var /var
          ${etc}
          --die-with-parent
          ${ldCache}
          ${new_session}
          ${unshare}
          ${dev_or_dri}
          ${net}
          ${ipc}
          ${tmp}
          # https://github.com/flatpak/flatpak/blob/be2de97e862e5ca223da40a895e54e7bf24dbfb9/common/flatpak-run.c#L285
          --tmpfs /tmp/.X11-unix
          ${rwBinds}
          ${roBinds}
          ${dbusBinds}
          ${flatpak_info}
          ${extraConfig}
          --
          bash -c 'source ${fhsenv}/etc/profile && ${pre_exec} ${runScript} ${post_exec}'
        )
        exec "''${cmd[@]}"
      '';
    in
    pkgs.writeScriptBin name ''
      #! ${pkgs.stdenv.shell} -e
      # Run xdg-dbux-proxy so we can bind it later
      ${dbusProxy}

      ${mkdir}

      ${bwrap_script}
    '';
}
