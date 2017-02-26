{ pkgs, config, ... }: let
  fd-limit.soft = "262140";
  fd-limit.hard = "524280";
  core-limit = "1048576"; # one gigabyte
in {
  time.timeZone = "UTC";

  networking.firewall.enable = false;

  environment.systemPackages = [
    pkgs.psmisc
    pkgs.htop
    config.boot.kernelPackages.sysdig
    config.boot.kernelPackages.perf
  ];
  boot.extraModulePackages = [
    config.boot.kernelPackages.sysdig
  ];
  boot.kernelModules = [ "sysdig-probe" ];

  security.pam.loginLimits = [ # login sessions only, not systemd services
    { domain = "*"; type = "hard"; item = "core"; value = core-limit; }
    { domain = "*"; type = "soft"; item = "core"; value = core-limit; }

    { domain = "*"; type = "soft"; item = "nofile"; value = fd-limit.soft; }
    { domain = "*"; type = "hard"; item = "nofile"; value = fd-limit.hard; }
  ];

  systemd.extraConfig = ''
    DefaultLimitCORE=${core-limit}
    DefaultLimitNOFILE=${fd-limit.soft}
  '';

  environment.etc."systemd/coredump.conf".text = ''
    [Coredump]
    Storage=journal
  '';

  boot.kernel.sysctl = {
    # allows control of core dumps with systemd-coredumpctl
    "kernel.core_pattern" = "|${pkgs.systemd}/lib/systemd/systemd-coredump %p %u %g %s %t %e";

    "fs.file-max" = fd-limit.hard;

    # moar ports
    "net.ipv4.ip_local_port_range" = "10000 65535";

    # should be the default, really
    "net.ipv4.tcp_slow_start_after_idle" = "0";
    "net.ipv4.tcp_early_retrans" = "1"; # 3.5+

    # backlogs
    "net.core.netdev_max_backlog" = "4096";
    "net.core.somaxconn" = "4096";

    # tcp receive flow steering (newer kernels)
    "net.core.rps_sock_flow_entries" = "32768";

    # max bounds for buffer autoscaling (16 megs for 10 gbe)
    #"net.core.rmem_max" = "16777216";
    #"net.core.wmem_max" = "16777216";
    #"net.core.optmem_max" = "40960";
    #"net.ipv4.tcp_rmem" = "4096 87380 16777216";
    #"net.ipv4.tcp_wmem" = "4096 65536 16777216";

    "net.ipv4.tcp_max_syn_backlog" = "8096";

    # read http://vincent.bernat.im/en/blog/2014-tcp-time-wait-state-linux.html
    "net.ipv4.tcp_tw_reuse" = "1";

    # vm
    #"vm.overcommit_memory" = lib.mkDefault "2"; # no overcommit
    #"vm.overcommit_ratio" = "100";
    "vm.swappiness" = "1"; # discourage swap

    # just in case for postgres and friends
    "kernel.msgmnb" = "65536";
    "kernel.msgmax" = "65536";
    "kernel.shmmax" = "68719476736";
  };
}
