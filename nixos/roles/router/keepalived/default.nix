{ config, pkgs, lib, ... }:

with builtins;

let
  inherit (config) fclib;
  inherit (config.networking) hostName;
  inherit (config.flyingcircus) location;
  role = config.flyingcircus.roles.router;
  locationConfig = readFile (./. + "/${location}.conf");
  routerId = "${hostName}.gocept.net";

  checkDefaultRoute4 = fclib.writeShellApplication {
    name = "check-default-route-v4";
    runtimeInputs = with pkgs; [ iproute2 ];
    text = ''
      ip -4 route | grep "''${1:-default}"
    '';
  };

  checkDefaultRoute6 = fclib.writeShellApplication {
    name = "check-default-route-v6";
    runtimeInputs = with pkgs; [ iproute2 ];
    text = ''
      ip -6 route | grep "''${1:-default}"
    '';
  };

  keepalivedConf = pkgs.writeText "keepalived.conf" ''
    global_defs {
      enable_script_security
      config_save_dir /var/lib/keepalived/saved_config
      notification_email { admin+${hostName}@flyingcircus.io }
      notification_email_from admin+${hostName}@flyingcircus.io
      smtp_server mail.gocept.net
      smtp_connect_timeout 30
      router_id ${routerId}
      script_user root
      use_symlink_paths true
    }

    ${locationConfig}
    '';
in
lib.mkIf role.enable {

  environment.etc."keepalived/check-default-route-v4".source = "${checkDefaultRoute4}/bin/check-default-route-v4";
  environment.etc."keepalived/check-default-route-v6".source = "${checkDefaultRoute6}/bin/check-default-route-v6";
  environment.etc."keepalived/fc-manage".source = "${pkgs.fc.agent}/bin/fc-manage";
  environment.etc."keepalived/keepalived.conf".source = keepalivedConf;

  environment.systemPackages = with pkgs; [
    keepalived
    checkDefaultRoute4
    checkDefaultRoute6
  ];

  services.keepalived = {
    enable = true;
    # XXX: We override the keepalived config file in ExecStart below,
    # using config options here has no effect.
  };

  systemd.services.keepalived = {
    # Restarting is ok for secondary routers but we have to avoid
    # restarts on the primary router to not interrupt things.
    # XXX: This means that some changes won't be active on primary routers
    # until a switchover happens.
    reloadIfChanged = role.isPrimary;
    restartTriggers = [ keepalivedConf ];
    serviceConfig = {
      Type = lib.mkOverride 90 "simple";
      ExecStart = lib.mkOverride 90 ("${pkgs.keepalived}/sbin/keepalived"
        + " -f /etc/keepalived/keepalived.conf"
        + " -p /run/keepalived.pid"
        + " -n");
      StateDirectory = "keepalived";
    };
  };

  systemd.tmpfiles.rules = [
    "d /etc/keepalived 0755 root root"
    "f /etc/keepalived/stop 0644 root root - 0"
  ];
}
