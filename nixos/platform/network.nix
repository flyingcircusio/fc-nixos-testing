{ config, lib, pkgs, utils, ... }:

with builtins;

let
  cfg = config.flyingcircus;

  fclib = config.fclib;

  # XXX there's a lot of conditionals here
  interfaces = filter
    (i: i.vlan != "ipmi" && i.vlan != "lo")
    (lib.attrValues fclib.network);

  managedInterfaces = filter
    (i: i.policy != "unmanaged" && i.policy != "null")
    interfaces;

  physicalInterfaces = filter
    (i: i.policy != "vxlan" && i.policy != "underlay")
    managedInterfaces;

  nonUnderlayInterfaces = filter
    (i: i.policy != "underlay")
    managedInterfaces;

  bridgedInterfaces = filter
    (i: i.bridged)
    managedInterfaces;

  vxlanInterfaces = filter
    (i: i.policy == "vxlan")
    managedInterfaces;

  ethernetInterfaces = physicalInterfaces ++
    # XXX handling this within fclib.network.ul would be great.
    (lib.optionals (!isNull fclib.underlay) fclib.underlay.links);

  virtualLinks = let
    allLinks = lib.unique
      (lib.foldl (acc: iface: acc ++ iface.linkStack) [] managedInterfaces);
    ethernetLinks = lib.unique
      (map (iface: iface.link) ethernetInterfaces);
  in
    lib.subtractLists ethernetLinks allLinks;

  location = lib.attrByPath [ "parameters" "location" ] "" cfg.enc;

  # generally use DHCP in the current location?
  allowDHCP = location:
    if hasAttr location cfg.static.allowDHCP
    then cfg.static.allowDHCP.${location}
    else false;

  # add srv addresses from my own resource group to /etc/hosts
  hostsFromEncAddresses = encAddresses:
    let
      recordToEtcHostsLine = r:
      let hostName =
        if config.networking.domain != null
        then "${r.name}.${config.networking.domain} ${r.name}"
        else "${r.name}";
      in
        "${fclib.stripNetmask r.ip} ${hostName}";
    in
      # always mention IPv6 addresses first to get predictable behaviour
      lib.concatMapStringsSep "\n" recordToEtcHostsLine
        ((filter (a: fclib.isIp6 a.ip) encAddresses) ++
         (filter (a: fclib.isIp4 a.ip) encAddresses));

  interfaceRules = lib.concatStrings (lib.unique
    # Due to the way we report interface config we may und up with repeated
    # rules for physical interfaces (e.g. with with two tagged interfaces
    # on the same underlying device).
    # XXX this doesn't sound right
    (map (iface: ''
      SUBSYSTEM=="net" , ATTR{address}=="${iface.mac}", NAME="${iface.link}"
    '') ethernetInterfaces));

   quoteLabel = replaceStrings ["/"] ["-"];

