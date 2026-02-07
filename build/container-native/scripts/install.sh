#!/bin/bash
# Olares Installation Script (runs inside container)
#
# This script performs the Olares installation from within the installer container.
# It expects the host filesystem to be mounted at specific paths.

set -euo pipefail

# Configuration
OLARES_VERSION="${OLARES_VERSION:-1.0.0}"
KUBECONFIG="${KUBECONFIG:-/host-etc/kubernetes/admin.conf}"
OLARES_DATA_DIR="${OLARES_DATA_DIR:-/host-var-lib/olares}"
OLARES_CHARTS_DIR="${OLARES_CHARTS_DIR:-/olares/charts}"
DRY_RUN="${DRY_RUN:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if running in container
    if [[ ! -f /.dockerenv ]] && [[ ! -f /run/.containerenv ]]; then
        log_warn "Not running in a container - this is unusual"
    fi

    # Check host mounts
    if [[ ! -d /host-etc ]]; then
        log_error "Host /etc not mounted at /host-etc"
        log_error "Run with: -v /etc:/host-etc"
        exit 1
    fi

    if [[ ! -d /host-var-lib ]]; then
        log_error "Host /var/lib not mounted at /host-var-lib"
        log_error "Run with: -v /var/lib:/host-var-lib"
        exit 1
    fi

    # Check container runtime access
    if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
        log_error "No container runtime detected"
        log_error "Mount the runtime socket (e.g., -v /run/podman:/var/run/podman)"
        exit 1
    fi

    # Check for kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in container"
        exit 1
    fi

    # Check for helm
    if ! command -v helm &>/dev/null; then
        log_error "helm not found in container"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

# Wait for Kubernetes API to be ready
wait_for_kubernetes() {
    log_info "Waiting for Kubernetes API server..."

    local retries=60
    local count=0

    while [[ $count -lt $retries ]]; do
        if kubectl --kubeconfig="$KUBECONFIG" cluster-info &>/dev/null; then
            log_info "Kubernetes API server is ready"
            return 0
        fi
        count=$((count + 1))
        echo -n "."
        sleep 2
    done

    log_error "Timeout waiting for Kubernetes API server"
    return 1
}

# Pull required container images
#
# NOTE: On Quadlet-based Olares OS, k3s uses its own embedded containerd.
# Images pulled into the host runtime (podman) are NOT visible to k3s.
# k3s will pull images on demand when pods are scheduled.
# This function is most useful for non-Quadlet deployments or pre-caching
# images in the host runtime for other purposes.
pull_images() {
    log_info "Pulling required container images..."

    local images_file="/olares/dependencies.yaml"
    
    if [[ ! -f "$images_file" ]]; then
        log_error "Dependencies manifest not found: $images_file"
        return 1
    fi

    # Extract image list using yq
    local images
    images=$(yq '.spec.images[].image' "$images_file")

    local total
    total=$(echo "$images" | wc -l)
    local current=0

    while IFS= read -r image; do
        current=$((current + 1))
        log_info "[$current/$total] Pulling: $image"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY-RUN] Would pull: $image"
            continue
        fi

        case "$CONTAINER_RUNTIME" in
            podman)
                podman pull "$image" || log_warn "Failed to pull: $image"
                ;;
            containerd)
                ctr -n k8s.io images pull "$image" || log_warn "Failed to pull: $image"
                ;;
            docker)
                docker pull "$image" || log_warn "Failed to pull: $image"
                ;;
            *)
                crictl pull "$image" || log_warn "Failed to pull: $image"
                ;;
        esac
    done <<< "$images"

    log_info "Image pull complete"
}

# Install system namespaces
install_namespaces() {
    log_info "Creating Olares namespaces..."

    local namespaces=(
        "olares-system"
        "user-system"
        "user-space"
    )

    for ns in "${namespaces[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY-RUN] Would create namespace: $ns"
            continue
        fi

        kubectl --kubeconfig="$KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml | \
            kubectl --kubeconfig="$KUBECONFIG" apply -f -
    done
}

# Install Helm charts
install_charts() {
    log_info "Installing Olares Helm charts..."

    # List of charts to install in order
    local charts=(
        "settings:olares-system"
        "account:olares-system"
        "system-apps:olares-system"
    )

    for chart_spec in "${charts[@]}"; do
        local chart_name="${chart_spec%%:*}"
        local namespace="${chart_spec##*:}"
        local chart_path="${OLARES_CHARTS_DIR}/${chart_name}"

        if [[ ! -d "$chart_path" ]]; then
            log_warn "Chart not found: $chart_path, skipping"
            continue
        fi

        log_info "Installing chart: $chart_name in namespace: $namespace"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY-RUN] Would install: helm upgrade --install $chart_name $chart_path -n $namespace"
            continue
        fi

        helm --kubeconfig="$KUBECONFIG" upgrade --install "$chart_name" "$chart_path" \
            --namespace "$namespace" \
            --create-namespace \
            --wait \
            --timeout 10m || {
                log_error "Failed to install chart: $chart_name"
                return 1
            }
    done

    log_info "Helm charts installed successfully"
}

# Create marker file to indicate successful installation
mark_installed() {
    log_info "Marking installation complete..."

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would create marker file"
        return 0
    fi

    mkdir -p "$OLARES_DATA_DIR"
    cat > "${OLARES_DATA_DIR}/installed" <<EOF
version=${OLARES_VERSION}
installed_at=$(date -Iseconds)
installer_image=${INSTALLER_IMAGE:-unknown}
EOF

    log_info "Installation marker created"
}

# Main installation flow
main() {
    echo "=============================================="
    echo "  Olares Container-Native Installer"
    echo "  Version: ${OLARES_VERSION}"
    echo "=============================================="
    echo ""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="true"
                log_info "Dry-run mode enabled"
                shift
                ;;
            --version)
                OLARES_VERSION="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Run installation steps
    check_prerequisites
    wait_for_kubernetes
    pull_images
    install_namespaces
    install_charts
    mark_installed

    echo ""
    echo "=============================================="
    echo "  Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Access Olares at: https://olares.local"
    echo "  2. Complete initial setup wizard"
    echo ""
}

main "$@"
