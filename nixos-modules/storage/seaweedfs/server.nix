{ lib, config, ... }:
{
  options.skyflake.storage.seaweedfs = {
    master = {
      serverIP = lib.mkOption {
        type = lib.str;
        description = ''
          IP of this node.
        '';
      };
      listenIPs = lib.mkOption {
        type = lib.listOf lib.str;
        description = ''
          IP of all the master servers.
          Can be the same as storage nodes.
        '';
      };
    };
    volumeStorage = {
      encrypt = {
        type = lib.types.bool;
        default = false;
        description = ''
          enable encryption on volume store.
        '';
        };
      datacenter = {
        type = lib.str;
        description = ''
          The datacenter location of the node.
        '';
      };
      rack = {
        type = lib.str;
        description = ''
          The rack location of the node.
        '';
      };
      listenIPs = lib.mkOption {
        type = lib.listOf lib.str;
        description = ''
          URLs of all the nodes that should store the actual data but not metadata.
          Can be the same as DB nodes.
        '';
      };
    };
    filer.db = {
      etcd = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Use to enable Kubernetes etcd database as a backend for seaweedfs.
          '';
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "${config.networking.hostName}";
        };
        listenPeerUrls = lib.mkOption {
          type = lib.listOf lib.str;
          description = ''
            URLs or IPs of all the nodes that should have the DB.
            Can be the same as storage nodes.
          '';
        };
      };
    };
  };
}