in
{

  options = {
    flyingcircus.networking.enableInterfaceDefaultRoutes = lib.mkOption {
      type = lib.types.bool;
      description = "Enable default routes for all networks with known default gateways.";
      default = true;
    };
  };

  config = rec {
    environment.etc."host.conf".text = ''
      order hosts, bind
      multi on
    '';

    environment.systemPackages = with pkgs; [
      ethtool
    ];

    networking = {

      # FQDN and host name should resolve to the SRV address
      # (set by hostsFromEncAddresses) and not 127.0.0.1.
      # Restores old behaviour that we know from 15.09.
      # -> #PL-129549
      hosts = lib.mkOverride 90 {};

      nameservers =
        if (hasAttr location cfg.static.nameservers)
        then cfg.static.nameservers.${location}
        else [];

      vlans = listToAttrs (map (interface:
        lib.nameValuePair interface.taggedLink {
          id = interface.vlanId;
          interface = interface.link;
        })
        (filter (interface: interface.policy == "tagged") interfaces));

      # data structure for all configured interfaces with their IP addresses:
      # { ethfe = { ... }; ethsrv = { }; ... }
      # or
      # { brfe = { ... }; brsrv = { }; ethsto = { }; ... }
      interfaces = listToAttrs ((map (interface:
        (lib.nameValuePair "${interface.interface}" {
          ipv4.addresses = interface.v4.attrs;
          ipv4.routes =
            let
              defaultRoutes = lib.optionals
                (config.flyingcircus.networking.enableInterfaceDefaultRoutes)
                (map (gateway:
                  {
                    address = "0.0.0.0";
                    prefixLength = 0;
                    via = gateway;
                    options = { metric = toString interface.priority; };
                  }) interface.v4.defaultGateways);

              # To select the correct interface, add routes for other subnets
              # in which this machine doesn't have its own address.
              # We did this with policy routing before. After deactivating it,
              # we had problems with srv traffic going out via fe because its default route
              # has higher priority.
              additionalRoutes = map
                (net: { address = net.network; inherit (net) prefixLength; })
                (filter (n: n.addresses == []) interface.v4.networkAttrs);
            in
              defaultRoutes ++ additionalRoutes;

          ipv6.addresses = interface.v6.attrs;

          # Using SLAAC/privacy addresses will cause firewalls to block
          # us internally and also have customers get problems with
          # outgoing connections.
          tempAddress = "disabled";

          ipv6.routes =
            let
              defaultRoutes = lib.optionals
                (config.flyingcircus.networking.enableInterfaceDefaultRoutes)
                (map (gateway:
                  { address = "::";
                    prefixLength = 0;
                    via = gateway;
                    options = { metric = toString interface.priority; };
                  }) interface.v6.defaultGateways);

              additionalRoutes = map
                (net: { address = net.network; inherit (net) prefixLength; })
                (filter (n: n.addresses == []) interface.v6.networkAttrs);
            in
              defaultRoutes ++ additionalRoutes;

          mtu = interface.mtu;
        })) nonUnderlayInterfaces) ++
      (lib.optionals (!isNull fclib.underlay) [(
        lib.nameValuePair fclib.underlay.interface {
          ipv4.addresses = [{
            address = fclib.underlay.loopback;
            prefixLength = 32;
          }];
          tempAddress = "disabled";
          mtu = fclib.network.ul.mtu;
        }
      )]) ++
      ((map (iface: lib.nameValuePair iface.link {
          tempAddress = "disabled";
          mtu = iface.mtu;
        })
        fclib.underlay.links or [])));

      bridges = listToAttrs (map (interface:
        (lib.nameValuePair
          "${interface.interface}"
          { interfaces = interface.attachedLinks; }))
        bridgedInterfaces);

      resolvconf.extraOptions = [ "ndots:1" "timeout:1" "attempts:6" ];

      search = lib.optionals
        (location != "" && config.networking.domain != null)
        [ "${location}.${config.networking.domain}"
          config.networking.domain
        ];

      # DHCP settings: never do IPv4ll and don't use DHCP by default.
      useDHCP = fclib.mkPlatform false;
      dhcpcd.extraConfig = ''
        # IPv4ll gets in the way if we really do not want
        # an IPv4 address on some interfaces.
        noipv4ll
      '';

      extraHosts = lib.optionalString
        (cfg.encAddresses != [])
        (hostsFromEncAddresses cfg.encAddresses);

      wireguard.enable = true;

      firewall.trustedInterfaces =
        lib.optionals (!isNull fclib.underlay && cfg.infrastructureModule == "flyingcircus-physical")
          ([ "brsto" "brstb" ] ++ (map (l: l.link) fclib.underlay.links or []));
    };

    flyingcircus.activationScripts = {

      prepare-wireguard-keys = ''
        set -e
        install -d -g root /var/lib/wireguard
        umask 077
        cd /var/lib/wireguard
        if [ ! -e "privatekey" ]; then
          ${pkgs.wireguard-tools}/bin/wg genkey > privatekey
        fi
        chmod u=rw,g-rwx,o-rwx privatekey
        if [ ! -e "publickey" ]; then
          ${pkgs.wireguard-tools}/bin/wg pubkey < privatekey > publickey
        fi
        chgrp service publickey
        chmod u=rw,g=r,o-rwx publickey
        ${pkgs.acl}/bin/setfacl -m g:sudo-srv:r publickey
      '';

    };

    flyingcircus.services.telegraf.inputs = lib.optionalAttrs (cfg.infrastructureModule == "flyingcircus-physical") {
      exec = [{
        commands = [ "${pkgs.fc.telegraf-routes-summary}/bin/telegraf-routes-summary" ];
        timeout = "10s";
        data_format = "json";
        json_name_key = "name";
        tag_keys = [ "family" "path" ];
      }];
    };

    services.udev.initrdRules = interfaceRules;
    services.udev.extraRules = interfaceRules;

    services.frr = lib.mkIf (!isNull fclib.underlay) {
      zebra = {
        enable = true;
        config = ''
          frr version 8.5.1
          frr defaults datacenter
          !
          route-map set-source-address permit 1
           set src ${fclib.underlay.loopback}
          exit
          !
          ip protocol bgp route-map set-source-address
        '';
      };
      bfd = {
        enable = true;
      };
      bgp = {
        enable = true;
        extraOptions = [ "-p" "0" ];
        config = ''
          frr version 8.5.1
          frr defaults datacenter
          !
          router bgp ${toString fclib.underlay.asNumber}
           bgp router-id ${fclib.underlay.loopback}
           bgp bestpath as-path multipath-relax
           neighbor switches peer-group
           neighbor switches remote-as external
           neighbor switches capability extended-nexthop
           neighbor switches bfd
           ${lib.concatMapStringsSep "\n "
             (iface: "neighbor ${iface.link} interface peer-group switches")
             fclib.underlay.links
           }
           !
           address-family ipv4 unicast
            redistribute connected
            neighbor switches prefix-list underlay-import in
            neighbor switches prefix-list underlay-export out
            neighbor switches route-map accept-all-routes in
            neighbor switches route-map accept-local-routes out
           exit-address-family
           !
           address-family l2vpn evpn
            neighbor switches activate
            neighbor switches route-map accept-all-routes in
            neighbor switches route-map accept-local-routes out
            advertise-all-vni
            advertise-svi-ip
            ${ # Workaround for FRR not advertising SVI IP when
               # globally configured
              lib.concatMapStringsSep "\n  "
                (iface: concatStringsSep "\n  " [
                  ("vni " + (toString iface.vlanId))
                  " advertise-svi-ip"
                  "exit-vni"
                ])
                vxlanInterfaces
            }
           exit-address-family
          !
          exit
          !
          bgp as-path access-list local-origin seq 1 permit ^$
          !
          route-map accept-local-routes permit 1
           match as-path local-origin
          exit
          !
          route-map accept-all-routes permit 1
          exit
          !
          ip prefix-list underlay-export seq 1 permit ${fclib.underlay.loopback}/32
          !
          ${lib.concatImapStringsSep "\n"
            (idx: net:
              "ip prefix-list underlay-import seq ${toString idx} permit ${net} le 32"
            )
            fclib.underlay.subnets
           }
          !
        '';
      };
    };

    # Don't automatically create a dummy0 interface when the kernel
    # module is loaded.
    boot.extraModprobeConfig = "options dummy numdummies=0";

    systemd.services =
      { nscd.restartTriggers = [
          config.environment.etc."host.conf".source
        ];
        systemd-sysctl.restartTriggers = lib.mkIf (!isNull fclib.underlay) [
          config.environment.etc."sysctl.d/70-fcio-underlay.conf".source
        ];
      } //
      # These units performing network interface setup must be
      # explicitly wanted by the multi-user target, otherwise they
      # will not get initially added as the individual address units
      # won't get restarted because triggering multi-user.target alone
      # does not propagate to the network target, etc etc.
      (listToAttrs
        ((map (iface:
          (lib.nameValuePair
            "network-link-properties-${iface.link}"
            rec {
              description = "Ensure link properties for ${iface.link}";
              wantedBy = [ "network-addresses-${iface.interface}.service"
                           "multi-user.target" ];
              after = [ "sys-subsystem-net-devices-${utils.escapeSystemdPath iface.link}.device" ];
              before = wantedBy;
              path = [ pkgs.nettools pkgs.ethtool pkgs.procps fclib.relaxedIp ];
              script = ''
                LINK_DRIVER=$(ethtool -i ${iface.link} | grep "driver: " | cut -d ':' -f 2 | sed -e 's/ //')
                case $LINK_DRIVER in
                    e1000|e1000e|igb|ixgbe|i40e)
                        # Set adaptive interrupt moderation. This does increase
                        # latency.
                        echo "Enabling adaptive interrupt moderation ..."
                        ethtool -C "${iface.link}" rx-usecs 1 || true
                        # Larger buffers.
                        echo "Setting ring buffer ..."
                        ethtool -G "${iface.link}" rx 4096 tx 4096 || true
                        # Large receive offload to reduce small packet CPU/interrupt impact.
                        echo "Enabling large receive offload ..."
                        ethtool -K "${iface.link}" lro on || true
                        ;;
                esac

                echo "Disabling flow control"
                ethtool -A ${iface.link} autoneg off rx off tx off || true

                # Ensure MTU
                ip l set ${iface.link} mtu ${toString iface.mtu}

                # Add long alternative names according to the external label
                ip l property add altname ${quoteLabel iface.externalLabel} dev ${iface.link}
              '';
              preStop = ''
                ip l property del altname ${quoteLabel iface.externalLabel} dev ${iface.link}
              '';
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            })) ethernetInterfaces) ++
        (let
          unitName = link: "network-disable-ipv6-autoconfig-${link}";
          unitTemplate = link: rec {
            description = "Disable IPv6 autoconfig for link ${link}";
            wantedBy = [ "network-addresses-${link}.service"
                         "multi-user.target" ];
            before = wantedBy;
            path = [ pkgs.procps fclib.relaxedIp ];
            stopIfChanged = false;
            script = ''
              # Disable IPv6 SLAAC (autoconf)
              sysctl net.ipv6.conf.${link}.accept_ra=0
              sysctl net.ipv6.conf.${link}.autoconf=0
              sysctl net.ipv6.conf.${link}.temp_valid_lft=0
              sysctl net.ipv6.conf.${link}.temp_prefered_lft=0
              for oldtmp in `ip -6 address show dev ${link} dynamic scope global | grep inet6 | cut -d ' ' -f6`; do
                ip addr del $oldtmp dev ${link}
              done
            '';
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
          };

          hardwareLinkUnit = link: ((unitTemplate link) // {
            after = [ "sys-subsystem-net-devices-${utils.escapeSystemdPath link}.device" ];
          });
          virtualLinkUnit = link: ((unitTemplate link) // {
            bindsTo = [ "${link}-netdev.service" ];
            after = [ "${link}-netdev.service" ];
          });
        in
          (map (iface:
            lib.nameValuePair (unitName iface.link) (hardwareLinkUnit iface.link))
            ethernetInterfaces) ++
          (map (link:
            lib.nameValuePair (unitName link) (virtualLinkUnit link))
            virtualLinks)
        ) ++
        (lib.optionals (!isNull fclib.underlay)
          # loopback dummy device
          (let linkName = fclib.underlay.interface; in [
            (lib.nameValuePair
            "${linkName}-netdev"
            rec {
              description = "Dummy interface ${linkName}";
              wantedBy = [ "network-setup.service" "multi-user.target" ];
              before = wantedBy;
              after = [ "network-pre.service" ];
              partOf = [ "network-setup.service" ];
              path = [ pkgs.nettools pkgs.procps fclib.relaxedIp ];
              reloadIfChanged = true;
              script = ''
                # Create virtual interface underlay
                ip link add ${linkName} type dummy

                ip link set ${linkName} mtu ${toString fclib.network.ul.mtu}
              '';
              reload = ''
                ip link set ${linkName} mtu ${toString fclib.network.ul.mtu}
              '';
              preStop = ''
                ip link delete ${linkName}
              '';
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            }
          ) (lib.nameValuePair
            "network-addresses-${linkName}"
            {
              unitConfig.After = lib.mkForce "network-pre.target ${linkName}-netdev.service";
              unitConfig.BindsTo = lib.mkForce "${linkName}-netdev.service";
            }
          )] ++
          # vxlan kernel devices
          (map (iface: (lib.nameValuePair
            "${iface.link}-netdev"
            rec {
              description = "VXLAN link device ${iface.link}";
              wantedBy = [ "network-setup.service" "multi-user.target" ];
              before = wantedBy;
              requires = [ "network-addresses-${fclib.underlay.interface}.service" ];
              after = requires ++ [ "network-pre.target" ];
              partOf = requires ++ [ "network-setup.service" ];
              reloadIfChanged = true;
              path = [ pkgs.nettools pkgs.procps fclib.relaxedIp ];
              script = ''
                # Create virtual link ${iface.link}
                ip link add ${iface.link} type vxlan \
                  id ${toString iface.vlanId} \
                  local ${fclib.underlay.loopback} \
                  dstport 4789 \
                  nolearning

                # Set MTU and layer 2 address
                ip link set ${iface.link} address ${iface.mac}
                ip link set ${iface.link} mtu ${toString iface.mtu}

                # Do not automatically generate IPv6 link-local address
                ip link set ${iface.link} addrgenmode none
              '';
              reload = ''
                # Set underlay address for virtual interface ${iface.link}.
                # Note that changing the VNI or destination port after the interface
                # has been created is not supported.
                ip link set ${iface.link} type vxlan local ${fclib.underlay.loopback}

                # Set MTU and layer 2 address
                ip link set ${iface.link} address ${iface.mac}
                ip link set ${iface.link} mtu ${toString iface.mtu}

                # Do not automatically generate IPv6 link-local address
                ip link set ${iface.link} addrgenmode none
              '';
              preStop = ''
                ip link delete ${iface.link}
              '';
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            })) vxlanInterfaces) ++
          # NixOS scripted networking configuration does not know
          # about VXLAN devices, and (incorrectly) generates
          # dependencies for them as if they were physical ethernet
          # devices. We need to patch some dependencies in other units
          # so that the link configuration and bridge device creation
          # depend on the correct units.
          (map (iface: (lib.nameValuePair
            "network-addresses-${iface.link}"
            {
              unitConfig.After = lib.mkForce "network-pre.target ${iface.link}-netdev.service";
              unitConfig.BindsTo = lib.mkForce "${iface.link}-netdev.service";
            }
          )) vxlanInterfaces) ++
          (map (iface: (lib.nameValuePair
            "${iface.interface}-netdev"
            {
              unitConfig.After = lib.mkForce "network-pre.target ${iface.link}-netdev.service network-addresses-${iface.link}.service";
              unitConfig.BindsTo = lib.mkForce "${iface.link}-netdev.service";
            }
          )) vxlanInterfaces) ++
          # bridge port configuration for vxlan devices
          # XXX we always make VXLAN ports bridge ports ... this complicates the
          # code a bit.
          (map (iface: (lib.nameValuePair
            "network-bridge-port-properties-${iface.link}"
            {
              description = "Ensure bridge port properties for ${iface.link}";
              wantedBy = [ "multi-user.target" ];
              partOf = [ "${iface.interface}-netdev.service" ];
              after = [ "${iface.interface}-netdev.service" ];
              stopIfChanged = false;
              path = [ fclib.relaxedIp ];
              script = ''
                ip link set ${iface.link} type bridge_slave neigh_suppress on learning off
              '';
              reload = ''
                ip link set ${iface.link} type bridge_slave neigh_suppress on learning off
              '';
              unitConfig.ReloadPropagatedFrom = [ "${iface.interface}-netdev.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            }
          )) vxlanInterfaces) ++
          # underlay network physical interfaces
          (map (iface: (lib.nameValuePair
            "network-underlay-properties-${iface.link}"
            {
              description = "Ensure underlay properties for ${iface.link}";
              wantedBy = [ "network-addresses-${iface.link}.service"
                           "multi-user.target" ];
              after = [ "network-link-properties-${iface.link}.service" ];
              path = [ pkgs.procps ];
              script = ''
                sysctl net.ipv4.conf.${iface.link}.rp_filter=0
              '';
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
            }
          )) fclib.underlay.links) ++ [
            # fallback unreachable routes
            (lib.nameValuePair
              "network-underlay-routing-fallback"
              rec {
                description = "Ensure fallback unreachable route for underlay prefixes";
                wantedBy = [ "network-addresses-${fclib.underlay.interface}.service"
                             "multi-user.target" ];
                before = wantedBy;
                after = [ "${fclib.underlay.interface}-netdev.service" ];
                path = [ fclib.relaxedIp ];
                stopIfChanged = false;
                # https://docs.frrouting.org/en/stable-8.5/zebra.html#administrative-distance
                #
                # Due to how zebra calculates administrative distance
                # for routes learned from the kernel, we need to set a
                # very high metric on these routes (i.e. very low
                # preference) so that routes learned from BGP can
                # override these statically configured routes.
                script = ''
                  ${lib.concatMapStringsSep "\n"
                    (net: "ip route add unreachable " + net + " metric 335544321")
                    fclib.underlay.subnets
                   }
                '';
                preStop = ''
                  ${lib.concatMapStringsSep "\n"
                    (net: "ip route del unreachable " + net + " metric 335544321")
                    fclib.underlay.subnets
                   }
                '';
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
              }
            )
            # interface altnames from lldp
            (lib.nameValuePair
              "fc-lldp-to-altnames"
              rec {
                description = "Set interface altnames based on peer hostname advertised in LLDP";
                after = [ "lldpd.service" ];
                unitConfig.Requisite = after;
                serviceConfig.Type = "oneshot";
                script = let
                  links = lib.concatStringsSep " " (map (i: i.link) ethernetInterfaces);
                in
                  "${pkgs.fc.lldp-to-altname}/bin/fc-lldp-to-altname -q ${links}";
              }
            )
            # ensure that restarts of ul-loopback are propagated to zebra
            (lib.nameValuePair
              "zebra"
              rec {
                requires = [ "network-addresses-${fclib.underlay.interface}.service" ];
                after = requires;
                partOf = requires;
              }
            )
          ])
        )));

    flyingcircus.services.sensu-client.checks = lib.optionalAttrs (!isNull fclib.underlay) {
      uplink_redundancy = {
        notification = "Host has redundant switch connectivity";
        interval = 600;
        command = let
          links = lib.concatStringsSep " " (map (i: i.link) fclib.underlay.links);
        in
          "${pkgs.fc.check-link-redundancy}/bin/check_link_redundancy ${links}";
      };
    };

    systemd.timers.fc-lldp-to-altnames = lib.mkIf (!isNull fclib.underlay) {
      description = "Timer for updating interface altnames based on peer hostname advertised in LLDP";
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*:0/10";
    };

    boot.kernel.sysctl = lib.mkMerge [{
      "net.ipv4.tcp_congestion_control" = "bbr";
      # Ensure that we can do early binds before addresses are configured.
      "net.ipv4.ip_nonlocal_bind" = "1";
      "net.ipv6.ip_nonlocal_bind" = "1";

      # Ensure dual stack support for binding to [::] for services that
      # only accept a single bind address.
      "net.ipv6.bindv6only" = "0";

      # Ensure that we can use IPv6 as early as possible.
      # This fixes startup race conditions like
      # https://yt.flyingcircus.io/issue/PL-130190
      "net.ipv6.conf.all.optimistic_dad" = 1;
      "net.ipv6.conf.all.use_optimistic" = 1;

      # Ensure we reserve ports as promised to our customers.
      "net.ipv4.ip_local_port_range" = "32768 60999";
      "net.ipv4.ip_local_reserved_ports" = "61000-61999";
      # Linux currently has 4096 as default and that includes
      # neighbour discovery. Seen on #denog on 2020-11-19
      "net.ipv6.route.max_size" = 2147483647;

      # Ensure we can work in larger VLANs with hundreds of nodes.
      "net.ipv4.neigh.default.gc_thresh1" = 1024;
      "net.ipv4.neigh.default.gc_thresh2" = 4096;
      "net.ipv4.neigh.default.gc_thresh3" = 8192;
      "net.ipv6.neigh.default.gc_thresh1" = 1024;
      "net.ipv6.neigh.default.gc_thresh2" = 4096;
      "net.ipv6.neigh.default.gc_thresh3" = 8192;

      # See PL-130189
      # conntrack entries are created (for v4/v6) if any rules
      # for related/established and/or NATing are used in the
      # PREROUTING hook
      # suppressing/disabling conntrack on individual machines will
      # likely lead to a confusing platform behaviour as we will need
      # connection tracking more and more on VPN servers, container hosts, etc.
      # we already dealt with this in Ceph and have established 250k tracked connections
      # as a reasonable size and I'd suggest generalizing this number to all machines.
      "net.netfilter.nf_conntrack_max" = 262144;
    }
    (lib.mkIf (cfg.infrastructureModule != "flyingcircus-physical") {
      "net.core.rmem_max" = 8388608;
    })
    (lib.mkIf (cfg.infrastructureModule == "flyingcircus-physical") {
      "vm.min_free_kbytes" = "513690";

      "net.core.netdev_max_backlog" = "300000";
      "net.core.optmem" = "40960";
      "net.core.wmem_default" = "16777216";
      "net.core.wmem_max" = "16777216";
      "net.core.rmem_default" = "8388608";
      "net.core.rmem_max" = "16777216";
      "net.core.somaxconn" = "1024";

      "net.ipv4.tcp_fin_timeout" = "10";
      "net.ipv4.tcp_max_syn_backlog" = "30000";
      "net.ipv4.tcp_slow_start_after_idle" = "0";
      "net.ipv4.tcp_syncookies" = "0";
      "net.ipv4.tcp_timestamps" = "0";
                                  # 1MiB   8MiB    # 16 MiB
      "net.ipv4.tcp_mem" = "1048576 8388608 16777216";
      "net.ipv4.tcp_wmem" = "1048576 8388608 16777216";
      "net.ipv4.tcp_rmem" = "1048576 8388608 16777216";

      "net.ipv4.tcp_tw_recycle" = "1";
      "net.ipv4.tcp_tw_reuse" = "1";

      # Supposedly this doesn't do much good anymore, but in one of my tests
      # (too many, can't prove right now.) this appeared to have been helpful.
      "net.ipv4.tcp_low_latency" = "1";

      # Optimize multi-path for VXLAN (layer3 in layer3)
      "net.ipv4.fib_multipath_hash_policy" = "2";
    })];

    # Prevent underlay interfaces from matching the rp_filter sysctl
    # glob in the default configuration shipped with systemd.
    environment.etc."sysctl.d/70-fcio-underlay.conf" =
      lib.mkIf (!isNull fclib.underlay) {
        text = lib.concatMapStringsSep "\n"
          (iface: "-net.ipv4.conf.${iface.link}.rp_filter")
          fclib.underlay.links;
      };

  };
}
