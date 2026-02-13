#!/usr/bin/env bash
set -euo pipefail

# lab.sh — Cross-platform helper for topotest containerlab topology
# Supports macOS/ARM64 (via OrbStack) and native Linux/x86_64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_FILE="$SCRIPT_DIR/topology.clab.yml"
TOPO_MINIMAL="$SCRIPT_DIR/topology-minimal.clab.yml"
USE_MINIMAL=false
LAB_NAME="topotest"
DEFAULT_SUBNET="172.20.20.0/24"
DEFAULT_SUBNET_V6="3fff:172:20:20::/64"
DEFAULT_NETWORK="clab"

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

# --- Network validation ---

# Get Docker command (wrapped for macOS)
docker_cmd() {
    if [ "$PLATFORM" = "macos" ]; then
        orb exec -m clab docker "$@"
    else
        docker "$@"
    fi
}

# List all Docker networks with their subnets
list_networks() {
    docker_cmd network ls --format '{{.Name}}' | while read -r name; do
        # Get IPv4 subnet only (filter out IPv6)
        subnet=$(docker_cmd network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)
        if [ -n "$subnet" ]; then
            printf "  %-40s %s\n" "$name" "$subnet"
        fi
    done
}

# Check if a network with specific subnet exists
find_network_by_subnet() {
    local target_subnet="$1"
    local networks
    networks=$(docker_cmd network ls --format '{{.Name}}')
    for name in $networks; do
        # Get IPv4 subnet only (filter out IPv6)
        subnet=$(docker_cmd network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)
        if [ "$subnet" = "$target_subnet" ]; then
            echo "$name"
            return 0
        fi
    done
}

# Check if a network has any attached containers
network_has_containers() {
    local name="$1"
    local containers
    containers=$(docker_cmd network inspect "$name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
    [ -n "$containers" ]
}

# Suggest next available subnet in 172.20.x.0/24 range
# Outputs: "<ipv4_subnet> <ipv6_subnet>"
suggest_subnet() {
    local used_subnets
    used_subnets=$(docker_cmd network ls --format '{{.Name}}' | while read -r name; do
        docker_cmd network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n'
    done | grep "^172\.20\." | sort -u || true)

    for i in $(seq 20 30); do
        local candidate="172.20.${i}.0/24"
        if ! echo "$used_subnets" | grep -q "^${candidate}$"; then
            echo "$candidate 3fff:172:20:${i}::/64"
            return 0
        fi
    done
    echo "172.20.31.0/24 3fff:172:20:31::/64"
}

# Validate network availability before deploy
validate_network() {
    local conflict_network
    conflict_network=$(find_network_by_subnet "$DEFAULT_SUBNET")

    # Check if clab network already exists and is correct
    if [ -n "$conflict_network" ] && [ "$conflict_network" = "$DEFAULT_NETWORK" ]; then
        echo "Network '$DEFAULT_NETWORK' already exists with subnet $DEFAULT_SUBNET (OK)"
        return 0
    fi

    # No conflict
    if [ -z "$conflict_network" ]; then
        return 0
    fi

    # Conflict detected
    echo ""
    echo "Network conflict detected!"
    echo "  Subnet $DEFAULT_SUBNET is in use by: $conflict_network"
    echo ""

    # Check if conflicting network has containers
    if network_has_containers "$conflict_network"; then
        echo "  Warning: Network '$conflict_network' has running containers."
        echo ""
        echo "Options:"
        echo "  1) Use a different subnet (recommended)"
        echo "  2) Stop containers and remove network"
        echo "  3) Cancel"
    else
        echo "  Network '$conflict_network' has no running containers."
        echo ""
        echo "Options:"
        echo "  1) Remove unused network '$conflict_network' and continue"
        echo "  2) Use a different subnet"
        echo "  3) Cancel"
    fi
    echo ""

    local choice
    read -r -p "Select option [1-3]: " choice

    if network_has_containers "$conflict_network"; then
        case "$choice" in
            1)
                local subnets subnet_v4 subnet_v6
                subnets=$(suggest_subnet)
                subnet_v4=$(echo "$subnets" | cut -d' ' -f1)
                subnet_v6=$(echo "$subnets" | cut -d' ' -f2)
                echo "Using subnet: $subnet_v4 (IPv6: $subnet_v6)"
                export CLAB_MGMT_NETWORK_SUBNET="$subnet_v4"
                export CLAB_MGMT_NETWORK_SUBNET_V6="$subnet_v6"
                export CLAB_MGMT_NETWORK_NAME="clab-$$"
                return 0
                ;;
            2)
                echo "Please stop containers manually and re-run deploy."
                return 1
                ;;
            *)
                echo "Cancelled."
                return 1
                ;;
        esac
    else
        case "$choice" in
            1)
                echo "Removing network '$conflict_network'..."
                docker_cmd network rm "$conflict_network"
                echo "Network removed."
                return 0
                ;;
            2)
                local subnets subnet_v4 subnet_v6
                subnets=$(suggest_subnet)
                subnet_v4=$(echo "$subnets" | cut -d' ' -f1)
                subnet_v6=$(echo "$subnets" | cut -d' ' -f2)
                echo "Using subnet: $subnet_v4 (IPv6: $subnet_v6)"
                export CLAB_MGMT_NETWORK_SUBNET="$subnet_v4"
                export CLAB_MGMT_NETWORK_SUBNET_V6="$subnet_v6"
                export CLAB_MGMT_NETWORK_NAME="clab-$$"
                return 0
                ;;
            *)
                echo "Cancelled."
                return 1
                ;;
        esac
    fi
}

