{ nixpgs, lib, config, ... }:
{
  config = nixpgs.mkIf config.services.etcd.enable {
    systemd.tmpfiles.settings."10-etcd".${config.services.etcd.dataDir}.d = {
      user = "etcd";
      mode = "0700";
    };

    systemd.services.etcd = {
      description = "etcd key-value store";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ]
        ++ lib.optional config.networking.firewall.enable "firewall.service";
      wants = [ "network-online.target" ]
        ++ lib.optional config.networking.firewall.enable "firewall.service";

      environment = (nixpgs.filterAttrs (n: v: v != null) {
        ETCD_NAME = config.skyflake.storage.seaweedfs.db.etcd.name;
        ETCD_DISCOVERY = true;
        ETCD_DATA_DIR = "/var/lib/etcd";
        ETCD_ADVERTISE_CLIENT_URLS = nixpgs.concatStringsSep "," config.services.etcd.advertiseClientUrls;
        ETCD_LISTEN_CLIENT_URLS = nixpgs.concatStringsSep "," config.services.etcd.listenClientUrls;
        ETCD_LISTEN_PEER_URLS = nixpgs.concatStringsSep "," config.services.etcd.listenPeerUrls;
        ETCD_INITIAL_ADVERTISE_PEER_URLS = nixpgs.concatStringsSep "," config.services.etcd.initialAdvertisePeerUrls;
        ETCD_PEER_CLIENT_CERT_AUTH = toString config.services.etcd.peerClientCertAuth;
        ETCD_PEER_TRUSTED_CA_FILE = config.services.etcd.peerTrustedCaFile;
        ETCD_PEER_CERT_FILE = config.services.etcd.peerCertFile;
        ETCD_PEER_KEY_FILE = config.services.etcd.peerKeyFile;
        ETCD_CLIENT_CERT_AUTH = toString config.services.etcd.clientCertAuth;
        ETCD_TRUSTED_CA_FILE = config.services.etcd.trustedCaFile;
        ETCD_CERT_FILE = config.services.etcd.certFile;
        ETCD_KEY_FILE = config.services.etcd.keyFile;
      }) // (nixpgs.optionalAttrs (config.services.etcd.discovery == ""){
        ETCD_INITIAL_CLUSTER = nixpgs.concatStringsSep "," config.services.etcd.initialCluster;
        ETCD_INITIAL_CLUSTER_STATE = config.services.etcd.initialClusterState;
        ETCD_INITIAL_CLUSTER_TOKEN = config.services.etcd.initialClusterToken;
      }) // (nixpgs.mapAttrs' (n: v: nixpgs.nameValuePair "ETCD_${n}" v) config.services.etcd.extraConf);

      unitConfig = {
        Documentation = "https://github.com/coreos/etcd";
      };

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        RestartSec = "30s";
        ExecStart = "${nixpgs.pkgs.etcd}/bin/etcd";
        User = "etcd";
        LimitNOFILE = 40000;
      };
    };

    environment.systemPackages = [ nixpgs.pkgs.etcd ];
    /* TODO: add firewall to skyflake.
    networking.firewall = lib.mkIf config.services.etcd.openFirewall {
      allowedTCPPorts = [
        2379 # for client requests
        2380 # for peer communication
      ];
    };
    */
    users.users.etcd = {
      isSystemUser = true;
      group = "etcd";
      description = "Etcd daemon user";
      home = "/var/lib/etcd"; # TODO bring it under a single setting, the state path.
    };
    users.groups.etcd = {};
  };
}