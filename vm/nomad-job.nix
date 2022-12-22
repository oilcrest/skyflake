{ user
, repo
, vmName
, datacenters
, pkgs
, config
, runner
}:

let
  inherit (pkgs) lib;

  workDir = "/run/microvms/${user}/${repo}/${vmName}";

  constraints = [ {
    attribute = "\${attr.kernel.name}";
    operator = "=";
    value = pkgs.lib.toLower config.nixpkgs.localSystem.uname.system;
  } {
    attribute = "\${attr.kernel.arch}";
    operator = "=";
    value = config.nixpkgs.localSystem.uname.processor;
  } {
    attribute = "\${attr.cpu.numcores}";
    operator = ">=";
    value = config.microvm.vcpu;
  } ] ++ config.skyflake.nomadJob.constraints;

  jobFile = pkgs.writeText "${user}-${repo}-${vmName}.job" ''
    job "${vmName}" {
      namespace = "${user}-${repo}"
      datacenters = [${lib.concatMapStringsSep ", " (datacenter:
        "\"${datacenter}\""
      ) datacenters}]
      type = "service"

      group "nixos-${config.system.nixos.label}" {
        count = 1

        restart {
          attempts = 3
          delay = "3s"
          mode = "fail"
          interval = "60s"
        }
        reschedule {
          unlimited = true
          delay = "90s"
        }

        ${lib.concatMapStrings ({ attribute, operator, value }: ''
          constraint {
            attribute = "${attribute}"
            operator = "${operator}"
            value = "${toString value}"
          }
        '') constraints}
        ${lib.concatMapStrings ({ attribute, operator, value, weight }: ''
          affinity {
            attribute = "${attribute}"
            operator = "${operator}"
            value = "${toString value}"
            weight = ${toString weight}
          }
        '') config.skyflake.nomadJob.affinities}

        ${lib.concatMapStrings (interface@{ id, ... }: ''
          task "add-interface-${id}" {
            lifecycle {
              hook = "prestart"
            }
            driver = "raw_exec"
            user = "root"
            config {
              command = "local/add-interface-${id}.sh"
            }
            template {
              destination = "local/add-interface-${id}.sh"
              perms = "755"
              data = <<EOD
${''
  #! /run/current-system/sw/bin/bash -e

  IFACE="${id}"

  if [ -d /sys/class/net/"$IFACE" ]; then
    echo "WARNING: Removing stale tap interface "$IFACE"" >&2
    ip tuntap del "$IFACE" mode tap || true
  fi
  ip tuntap add "$IFACE" mode tap user microvm
  ${config.skyflake.deploy.startTapScript}
  ip link set "$IFACE" up
''}EOD
            }
          }

          task "delete-interface-${id}" {
            lifecycle {
              hook = "poststop"
            }
            driver = "raw_exec"
            user = "root"
            config {
              command = "local/delete-interface-${id}.sh"
            }
            template {
              destination = "local/delete-interface-${id}.sh"
              perms = "755"
              data = <<EOD
${''
  #! /run/current-system/sw/bin/bash

  IFACE="${id}"

  ${config.skyflake.deploy.stopTapScript}
  ip link set "$IFACE" down
  ip tuntap del "$IFACE" mode tap
''}EOD
            }
          }
        '') config.microvm.interfaces}

        ${lib.concatMapStrings (share@{ tag, source, socket, proto, ... }:
          lib.optionalString (proto == "virtiofs") ''
            task "virtiofsd-${tag}" {
              lifecycle {
                hook = "prestart"
                sidecar = true
              }
              driver = "raw_exec"
              user = "root"
              config {
                command = "local/virtiofsd-${tag}.sh"
              }
              template {
                destination = "local/virtiofsd-${tag}.sh"
                perms = "755"
                data = <<EOD
${''
  #! /run/current-system/sw/bin/bash -e

  mkdir -p ${workDir}
  chown microvm:kvm ${workDir}
  cd ${workDir}

  mkdir -p ${source}
  exec /run/current-system/sw/bin/virtiofsd \
    --socket-path=${socket} \
    --socket-group=kvm \
    --shared-dir=${source} \
    --sandbox=none --no-killpriv-v2 \
    --xattr --posix-acl \
    --inode-file-handles=prefer \
    --cache=never
''}EOD
              }
              kill_timeout = "5s"

              resources {
                memory = ${toString (config.microvm.vcpu * 10)}
                cpu = ${toString (config.microvm.vcpu * 10)}
              }
            }
          '') config.microvm.shares}

        task "copy-system" {
          driver = "raw_exec"
          lifecycle {
            hook = "prestart"
          }
          config {
            command = "local/copy-system.sh"
          }
          template {
            destination = "local/copy-system.sh"
            perms = "755"
            data = <<EOD
${''
  #! /run/current-system/sw/bin/bash -e

  if ! [ -e ${runner} ] ; then
    /run/current-system/sw/bin/nix copy --from file://@sharedStorePath@?trusted=1 --no-check-sigs ${runner}
  fi
''}EOD
          }
        }

        task "volume-dirs" {
          driver = "raw_exec"
          lifecycle {
            hook = "prestart"
          }
          config {
            command = "local/make-dirs.sh"
          }
          template {
            destination = "local/make-dirs.sh"
            perms = "755"
            data = <<EOD
${''
  #! /run/current-system/sw/bin/bash -e

  ${lib.concatMapStrings ({ image, ... }: ''
    mkdir -p "${dirOf image}"
    chown microvm:kvm "${dirOf image}"
  '') config.microvm.volumes}
''}EOD
          }
        }

        task "hypervisor" {
          driver = "raw_exec"
          user = "microvm"
          config {
            command = "local/hypervisor.sh"
          }
          template {
            destination = "local/hypervisor.sh"
            perms = "755"
            data = <<EOD
${''
  #! /run/current-system/sw/bin/bash -e

  mkdir -p ${workDir}
  cd ${workDir}

  # start hypervisor
  ${runner}/bin/microvm-run &

  # stop hypervisor on signal
  function handle_signal() {
    echo "Received signal, shutting down" >&2
    date >&2
    ${runner}/bin/microvm-shutdown
    echo "Done" >&2
    date >&2
    exit
  }
  trap handle_signal CONT
  wait
''}EOD
          }

          leader = true
          # don't get killed immediately but get shutdown by wait-shutdown
          kill_signal = "SIGCONT"
          # systemd timeout is at 90s by default
          kill_timeout = "95s"

          resources {
            memory = ${toString (config.microvm.mem + 8)}
            cpu = ${toString (config.microvm.vcpu * 50)}
          }
        }
      }
    }
  '';

in
pkgs.stdenv.mkDerivation rec {
  pname = "${user}-${repo}-${vmName}";
  inherit (config.system.nixos) version;

  src = jobFile;
  NAME = "${pname}.job";

  phases = [ "buildPhase" "checkPhase" "installPhase" ];

  buildInputs = lib.optionals (pkgs ? hclfmt) [ pkgs.hclfmt ];
  buildPhase =
    if pkgs ? hclfmt
    then ''
      hclfmt < $src > $NAME
    '' else ''
      cp $src $NAME
    '';

  checkInputs = with pkgs; [ nomad ];
  checkPhase = ''
    nomad job validate $NAME
  '';

  installPhase = ''
    cp $NAME $out
  '';
}
