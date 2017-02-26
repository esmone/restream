let
  inherit (import <nixpkgs/lib>) singleton;

  virtualbox = { ... }: {
    deployment.targetEnv = "virtualbox";
    deployment.virtualbox.headless = true;
  };

  extra-pkgs = { lib, pkgs, ... }: {
    options.extra = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; };
    config.extra = rec {
      bunny = pkgs.fetchurl {
        url = http://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_480p_h264.mov;
        sha256 = "09wsbgsyway1gjikabxd80g7igmlv3vgi6li5xvgk15kvjyvkb5j";
      };

      stream-bunny = pkgs.writeScriptBin "stream-bunny" ''
        stream=''${1:-rtmp://localhost/pub_secret/stream}
        ${pkgs.ffmpeg-full}/bin/ffmpeg -re -i ${bunny} -acodec copy -vcodec copy -f flv $stream
      '';

      restreamer = pkgs.writeScriptBin "restreamer" ''
        #!${pkgs.bash}/bin/bash
        export PATH_FFMPEG=${pkgs.ffmpeg-full}/bin/ffmpeg
        exec ${pkgs.python}/bin/python ${./restreamer.py} "$@"
      '';

      nginx = import ./nginx.nix {
        inherit pkgs;
        package = pkgs.nginx;
        user = "nginx";
        group = "nginx";
        ffmpeg = pkgs.ffmpeg-full;
        restream = "${restreamer}/bin/restreamer";
        stateDir = "/tmp";
        errorLog = "stderr";
        accessLog = "/tmp/access.log";
      };
    };
  };
in {
  restream =
    { resources, pkgs, config, ... }: {
      imports = [
        extra-pkgs
        virtualbox
        ./cloud-config.nix
      ];

      environment.systemPackages = [ config.extra.stream-bunny pkgs.nginx pkgs.ffmpeg-full ];

      users.extraUsers = singleton {
        name = "nginx";
        group = "nginx";
        uid = config.ids.uids.nginx;
      };

      users.extraGroups = singleton {
        name = "nginx";
        gid = config.ids.gids.nginx;
      };

      systemd.services.nginx = let cfg = config.extra.nginx; in {
        wantedBy = [ "multi-user.target" ];
        script = let s = pkgs.writeScript "nginx" ''
          ${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}/logs
          exec ${cfg.package}/bin/nginx -c ${cfg.configFile}  -p ${cfg.stateDir}
        ''; in "${s}";
      };
  };
}