# --- Commands ---

cmd_networks() {
    echo "Docker networks and their subnets:"
    echo ""
    list_networks
    echo ""

    local conflict
    conflict=$(find_network_by_subnet "$DEFAULT_SUBNET")

    if [ -n "$conflict" ]; then
        if [ "$conflict" = "$DEFAULT_NETWORK" ]; then
            echo "Status: Network '$DEFAULT_NETWORK' exists with expected subnet (ready)"
        else
            echo "Status: Conflict - subnet $DEFAULT_SUBNET used by '$conflict'"
            if network_has_containers "$conflict"; then
                echo "        Network has running containers"
            else
                echo "        Network is unused (can be removed)"
            fi
        fi
    else
        echo "Status: Subnet $DEFAULT_SUBNET is available"
    fi

    echo ""
    echo "Suggested available subnet: $(suggest_subnet | cut -d' ' -f1)"
}

cmd_deploy() {
    # Validate network availability
    if ! validate_network; then
        exit 1
    fi

    if [ "$USE_MINIMAL" = true ]; then
        echo "Deploying minimal lab (Alpine Linux)..."
    else
        echo "Deploying lab (image: $CEOS_IMAGE)..."
    fi

    # Build extra args for custom network settings
    local extra_args=()
    if [ -n "${CLAB_MGMT_NETWORK_SUBNET:-}" ]; then
        extra_args+=(--ipv4-subnet "$CLAB_MGMT_NETWORK_SUBNET")
    fi
    if [ -n "${CLAB_MGMT_NETWORK_SUBNET_V6:-}" ]; then
        extra_args+=(--ipv6-subnet "$CLAB_MGMT_NETWORK_SUBNET_V6")
    fi
    if [ -n "${CLAB_MGMT_NETWORK_NAME:-}" ]; then
        extra_args+=(--network "$CLAB_MGMT_NETWORK_NAME")
    fi

    if [ "$PLATFORM" = "macos" ]; then
        orb exec -m clab sudo CEOS_IMAGE="$CEOS_IMAGE" containerlab deploy -t "$(topo_path)" "${extra_args[@]}" "$@"
    else
        sudo CEOS_IMAGE="$CEOS_IMAGE" containerlab deploy -t "$(topo_path)" "${extra_args[@]}" "$@"
    fi
}

cmd_destroy() {
    echo "Destroying lab..."
    # Try normal destroy first; if it fails due to network issues, offer cleanup
    if ! run_clab destroy -t "$(topo_path)" "$@" 2>&1; then
        echo ""
        echo "Destroy failed. This can happen if the lab was deployed with a custom network."
        echo "Try: $0 cleanup"
    fi
}

cmd_cleanup() {
    echo "Force cleanup of lab containers and networks..."
    echo ""

    # Find and remove lab containers
    local containers
    containers=$(docker_cmd ps -a --filter "name=clab-${LAB_NAME}" --format '{{.Names}}' || true)

    if [ -n "$containers" ]; then
        echo "Removing containers:"
        for c in $containers; do
            echo "  - $c"
            docker_cmd rm -f "$c" >/dev/null 2>&1 || true
        done
    else
        echo "No lab containers found."
    fi

    # Find and remove clab networks (custom networks created by deploy)
    local networks
    networks=$(docker_cmd network ls --format '{{.Name}}' | grep -E "^clab(-[0-9]+)?$" || true)

    if [ -n "$networks" ]; then
        echo ""
        echo "Removing networks:"
        for n in $networks; do
            # Only remove if no containers attached
            if ! network_has_containers "$n"; then
                echo "  - $n"
                docker_cmd network rm "$n" >/dev/null 2>&1 || true
            else
                echo "  - $n (skipped - has containers)"
            fi
        done
    fi

    # Remove lab directory
    local lab_dir="$SCRIPT_DIR/clab-${LAB_NAME}"
    if [ -d "$lab_dir" ]; then
        echo ""
        echo "Removing lab directory: $lab_dir"
        rm -rf "$lab_dir"
    fi

    echo ""
    echo "Cleanup complete."
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
  deploy          Deploy the lab (validates network first)
  destroy         Destroy the lab
  cleanup         Force remove lab containers and networks
  inspect         Show lab status
  save            Save running configs
  graph           Generate topology graph
  networks        Show Docker networks and check for conflicts
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
    cleanup)  cmd_cleanup "$@" ;;
    inspect)  cmd_inspect "$@" ;;
    save)     cmd_save "$@" ;;
    graph)    cmd_graph "$@" ;;
    networks) cmd_networks "$@" ;;
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
