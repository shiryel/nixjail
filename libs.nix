{ lib, pkgs, ... }:

with builtins;
with lib;

# NOTE:
# A fake dbus like this Will hide tray and fix some issues, 
# but some apps will keep running in backgroud
#
# fake_dbus =
#   if fake_dbus then "export $(dbus-launch)" else "";

let
  pkgsi686Linux = pkgs.pkgsi686Linux;
in
rec {
  _generic_args = (
    { name ? null
    , args ? ''"$@"''
    , rwBinds ? [ ] # [string] | [{from: string; to: string;}]
    , roBinds ? [ ] # [string] | [{from: string; to: string;}]
    , autoBindHome ? true
    , homeDirRoot ? "~/bwrap"
    , defaultBinds ? true
    , dri ? false # video acceleration
    , dev ? false # Vulkan support / devices usage
    , xdg ? "ro" # true | false | "ro"
    , net ? false
    , tmp ? false # some tray icons needs it
    , unshareAll ? true
      # Fixes "cannot set terminal process group (-1)" but is 
      # not recommended because of a security issue with TIOCSTI [1]
      # [1] - https://wiki.archlinux.org/title/Bubblewrap#New_session
    , keepSession ? false
    , extraConfig ? [ ]
    }:
      assert isString name;
      assert isString args;
      assert isList rwBinds;
      assert isList roBinds;
      assert isBool autoBindHome;
      assert isString homeDirRoot;
      assert isBool defaultBinds;
      assert isBool dri;
      assert isBool dev;
      assert asserts.assertOneOf "bwrap.xdg" xdg [ "ro" true false ];
      assert isBool net;
      assert isBool tmp;
      assert isBool unshareAll;
      assert isBool keepSession;
      assert isList extraConfig;
      let
        _auto_bind_home =
          if autoBindHome then [{
            from = "${homeDirRoot}/${name}";
            to = "~/";
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
          # the same bwrap enviroment, like steam, steam-run and protontricks). To fix this
          # problem we bind the bwrap enviroment inside itself, so it will be available in case
          # the program call itself (and create a new bwrap)
          (b: b ++ (map (x: if isList (match ".*(bwrap).*" x.from) then [{ from = x.from; to = x.from; }] else [ ]) b))
          lists.flatten
          (map (x: ''--bind-try $(readlink -mn ${x.from}) ${x.to}''))
          (concatStringsSep "\n")
        ];

        _extra_roBinds =
          if defaultBinds then [
            "~/.config/mimeapps.list"
            "~/.local/share/applications/mimeapps.list"
            "~/.config/dconf"
            "~/.config/gtk-3.0/settings.ini"
            "~/.config/gtk-4.0/settings.ini"
            "~/.gtkrc-2.0"
          ] else [ ];

        _roBinds = pipe (roBinds ++ _extra_roBinds) [
          _normalize_binds
          (map (x: ''--ro-bind-try $(readlink -mn ${x.from}) ${x.to}''))
          (concatStringsSep "\n")
        ];

        # mkdir -p (only if bwrap is on the name)
        _mkdir = pipe (_auto_bind_home ++ rwBinds) [
          _normalize_binds
          (map (x: if isList (match ".*(bwrap).*" x.from) then "mkdir -p ${x.from}" else ""))
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
          if xdg == "ro" then "" else
          if xdg then "--bind-try $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR" else "--tmpfs $XDG_RUNTIME_DIR";

        _net = if net then "--share-net" else "";
        _tmp = if tmp then "--bind-try /tmp /tmp" else "--tmpfs /tmp";
        _unshare = if unshareAll then "--unshare-all" else "";
        _new_session = if keepSession then "" else "--new-session";
        _extraConfig = concatStringsSep " " extraConfig;
      in
      {
        name = name;
        args = args;
        rwBinds = _rwBinds;
        roBinds = _roBinds;
        mkdir = _mkdir;
        dev_or_dri = _dev_or_dri;
        xdg = _xdg;
        net = _net;
        tmp = _tmp;
        unshare = _unshare;
        new_session = _new_session;
        extraConfig = _extraConfig;
      }
  );

  _bwrapIt_args = (
    { package ? null
    , symlinkJoin ? true
    , ldCache ? false
    , ...
    }@bwrapIt_args:
      assert package != null;
      assert isBool ldCache;
      assert isBool symlinkJoin;
      let
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
      in
      (_generic_args (removeAttrs bwrapIt_args [ "package" "symlinkJoin" "ldCache" ])) // {
        inherit package symlinkJoin;
        ldCache = _ldCache;
      }
  );

  _fhsIt_args = (
    { runScript ? "$TERM"
    , profile ? ""
    , targetPkgs ? pkgs: [ ]
    , multiPkgs ? pkgs: [ ]
    , ...
    }@fhsIt_args:
      assert isString runScript;
      assert isFunction targetPkgs;
      assert isFunction multiPkgs;
      assert isString profile;

      (_generic_args (removeAttrs fhsIt_args [ "runScript" "profile" "targetPkgs" "multiPkgs" ])) // {
        inherit runScript profile targetPkgs multiPkgs;
      }
  );

  # only tries to override when necessary, otherwise it
  # would fail with packages that can't override
  maybeOverride = (package: override_args:
    if (override_args == { })
    then package
    else
      (
        if package?override
        then package.override override_args
        else throw "package ${package} is not overridable"
      )
  );

  # NOTE: Remember to follow the binding order from ~/
  # eg: ~/ ~/.config ~/.config/*
  bwrapIt = bwrapIt_args:
    let
      _args = _bwrapIt_args bwrapIt_args;

      _derivation = override_args:
        with _args;

        let
          _package = maybeOverride package override_args;

          _bwrap_script = path_var: ''
            # We need to split this script in 2 EOFs, because of how the $ interact with bash and nix
            # in the case of this EOF, we set the envs that will be used by the next EOF
            cat << EOF > "$out_path"
              #!${pkgs.stdenv.shell} -e
              path="${path_var}"
              i="$i"
            EOF

            # this EOF is special, 'EOF' escapes all $ by default, preventing unexpected iteractions
            # and making sure that they will only be interpreted when running the generated script
            cat << 'EOF' >> "$out_path"
              ${mkdir}
              cmd=(
                ${lib.getBin pkgs.bubblewrap}/bin/bwrap
                --tmpfs /
                --ro-bind-try /run /run
                # fix sh and bash for some scripts
                --ro-bind-try /bin/sh /bin/sh
                --ro-bind-try /bin/sh /bin/bash
                --ro-bind-try /etc /etc
                --ro-bind-try /nix /nix
                --ro-bind-try /sys /sys
                --ro-bind-try /var /var
                --ro-bind-try /usr /usr
                --ro-bind-try /opt /opt
                --proc /proc
                --tmpfs /home
                --tmpfs /keep
                --die-with-parent
                ${ldCache}
                ${new_session}
                ${unshare}
                ${dev_or_dri}
                ${xdg}
                ${net}
                ${tmp}
                ${rwBinds}
                ${roBinds}
                ${extraConfig}
                "$path/$i" ${args}
                )
              exec -a "$0" "''${cmd[@]}"
            EOF
          '';
        in
        pkgs.stdenv.mkDerivation {
          name = "${_package.name}-bwrap";
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

            for i in $(${pkgs.coreutils}/bin/ls $desktop_path); do
              mkdir -p "$out/share/applications"
              out_path="$out/share/applications/$i"

              cp $desktop_path/$i $out_path
              substituteInPlace $out_path --replace "${_package}" "$out"
            done
          '';
        };
    in
    makeOverridable
      (x: (
        if _args.symlinkJoin
        # make man pages, desktop entries and libs available
        then pkgs.symlinkJoin { name = "${_args.package.name}-bwraplink"; paths = [ (_derivation x) (maybeOverride _args.package x) ]; }
        else (_derivation x)
      ))
      { };

  fhsIt = (fhsIt_args:
    (with (_fhsIt_args fhsIt_args);

    pkgs.writeScriptBin name ''
      #! ${pkgs.stdenv.shell} -e
      ${mkdir}

      ${pkgs.buildFHSUserEnvBubblewrap {
        name = "${name}";
        runScript = "${runScript} ${args}";
        targetPkgs = targetPkgs;
        multiPkgs = multiPkgs;
        profile = profile;
        extraOutputsToInstall = [ "dev" ];
        extraBwrapArgs = [
          "--proc /proc"
          "--tmpfs /home"
          "--tmpfs /keep"
          "--die-with-parent"
          "${new_session}"
          "${unshare}"
          "${dev_or_dri}"
          "${xdg}"
          "${net}"
          "${tmp}"
          "${rwBinds}"
          "${roBinds}"
          "${extraConfig}"
        ];
      }}/bin/${name}
    ''
    )
  );
}
