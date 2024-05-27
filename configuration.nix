{ config, lib, pkgs, ... }:

let
  isWsl = true;
  isHyperV = false;
  hostname = "multivac-nixos";
  work = false;

  hyperVResolution = "1920x1080";

  allInstalledPackages = lib.flatten ([config.environment.systemPackages] ++ (lib.mapAttrsToList (k: v: v.packages) config.users.users));
  hasPackage = p: lib.any (x: x == p) allInstalledPackages;

  # https://discourse.nixos.org/t/installing-only-a-single-package-from-unstable/5598/4
  unstable = import (fetchTarball https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz) { config = config.nixpkgs.config; };
  tip = import (fetchTarball https://github.com/NixOS/nixpkgs/archive/master.tar.gz) { config = config.nixpkgs.config; };

  #taskwarrior = unstable.taskwarrior3;
  taskwarrior = pkgs.taskwarrior;

in
{
  imports = [ ./channels.nix ./git.nix <home-manager/nixos> ]
    ++ lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ lib.optionals isWsl [ <nixos-wsl/modules> ./wsl.nix ]
    ++ lib.optional isHyperV ./hyperv.nix
    ++ lib.optional work ./work.nix
  ;

  config = {
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    virtualisation.hypervGuest.videoMode = hyperVResolution;

    # Set network basics.
    networking.hostName = hostname;

    # Always want to be in the UK.
    time.timeZone = "Europe/London";
    i18n.defaultLocale = "en_GB.UTF-8";

    # Always want to be using UK Dvorak.
    services.xserver.layout = "gb";
    services.xserver.xkbVariant = "dvorak";
    console.useXkbConfig = true;

    # Set up printing.
    services.printing.enable = true;
    services.printing.drivers = [ unstable.cups-kyocera-3500-4500 ];

    # Set up sound.
    sound.enable = true;
    hardware.pulseaudio.enable = true;

    # Always want Vim to be my editor.
    programs.vim.defaultEditor = true;
    programs.vim.package = pkgs.vim-full;

    # Configure rclone mount if rclone is installed.
    systemd.user.services = lib.optionalAttrs (hasPackage pkgs.rclone) {
      rclone-onedrive = {
        description = "OneDrive rclone mount";
        wantedBy = [ "default.target" ];
        unitConfig.AssertPathExists = "%h/.config/rclone/rclone.conf";
        serviceConfig.Type = "notify";
        serviceConfig.CacheDirectory = "rclone";
        preStart = ''
          # Make sure the mount point exists, and make sure the system clock is
          # synchronised as otherwise OneDrive won't be able to connect.

          set -euo pipefail

          ${pkgs.coreutils-full}/bin/mkdir -p "$HOME"/OneDrive

          if [[ -e /run/systemd/timesyncd/synchronized ]]; then
              # Clock is already synchronised so no need to do anything complicated.
              exit 0
          fi

          # Set up a coprocess to watch for the file that flags synchronisation is
          # complete.
          coproc inw {
              exec ${pkgs.inotify-tools}/bin/inotifywait -e create,moved_to \
                  --include '/synchronized$' /run/systemd/timesync 2>&1
          }

          # Wait for the coprocess to indicate it's ready.
          while read -r -u "''${inw[0]}" line; do
              if [[ "$line" = 'Watches established.' ]]; then
                  break
              fi
          done

          # Check the file still doesn't exist, to avoid a window condition between
          # setting up the watch process.
          if [[ -e /run/systemd/timesync/synchronized ]]; then
              kill "$inw_PID"
              rc=0
              wait "$inw_PID" || rc="$?"
              if (( rc == 143 )); then
                  exit 0
              else
                  printf 'Unexpected inotifywait return code %s\n' "$rc"
                  exit 1
              fi
          fi

          # Wait for the coprocess to exit, indicating the flag file has been created.
          time wait "$inw_PID";
        '';
        script = ''
          set -xeuo pipefail

          if [[ :"$PATH": != *:'${config.security.wrapperDir}':* ]]; then
              PATH="${config.security.wrapperDir}:$PATH"
          fi

          # exec necessary here because otherwise Bash will start this as a
          # subprocess, and systemctl will see the service notification coming
          # from the wrong PID.
          exec "${pkgs.rclone}/bin/rclone" mount \
              --config="$HOME"/.config/rclone/rclone.conf --vfs-cache-mode=full \
              --cache-dir="$CACHE_DIRECTORY" onedrive: "$HOME"/OneDrive
        '';
        serviceConfig.ExecReload = "${pkgs.util-linux}/bin/kill -HUP \$MAINPID";
      };
    };

    # Always want a /mnt directory.
    system.activationScripts.mnt = "mkdir -m 700 -p /mnt";

    # Check the channel list is as expected.
    nix.checkChannels = true;
    nix.channels = {
      home-manager = https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz;
      nixos = https://nixos.org/channels/nixos-23.11;
    };

    # Always want locate running.
    services.locate = {
      enable = true;
      package = pkgs.plocate;
      localuser = null;  # Needed to silence warning about running as root.
    };

    environment.systemPackages = with pkgs; [
      file
      home-manager
      htop
      moreutils
      psmisc
    ];

    # If this isn't WSL, want OpenSSH for inbound connections, and mDNS for both
    # inbound and outbound connections.
    services.openssh.enable = true;
    services.avahi.enable = true;
    services.avahi.nssmdns = true;

    # Always want fixed users.
    users.mutableUsers = false;

    programs.git.enable = true;
    programs.git.sourceBranch = "next";

    home-manager.useGlobalPkgs = true;

    # Set up my user account.
    users.users.adam = {
      isNormalUser = true;
      hashedPasswordFile = "/etc/nixos/passwords/adam";
      description = "Adam Dinwoodie";
      extraGroups = [ "wheel" ];
#      packages = with pkgs; [
#        fzf
#        home-manager
#        lesspipe
#        mosh
#        silver-searcher
#        taskwarrior
#        gh
#        mypy
#      ];
      linger = true;
    };

    # Enable nix-index, run it automatically, and replace command-not-found with
    # it.
    programs.nix-index.enable = true;
    programs.nix-index.enableBashIntegration = true;
    programs.command-not-found.enable = false;
    environment.variables.NIX_INDEX_DATABASE = "/var/cache/nix-index";
    systemd.services.nix-index = {
      script = "${pkgs.nix-index}/bin/nix-index";
      environment.NIX_INDEX_DATABASE = "/var/cache/nix-index";
      environment.NIX_PATH = "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels";
    };
    systemd.timers.nix-index = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon 18:00";
        AccuracySec = "24h";
        RandomizedDelaySec = "1h";
        Persistent = "true";
      };
    };

    # Clean the Nix config store regularly.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      randomizedDelaySec = "6h";
      options = "--delete-older-than 7d";
    };

    # Trust anyone in the wheel group
    nix.settings.trusted-users = [ "@wheel" ];

    nixpkgs.config.allowUnfree = true;

    # This is the thing that comes with An Million Warnings about ever
    # changing...
    system.stateVersion = "23.11";
  };
}

# TODO Better modeline and/or better Vim plugins for Nix config files.
# vim: et ts=2 sw=2 autoindent ft=nix