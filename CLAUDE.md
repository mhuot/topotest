# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Topotest is a Containerlab-based network topology for testing [walktopo](https://github.com/mhuot/walktopo) SNMP discovery capabilities. It defines a 5-node Arista cEOS lab in a redundant hub-and-spoke topology. This is a **configuration-only infrastructure project** — there is no application code, build system, or test suite.

## Key Commands

The `lab.sh` helper auto-detects the platform and wraps all containerlab commands:

```bash
./lab.sh deploy          # Deploy the lab
./lab.sh inspect         # Check status
./lab.sh destroy         # Destroy the lab
./lab.sh save            # Save running configs
./lab.sh ssh hub1        # SSH to a node
./lab.sh exec hub1       # Open Cli on a node
./lab.sh import <file>   # Import a cEOS image
./lab.sh info            # Show platform, image, and settings
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
- **topology-minimal.clab.yml** — Lightweight topology using Alpine Linux. 3 nodes with lldpd + net-snmp installed via exec commands. No cEOS image required. Deploy directly with `sudo containerlab deploy -t topology-minimal.clab.yml`.
- **topology-lldp.clab.yml** — LLDP discovery demo topology using Alpine Linux. 5 nodes in a 3-tier architecture (core / distribution / edge) with 7 links and redundant paths. Designed to demonstrate walktopo/lldp-me multi-hop LLDP discovery. No cEOS image required. Deploy with `./lab.sh --lldp deploy` or `sudo containerlab deploy -t topology-lldp.clab.yml`.
- **lab.sh** — Cross-platform helper script. Detects macOS/Linux and arm64/x86_64, sets `CEOS_IMAGE`, wraps containerlab with OrbStack on macOS. Supports `--minimal` and `--lldp` flags for topology selection.
- **configs/** — Arista EOS startup configurations, one per node. Each config sets up hostname, SNMP (community `public`, v2c), LLDP, management IP, and inter-device link IPs.

### Network Layouts

**Full topology (cEOS):** 5 nodes: hub1, hub2, sub1, site1, site2. Connected in a redundant mesh with 8 links using /30 subnets (10.0.x.0/30). Management IPs are 192.168.1.101-105. Container IPs are in the 172.20.20.0/24 range.

**LLDP topology (Alpine):** 5 nodes in 3 tiers: core → dist1/dist2 → edge1/edge2. 7 links with dual-homed edge switches for redundancy. Each node runs lldpd (with AgentX) and net-snmp, with custom system descriptions and port descriptions for rich LLDP data. Ideal for demonstrating SNMP-based LLDP neighbor walks.

### Platform Support

| Platform | Image | Execution | Container IPs accessible from |
|----------|-------|-----------|-------------------------------|
| macOS ARM64 | `ceosarm:4.35.1F` | Via OrbStack VM `clab` | Inside VM only |
| Linux x86_64 | `ceos64:4.35.1F` | Native | Host directly |

## Important Conventions

- On macOS, container network IPs (172.20.20.x) are only accessible from inside the `clab` VM. On Linux, they're reachable from the host.
- To reach host services: use `host.orb.internal` on macOS, `localhost` on Linux.
- cEOS images must be imported with `docker import` (not `docker load`).
- Never commit the cEOS image tarball (it's in .gitignore).
- Node configs follow a consistent pattern: SNMP + LLDP + Management0 + numbered Ethernet interfaces with /30 subnets.
