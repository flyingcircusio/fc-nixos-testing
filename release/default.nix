# everything in release/ MUST NOT import from <nixpkgs> to get repeatable builds
{ system ? builtins.currentSystem
, bootstrap ? <nixpkgs>
, nixpkgs_ ? (import ../versions.nix { pkgs = import bootstrap {}; }).nixpkgs
, branch ? null  # e.g. "fc-20.09-dev"
, stableBranch ? false
, supportedSystems ? [ "x86_64-linux" ]
, fc ? {
    outPath = ./.;
    revCount = 0;
    rev = "0000000000000000000000000000000000000000";
    shortRev = "0000000";
  }
, scrubJobs ? true  # Strip most of attributes when evaluating
}:

with builtins;

with import "${nixpkgs_}/pkgs/top-level/release-lib.nix" {
  inherit supportedSystems scrubJobs;
  nixpkgsArgs = { config = { allowUnfree = true; inHydra = true; }; nixpkgs = nixpkgs_; };
  packageSet = import ../.;
};
# pkgs and lib imported from release-lib.nix

let
  shortRev = fc.shortRev or (substring 0 11 fc.rev);
  version = lib.fileContents "${nixpkgs_}/.version";
  versionSuffix =
    (if stableBranch then "." else ".dev") +
    "${toString fc.revCount}.${shortRev}";
  version_nix = pkgs.writeText "version.nix" ''
    { ... }:
    {
      system.nixos.revision = "${fc.rev}";
      system.nixos.versionSuffix = "${versionSuffix}";
    }
  '';

  upstreamSources = (import ../versions.nix { pkgs = (import nixpkgs_ {}); });

  fcSrc = pkgs.stdenv.mkDerivation {
    name = "fc-overlay";
    src = lib.cleanSource ../.;
    builder = pkgs.stdenv.shell;
    PATH = with pkgs; lib.makeBinPath [ coreutils ];
    args = [ "-ec" ''
      cp -r $src $out
      chmod +w $out/nixos/version.nix
      cat ${version_nix} > $out/nixos/version.nix
    ''];
    preferLocalBuild = true;
  };

  combinedSources =
    pkgs.stdenv.mkDerivation {
      inherit fcSrc;
      inherit (upstreamSources) allUpstreams;
      name = "channel-sources-combined";
      builder = pkgs.stdenv.shell;
      PATH = with pkgs; lib.makeBinPath [ coreutils ];
      args = [ "-ec" ''
        mkdir -p $out/nixos
        cp -r $allUpstreams/* $out/nixos/
        ln -s $fcSrc $out/nixos/fc
        echo -n ${fc.rev} > $out/nixos/.git-revision
        echo -n ${version} > $out/nixos/.version
        echo -n ${versionSuffix} > $out/nixos/.version-suffix
        # default.nix is needed when the channel is imported directly, for example
        # from a fetchTarball.
        echo "{ ... }: import ./fc { nixpkgs = ./nixpkgs; }" > $out/nixos/default.nix
      ''];
      preferLocalBuild = true;
    };

  initialNixChannels = pkgs.writeText "nix-channels" ''
    https://hydra.flyingcircus.io/channel/custom/flyingcircus/fc-${version}-dev/release nixos
  '';

  initialVMContents = [
    { source = initialNixChannels;
      target = "/root/.nix-channels";
    }
    {
      source = (pkgs.writeText "fc-agent-initial-run" ''
        VM ignores roles and just builds a minimal system while this marker file
        is present. This will be deleted during first agent run.
      '');
      target = "/etc/nixos/fc_agent_initial_run";
    }
    { source = ../nixos/etc_nixos_local.nix;
      target = "/etc/nixos/local.nix";
    }
  ];

  modifiedPkgNames = attrNames (import ../pkgs/overlay.nix pkgs pkgs);

  excludedPkgNames = [
    # Build fails with patch errors.
    "gitlab"
    "gitlab-workhorse"
    # XXX: builds chromium at the moment, remove this
    "jibri"
    # The kernel universe is _huge_ and contains a lot of unfree stuff. Kernel
    # packages which are really needed are pulled in as dependencies anyway.
    "linux"
    "linux_5_4"
    "linuxPackages"
    "linuxPackages_5_4"
    # Same as above, don't pull everything in here
    "python2Packages"
    "python27Packages"
    "python3Packages"
    "python37Packages"
    "python38Packages"
    "python310Packages"
    # XXX: fails on 21.05, must be fixed
    "backy"
  ];

  includedPkgNames = [
    "calibre"
    "irqbalance"
  ];

  testPkgNames = includedPkgNames ++
    lib.subtractLists excludedPkgNames modifiedPkgNames;

  testPkgs =
    listToAttrs (map (n: { name = n; value = pkgs.${n}; }) testPkgNames);

  platformRoleDoc =
  let
    html = import ../doc {
      inherit pkgs;
      branch = if branch != null then branch else "fc-${version}";
      updated = "${toString fc.revCount}.${shortRev}";
      failOnWarnings = true;
    };
  in lib.hydraJob (
    pkgs.runCommandLocal "platform-role-doc" { inherit html; } ''
      mkdir -p $out/nix-support
      tarball=$out/platform-role-doc.tar.gz
      tar czf $tarball --mode +w -C $html .
      echo "file tarball $tarball" > $out/nix-support/hydra-build-products
    ''
  );

  doc = { roles = platformRoleDoc; };

  jobs = {
    pkgs = mapTestOn (packagePlatforms testPkgs);
    tests = import ../tests { inherit system pkgs; nixpkgs = nixpkgs_; };
  };

  makeNetboot = config:
    let
      evaled = import "${nixpkgs_}/nixos/lib/eval-config.nix" config;
      build = evaled.config.system.build;
      kernelTarget = evaled.pkgs.stdenv.hostPlatform.linux-kernel.target;

      customIPXEScript = pkgs.writeTextDir "netboot.ipxe" ''
        #!ipxe

        set console ttyS1
        set speed 115200

        :start
        menu Flying Circus Installer boot menu
        item --gap --          --- Info ---
        item --gap --           Console: console=''${console},''${speed}
        item --gap --          --- Settings ---
        item console_tty0      console=tty0
        item console_ttys0     console=ttyS0
        item console_ttys1     console=ttyS1
        item console_ttys2     console=ttyS2
        item console_enter     [Enter manual value for `console`]
        item speed_115200      speed=115200
        item speed_57600       speed=57600
        item speed_enter       [Enter manual value for `speed`]
        item --gap --          --- Install ---
        item boot_installer    Boot installer
        item --gap --          --- Other ---
        item exit              Continue BIOS boot
        item local             Continue boot from local disk
        item shell             Drop to iPXE shell
        item reboot            Reboot computer

        choose selected
        goto ''${selected}
        goto error

        :console_enter
        echo -n console= && read console
        goto start

        :console_tty0
        set console tty0
        goto start

        :console_ttys1
        set console ttyS1
        goto start

        :console_ttys0
        set console ttyS0
        goto start

        :console_ttys2
        set console ttyS2
        goto start

        :speed_115200
        set speed 115200
        goto start

        :speed_57600
        set speed 57600
        goto start

        :speed_enter
        echo -n speed= && read console
        goto start

        :local
        sanboot || goto error

        :reboot
        reboot

        :shell
        echo Type 'exit' to get the back to the menu
        shell
        set menu-timeout 0
        set submenu-timeout 0
        goto start

        :boot_installer
        kernel ${kernelTarget} init=${build.toplevel}/init console=''${console},''${speed} initrd=initrd loglevel=4
        initrd initrd
        boot || goto error

        :error
        echo An error occured. Will fall back to menu in 15 seconds.
        sleep 15
        goto start
        '';
    in
      pkgs.symlinkJoin {
        name = "netboot-${evaled.config.system.nixos.label}-${system}";
        paths = [];
        postBuild = ''
          mkdir -p $out/nix-support
          cp ${build.netbootRamdisk}/initrd  $out/
          cp ${build.kernel}/${kernelTarget}  $out/
          cp ${customIPXEScript}/netboot.ipxe $out/

          echo "file ${kernelTarget} $out/${kernelTarget}" >> $out/nix-support/hydra-build-products
          echo "file initrd $out/initrd" >> $out/nix-support/hydra-build-products
          echo "file ipxe $out/netboot.ipxe" >> $out/nix-support/hydra-build-products
        '';
        preferLocalBuild = true;
      };

  channelsUpstream =
    lib.mapAttrs (name: src:
    let
      fullName =
        if (parseDrvName name).version != ""
        then "${src.name}.${substring 0 11 src.rev}"
        else "${src.name}-0.${substring 0 11 src.rev}";
    in pkgs.releaseTools.channel {
      inherit src;
      name = fullName;
      constituents = [ src ];
      patchPhase = ''
        echo -n "${src.rev}" > .git-revision
      '';
      passthru.channelName = src.name;
      meta.description = "${src.name} according to versions.json";
    })
    (removeAttrs upstreamSources [ "allUpstreams" ]);

  channels = channelsUpstream // {
    # The attribute name `fc` if important because if channel is added without
    # an explicit name argument, it will be available as <fc>.
    fc = with lib; pkgs.releaseTools.channel {
      name = "fc-${version}${versionSuffix}";
      constituents = [ fcSrc ];
      src = fcSrc;
      patchPhase = ''
        echo -n "${fc.rev}" > .git-revision
        echo -n "${versionSuffix}" > .version-suffix
        echo -n "${version}" > .version
      '';
      passthru.channelName = "fc";
      meta = {
        description = "Main channel of the <fc> overlay";
        homepage = "https://flyingcircus.io/doc/";
        license = [ licenses.bsd3 ];
        maintainer = with maintainers; [ ckauhaus ];
      };
    };
  };

  # run upstream tests against our overlay
  upstreamTests = {
    inherit (pkgs.nixosTests)
      matomo;
  };

  images =
    let
      imgArgs = {
        nixpkgs = nixpkgs_;
        version = "${version}${versionSuffix}";
        channelSources = combinedSources;
        configFile = ../nixos/etc_nixos_local.nix;
        contents = initialVMContents;
      };
    in
    {

    # iPXE netboot image
    netboot = lib.hydraJob (makeNetboot {
     inherit system;

     modules = [
       "${nixpkgs_}/nixos/modules/installer/netboot/netboot-minimal.nix"
       (import version_nix {})
       ./netboot-installer.nix
     ];
    });

    # VM image for the Flying Circus infrastructure.
    fc = lib.hydraJob (import "${nixpkgs_}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        (import ./vm-image.nix imgArgs)
        (import version_nix {})
        ../nixos
        ../nixos/roles
      ];
    }).config.system.build.fcImage;

    # VM image for devhost VMs
    dev-vm = lib.hydraJob (import "${nixpkgs_}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        (import ./dev-vm-image.nix imgArgs)
        (import version_nix {})
        ../nixos
        ../nixos/roles
      ];
    }).config.system.build.devVMImage;

  };

in

jobs // {
  inherit channels images doc;

  release = with lib; pkgs.releaseTools.channel rec {
    name = "release-${version}${versionSuffix}";
    src = combinedSources;
    constituents = [
      src
      "pkgs.fc.install.x86_64-linux"
      "pkgs.ipxe.x86_64-linux"
      "pkgs.irqbalance.x86_64-linux"
      "channels.fc"
      "channels.nixos-mailserver"
      "channels.nixpkgs"
      "channels.nixpkgs-23_05"
      "doc.roles"
      "images.dev-vm"
      "images.fc"
      "images.netboot"
      "pkgs.auditbeat7.x86_64-linux"
      "pkgs.bird.x86_64-linux"
      "pkgs.bird2.x86_64-linux"
      "pkgs.bird6.x86_64-linux"
      "pkgs.busybox.x86_64-linux"
      "pkgs.calibre.x86_64-linux"
      "pkgs.ceph-client.x86_64-linux"
      "pkgs.ceph.x86_64-linux"
      "pkgs.certmgr.x86_64-linux"
      "pkgs.cgmemtime.x86_64-linux"
      "pkgs.check_ipmi_sensor.x86_64-linux"
      "pkgs.check_md_raid.x86_64-linux"
      "pkgs.check_megaraid.x86_64-linux"
      "pkgs.containerd.x86_64-linux"
      "pkgs.docsplit.x86_64-linux"
      "pkgs.dstat.x86_64-linux"
      "pkgs.elasticsearch7-oss.x86_64-linux"
      "pkgs.elasticsearch7.x86_64-linux"
      "pkgs.fc.agent.x86_64-linux"
      "pkgs.fc.blockdev.x86_64-linux"
      "pkgs.fc.ceph.x86_64-linux"
      "pkgs.fc.check-age.x86_64-linux"
      "pkgs.fc.check-ceph-nautilus.x86_64-linux"
      "pkgs.fc.check-haproxy.x86_64-linux"
      "pkgs.fc.check-journal.x86_64-linux"
      "pkgs.fc.check-link-redundancy.x86_64-linux"
      "pkgs.fc.check-mongodb.x86_64-linux"
      "pkgs.fc.check-postfix.x86_64-linux"
      "pkgs.fc.check-rib-integrity.x86_64-linux"
      "pkgs.fc.check-xfs-broken.x86_64-linux"
      "pkgs.fc.collectdproxy.x86_64-linux"
      "pkgs.fc.fix-so-rpath.x86_64-linux"
      "pkgs.fc.ipmitool.x86_64-linux"
      "pkgs.fc.ledtool.x86_64-linux"
      "pkgs.fc.lldp-to-altname.x86_64-linux"
      "pkgs.fc.logcheckhelper.x86_64-linux"
      "pkgs.fc.megacli.x86_64-linux"
      "pkgs.fc.multiping.x86_64-linux"
      "pkgs.fc.neighbour-cache-monitor.x86_64-linux"
      "pkgs.fc.ping-on-tap.x86_64-linux"
      "pkgs.fc.qemu-nautilus.x86_64-linux"
      "pkgs.fc.roundcube-chpasswd.x86_64-linux"
      "pkgs.fc.secure-erase.x86_64-linux"
      "pkgs.fc.sensuplugins.x86_64-linux"
      "pkgs.fc.sensusyntax.x86_64-linux"
      "pkgs.fc.telegraf-collect-psi.x86_64-linux"
      "pkgs.fc.telegraf-routes-summary.x86_64-linux"
      "pkgs.fc.trafficclient.x86_64-linux"
      "pkgs.fc.userscan.x86_64-linux"
      "pkgs.fc.util-physical.x86_64-linux"
      "pkgs.filebeat7.x86_64-linux"
      "pkgs.flannel.x86_64-linux"
      "pkgs.frr.x86_64-linux"
      "pkgs.graylog.x86_64-linux"
      "pkgs.grub2_full.x86_64-linux"
      "pkgs.haproxy.x86_64-linux"
      "pkgs.innotop.x86_64-linux"
      "pkgs.ipmitool.x86_64-linux"
      "pkgs.jicofo.x86_64-linux"
      "pkgs.jitsi-meet.x86_64-linux"
      "pkgs.jitsi-videobridge.x86_64-linux"
      "pkgs.keepalived.x86_64-linux"
      "pkgs.kibana7-oss.x86_64-linux"
      "pkgs.kibana7.x86_64-linux"
      "pkgs.kubernetes-dashboard-metrics-scraper.x86_64-linux"
      "pkgs.kubernetes-dashboard.x86_64-linux"
      "pkgs.lamp_php56.x86_64-linux"
      "pkgs.lamp_php72.x86_64-linux"
      "pkgs.lamp_php73.x86_64-linux"
      "pkgs.lamp_php74.x86_64-linux"
      "pkgs.lamp_php80.x86_64-linux"
      "pkgs.libceph.x86_64-linux"
      "pkgs.libmodsecurity.x86_64-linux"
      "pkgs.libpcap-vxlan.x86_64-linux"
      "pkgs.matomo-beta.x86_64-linux"
      "pkgs.matomo.x86_64-linux"
      "pkgs.matrix-synapse.x86_64-linux"
      "pkgs.mc.x86_64-linux"
      "pkgs.microcodeAmd.x86_64-linux"
      "pkgs.microcodeIntel.x86_64-linux"
      "pkgs.mongodb-3_6.x86_64-linux"
      "pkgs.mongodb-4_0.x86_64-linux"
      "pkgs.mongodb-4_2.x86_64-linux"
      "pkgs.monitoring-plugins.x86_64-linux"
      "pkgs.mysql.x86_64-linux"
      "pkgs.nginx.x86_64-linux"
      "pkgs.nginxMainline.x86_64-linux"
      "pkgs.nginxStable.x86_64-linux"
      "pkgs.openssh_9_6.x86_64-linux"
      "pkgs.percona-toolkit.x86_64-linux"
      "pkgs.percona-xtrabackup_8_0.x86_64-linux"
      "pkgs.percona.x86_64-linux"
      "pkgs.percona56.x86_64-linux"
      "pkgs.percona57.x86_64-linux"
      "pkgs.percona80.x86_64-linux"
      "pkgs.php56.x86_64-linux"
      "pkgs.php72.x86_64-linux"
      "pkgs.polkit.x86_64-linux"
      "pkgs.postgis_2_5.x86_64-linux"
      "pkgs.prometheus-elasticsearch-exporter.x86_64-linux"
      "pkgs.py_pytest_patterns.x86_64-linux"
      "pkgs.qemu-ceph-nautilus.x86_64-linux"
      "pkgs.qemu.x86_64-linux"
      "pkgs.rabbitmq-server_3_8.x86_64-linux"
      "pkgs.remarshal.x86_64-linux"
      "pkgs.rum.x86_64-linux"
      "pkgs.sensu-plugins-disk-checks.x86_64-linux"
      "pkgs.sensu-plugins-elasticsearch.x86_64-linux"
      "pkgs.sensu-plugins-entropy-checks.x86_64-linux"
      "pkgs.sensu-plugins-http.x86_64-linux"
      "pkgs.sensu-plugins-influxdb.x86_64-linux"
      "pkgs.sensu-plugins-kubernetes.x86_64-linux"
      "pkgs.sensu-plugins-logs.x86_64-linux"
      "pkgs.sensu-plugins-memcached.x86_64-linux"
      "pkgs.sensu-plugins-mysql.x86_64-linux"
      "pkgs.sensu-plugins-network-checks.x86_64-linux"
      "pkgs.sensu-plugins-postfix.x86_64-linux"
      "pkgs.sensu-plugins-postgres.x86_64-linux"
      "pkgs.sensu-plugins-rabbitmq.x86_64-linux"
      "pkgs.sensu-plugins-redis.x86_64-linux"
      "pkgs.sensu-plugins-systemd.x86_64-linux"
      "pkgs.sensu.x86_64-linux"
      "pkgs.sudo.x86_64-linux"
      "pkgs.tcpdump.x86_64-linux"
      "pkgs.temporal_tables.x86_64-linux"
      "pkgs.tideways_daemon.x86_64-linux"
      "pkgs.tideways_module.x86_64-linux"
      "pkgs.wkhtmltopdf.x86_64-linux"
      "pkgs.wkhtmltopdf_0_12_5.x86_64-linux"
      "pkgs.wkhtmltopdf_0_12_6.x86_64-linux"
      "pkgs.xtrabackup.x86_64-linux"
      "tests.antivirus"
      "tests.audit"
      "tests.backyserver_ceph-nautilus"
      "tests.backyserver_volumes"
      "tests.ceph-nautilus"
      "tests.channel"
      "tests.coturn"
      "tests.docker"
      "tests.fcagent.nonprod"
      "tests.fcagent.prod"
      "tests.ffmpeg"
      "tests.filebeat"
      "tests.frr.evpn"
      "tests.frr.regression-test"
      "tests.garbagecollect"
      "tests.haproxy"
      "tests.journal"
      "tests.kernelconfig"
      "tests.kibana6"
      "tests.kibana7"
      "tests.kvm_host_ceph-nautilus-nautilus"
      "tests.lamp"
      "tests.lamp56"
      "tests.lamp56_fpm"
      "tests.lamp72"
      "tests.lamp72_fpm"
      "tests.lamp73"
      "tests.lamp73_fpm"
      "tests.lamp73_tideways"
      "tests.lamp73_tideways_fpm"
      "tests.lamp74"
      "tests.lamp74_fpm"
      "tests.lamp74_tideways"
      "tests.lamp74_tideways_fpm"
      "tests.lamp80_fpm"
      "tests.lamp80_tideways_fpm"
      "tests.locale"
      "tests.logging"
      "tests.login"
      "tests.logrotate"
      "tests.mail"
      "tests.mailstub"
      "tests.matomo.matomo"
      "tests.matomo.matomo-beta"
      "tests.memcached"
      "tests.mongodb34"
      "tests.mongodb36"
      "tests.mongodb40"
      "tests.mongodb42"
      "tests.mysql57"
      "tests.network.firewall"
      "tests.network.loopback"
      "tests.network.name-resolution"
      "tests.network.ping-vlans"
      "tests.network.routes"
      "tests.network.wireguard"
      "tests.nfs"
      "tests.nginx"
      "tests.openvpn"
      "tests.percona80"
      "tests.physical-installer"
      "tests.postgresql10"
      "tests.postgresql11"
      "tests.postgresql12"
      "tests.postgresql13"
      "tests.postgresql96"
      "tests.prometheus"
      "tests.rabbitmq"
      "tests.redis"
      "tests.rg-relay"
      "tests.router.agentswitch"
      "tests.router.failover"
      "tests.router.interactive"
      "tests.router.maintenance"
      "tests.router.primary"
      "tests.router.secondary"
      "tests.router.whq_dev"
      "tests.sensu"
      "tests.servicecheck"
      "tests.statshost-global"
      "tests.statshost-master"
      "tests.sudo"
      "tests.systemd-service-cycles"
      "tests.users"
      "tests.vxlan"
      "tests.webproxy"
      "tests.wkhtmltopdf"
    ];
    preferLocalBuild = true;

    passthru.src = combinedSources;

    patchPhase = "touch .update-on-nixos-rebuild";

    XZ_OPT = "-1";
    tarOpts = ''
      --owner=0 --group=0 --mtime="1970-01-01 00:00:00 UTC" \
      --exclude-vcs-ignores \
      --transform='s!^\.!${name}!' \
    '';

    installPhase = ''
      mkdir -p $out/{tarballs,nix-support}
      cd nixos
      tar cJhf $out/tarballs/nixexprs.tar.xz ${tarOpts} .

      echo "channel - $out/tarballs/nixexprs.tar.xz" > "$out/nix-support/hydra-build-products"
      echo $constituents > "$out/nix-support/hydra-aggregate-constituents"

      # Propagate build failures.
      for i in $constituents; do
        if [ -e "$i/nix-support/failed" ]; then
          touch "$out/nix-support/failed"
        fi
      done
    '';
  };
}
