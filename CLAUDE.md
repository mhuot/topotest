# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Topotest is a Containerlab-based network topology for testing [walktopo](https://github.com/mhuot/walktopo) SNMP discovery capabilities. It defines a 5-node lab in a redundant hub-and-spoke topology, available in three flavors: Arista cEOS, SONiC-VS, and a minimal Alpine Linux variant. This is a **configuration-only infrastructure project** — there is no application code, build system, or test suite.

## Key Commands

The `lab.sh` helper auto-detects the platform and wraps all containerlab commands:

```bash
./lab.sh deploy              # Deploy the cEOS lab
./lab.sh --sonic deploy      # Deploy the SONiC-VS lab
./lab.sh --minimal deploy    # Deploy the minimal Alpine lab
./lab.sh inspect             # Check status
./lab.sh destroy             # Destroy the lab
./lab.sh save                # Save running configs
./lab.sh ssh hub1            # SSH to a node
./lab.sh exec hub1           # Open Cli on a node (vtysh for SONiC)
./lab.sh import <file>       # Import a cEOS image
./lab.sh info                # Show platform, image, and settings
```

### Manual Commands (Linux)

On Linux, containerlab runs natively:

```bash
sudo containerlab deploy -t topology.clab.yml
sudo containerlab inspect -t topology.clab.yml
sudo containerlab destroy -t topology.clab.yml
sudo containerlab save -t topology.clab.yml
ssh admin@clab-topotest-hub1
docker exec -it clab-topotest-hub1 Cli
```

### Manual Commands (macOS via OrbStack)

On macOS, all commands run inside the OrbStack VM named `clab`:

```bash
orb exec -m clab sudo containerlab deploy -t /path/to/topology.clab.yml
orb exec -m clab sudo containerlab inspect -t /path/to/topology.clab.yml
orb exec -m clab sudo containerlab destroy -t /path/to/topology.clab.yml
orb exec -m clab sudo containerlab save -t /path/to/topology.clab.yml
orb exec -m clab ssh admin@clab-topotest-hub1
orb exec -m clab docker exec -it clab-topotest-hub1 Cli
```

## Architecture

- **topology.clab.yml** — Full Containerlab topology. Declares 5 cEOS nodes and 8 inter-device links. Uses `${CEOS_IMAGE:-ceos64:4.35.1F}` for the node image — defaults to x86_64 on Linux, overridden to `ceosarm:4.35.1F` on ARM64 (set by `lab.sh` or manually).
- **topology-sonic.clab.yml** — SONiC-VS topology. Same 5-node, 8-link layout using `sonic-vs` kind. Uses `${SONIC_IMAGE:-docker-sonic-vs:latest}` for the node image. Each node gets a `config_db.json` startup config with interface IPs, SNMP community `public`, and LLDP enabled. Deploy with `./lab.sh --sonic deploy`.
- **topology-minimal.clab.yml** — Lightweight topology using Alpine Linux. 3 nodes with lldpd + net-snmp installed via exec commands. No cEOS image required. Deploy directly with `sudo containerlab deploy -t topology-minimal.clab.yml`.
- **lab.sh** — Cross-platform helper script. Detects macOS/Linux and arm64/x86_64, sets `CEOS_IMAGE`, wraps containerlab with OrbStack on macOS. Supports `--sonic` and `--minimal` flags.
- **configs/** — Arista EOS startup configurations, one per node. Each config sets up hostname, SNMP (community `public`, v2c), LLDP, management IP, and inter-device link IPs.
- **configs/sonic/** — SONiC `config_db.json` startup configurations, one per node. Each defines device metadata (Force10-S6000 hwsku), port definitions, interface IPs, loopback, SNMP community, and enabled features (LLDP, SNMP, BGP, etc.).

### Network Layout

5 nodes: hub1, hub2, sub1, site1, site2. Connected in a redundant mesh with 8 links using /30 subnets (10.0.x.0/30). Management IPs are 192.168.1.101-105. Container IPs are in the 172.20.20.0/24 range.

### Platform Support

| Platform | Image | Execution | Container IPs accessible from |
|----------|-------|-----------|-------------------------------|
| macOS ARM64 | `ceosarm:4.35.1F` | Via OrbStack VM `clab` | Inside VM only |
| Linux x86_64 | `ceos64:4.35.1F` | Native | Host directly |

## Important Conventions

- On macOS, container network IPs (172.20.20.x) are only accessible from inside the `clab` VM. On Linux, they're reachable from the host.
- To reach host services: use `host.orb.internal` on macOS, `localhost` on Linux.
- cEOS images must be imported with `docker import` (not `docker load`).
- SONiC-VS images are loaded with `docker load < docker-sonic-vs.gz` (downloaded from the Azure pipeline).
- Never commit image tarballs (they're in .gitignore).
- Node configs follow a consistent pattern: SNMP + LLDP + Management/Loopback + numbered Ethernet interfaces with /30 subnets.
- SONiC-VS interface mapping (Force10-S6000 hwsku): eth1→Ethernet0, eth2→Ethernet4, eth3→Ethernet8, eth4→Ethernet12 (4 lanes per port).
- SONiC nodes use `vtysh` for FRR CLI and `bash` for shell access. SNMP and LLDP run as containers within SONiC and start automatically.
