#!/usr/bin/env bash
set -euo pipefail

# lab.sh — Cross-platform helper for topotest containerlab topology
# Supports macOS/ARM64 (via OrbStack) and native Linux/x86_64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="$SCRIPT_DIR/topology.clab.yml"
TOPO_MINIMAL="$SCRIPT_DIR/topology-minimal.clab.yml"
USE_MINIMAL=false
LAB_NAME="topotest"

# --- Platform detection ---

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            PLATFORM="linux"
            ;;
        *)
            echo "Error: Unsupported OS: $os" >&2
            exit 1
            ;;
    esac

    case "$arch" in
        arm64|aarch64)
            ARCH="arm64"
            CEOS_IMAGE="${CEOS_IMAGE:-ceosarm:4.35.1F}"
            ;;
        x86_64|amd64)
            ARCH="amd64"
            CEOS_IMAGE="${CEOS_IMAGE:-ceos64:4.35.1F}"
            ;;
        *)
            echo "Error: Unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac

    export CEOS_IMAGE
}

# --- Command execution ---

# Run a command, wrapping with OrbStack on macOS
run_cmd() {
    if [ "$PLATFORM" = "macos" ]; then
        orb exec -m clab "$@"
    else
        "$@"
    fi
}

# Run a containerlab command with sudo, passing CEOS_IMAGE through
run_clab() {
    if [ "$PLATFORM" = "macos" ]; then
        orb exec -m clab sudo CEOS_IMAGE="$CEOS_IMAGE" containerlab "$@"
    else
        sudo CEOS_IMAGE="$CEOS_IMAGE" containerlab "$@"
    fi
}

# Resolve topology file path (macOS needs absolute path visible in VM)
topo_path() {
    local topo
    if [ "$USE_MINIMAL" = true ]; then
        topo="$TOPO_MINIMAL"
    else
        topo="$TOPO_FILE"
    fi
    echo "$topo"
}

# Set lab name based on topology
set_lab_name() {
    if [ "$USE_MINIMAL" = true ]; then
        LAB_NAME="topotest-minimal"
    else
        LAB_NAME="topotest"
    fi
}

# --- Commands ---

cmd_deploy() {
    if [ "$USE_MINIMAL" = true ]; then
        echo "Deploying minimal lab (Alpine Linux)..."
    else
        echo "Deploying lab (image: $CEOS_IMAGE)..."
    fi
    run_clab deploy -t "$(topo_path)" "$@"
}

cmd_destroy() {
    echo "Destroying lab..."
    run_clab destroy -t "$(topo_path)" "$@"
}

cmd_inspect() {
    run_clab inspect -t "$(topo_path)" "$@"
}

cmd_save() {
    echo "Saving running configs..."
    run_clab save -t "$(topo_path)" "$@"
}

cmd_graph() {
    run_clab graph -t "$(topo_path)" "$@"
}

cmd_ssh() {
    if [ $# -lt 1 ]; then
        echo "Usage: $0 ssh <node-name>" >&2
        echo "Example: $0 ssh hub1" >&2
        exit 1
    fi
    local node="$1"; shift
    run_cmd ssh "admin@clab-${LAB_NAME}-${node}" "$@"
}

cmd_exec() {
    if [ $# -lt 1 ]; then
        echo "Usage: $0 exec <node-name> [command...]" >&2
        echo "Example: $0 exec hub1 Cli" >&2
        exit 1
    fi
    local node="$1"; shift
    if [ $# -eq 0 ]; then
        if [ "$USE_MINIMAL" = true ]; then
            run_cmd docker exec -it "clab-${LAB_NAME}-${node}" sh
        else
            run_cmd docker exec -it "clab-${LAB_NAME}-${node}" Cli
        fi
    else
        run_cmd docker exec -it "clab-${LAB_NAME}-${node}" "$@"
    fi
}

cmd_import() {
    if [ $# -lt 1 ]; then
        echo "Usage: $0 import <ceos-image-tarball>" >&2
        echo "Example: $0 import cEOS64-lab-4.35.1F.tar" >&2
        exit 1
    fi
    local tarball="$1"; shift
    echo "Importing $tarball as $CEOS_IMAGE..."
    run_cmd docker import "$tarball" "$CEOS_IMAGE"
}

cmd_info() {
    echo "Platform:     $PLATFORM ($ARCH)"
    if [ "$USE_MINIMAL" = true ]; then
        echo "Topology:     minimal (Alpine Linux)"
        echo "Image:        alpine:3.21"
    else
        echo "Topology:     full (Arista cEOS)"
        echo "Image:        $CEOS_IMAGE"
    fi
    echo "Lab name:     $LAB_NAME"
    if [ "$PLATFORM" = "macos" ]; then
        echo "Execution:    via OrbStack VM 'clab'"
        echo "Host access:  host.orb.internal"
    else
        echo "Execution:    native"
        echo "Host access:  localhost"
    fi
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: $0 [--minimal] <command> [options]

Cross-platform helper for the topotest containerlab topology.

Options:
  --minimal       Use the minimal Alpine-based topology (low resource)

Commands:
  deploy          Deploy the lab
  destroy         Destroy the lab
  inspect         Show lab status
  save            Save running configs
  graph           Generate topology graph
  ssh <node>      SSH to a node (e.g., hub1)
  exec <node>     Open shell on a node (Cli for cEOS, sh for minimal)
  import <file>   Import a cEOS image tarball
  info            Show detected platform and settings

Environment:
  CEOS_IMAGE      Override the cEOS Docker image name
                  Default: ceos64:4.35.1F (x86_64) or ceosarm:4.35.1F (arm64)

Examples:
  $0 deploy                    # Deploy full cEOS lab
  $0 --minimal deploy          # Deploy minimal Alpine lab
  $0 ssh hub1                  # SSH to hub1 (full lab)
  $0 --minimal exec switch1    # Shell into switch1 (minimal lab)
  $0 import cEOS64-lab-4.35.1F.tar
EOF
}

# --- Main ---

detect_platform

# Parse global options
while [ $# -gt 0 ]; do
    case "$1" in
        --minimal|-m)
            USE_MINIMAL=true
            shift
            ;;
        -*)
            if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
                usage
                exit 0
            fi
            break
            ;;
        *)
            break
            ;;
    esac
done

set_lab_name

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"; shift

case "$command" in
    deploy)   cmd_deploy "$@" ;;
    destroy)  cmd_destroy "$@" ;;
    inspect)  cmd_inspect "$@" ;;
    save)     cmd_save "$@" ;;
    graph)    cmd_graph "$@" ;;
    ssh)      cmd_ssh "$@" ;;
    exec)     cmd_exec "$@" ;;
    import)   cmd_import "$@" ;;
    info)     cmd_info "$@" ;;
    help) usage ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        echo "Run '$0 help' for usage." >&2
        exit 1
        ;;
esac
