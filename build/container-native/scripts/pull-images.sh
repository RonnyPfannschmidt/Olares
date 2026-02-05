#!/bin/bash
# Pull all Olares container images
#
# This script pulls all required container images to the local container runtime.
# Useful for pre-staging images before installation or for air-gapped environments.

set -euo pipefail

DEPENDENCIES_FILE="${DEPENDENCIES_FILE:-/olares/dependencies.yaml}"
PARALLEL_PULLS="${PARALLEL_PULLS:-4}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Detect container runtime
detect_runtime() {
    if [[ -S /var/run/containerd/containerd.sock ]]; then
        echo "containerd"
    elif [[ -S /var/run/docker.sock ]]; then
        echo "docker"
    elif [[ -S /var/run/crio/crio.sock ]]; then
        echo "crio"
    else
        echo "none"
    fi
}

# Pull a single image
pull_image() {
    local image="$1"
    local runtime="$2"

    case "$runtime" in
        containerd)
            ctr -n k8s.io images pull "$image" 2>&1
            ;;
        docker)
            docker pull "$image" 2>&1
            ;;
        crio|*)
            crictl pull "$image" 2>&1
            ;;
    esac
}

# Export image to tarball (for air-gapped)
export_image() {
    local image="$1"
    local runtime="$2"
    local output_dir="$3"

    local safe_name
    safe_name=$(echo "$image" | tr '/:' '_')

    case "$runtime" in
        containerd)
            ctr -n k8s.io images export "${output_dir}/${safe_name}.tar" "$image"
            ;;
        docker)
            docker save "$image" -o "${output_dir}/${safe_name}.tar"
            ;;
        *)
            log_warn "Export not supported for runtime: $runtime"
            ;;
    esac
}

main() {
    local export_dir=""
    local list_only="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --export)
                export_dir="$2"
                shift 2
                ;;
            --list)
                list_only="true"
                shift
                ;;
            --parallel)
                PARALLEL_PULLS="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Check dependencies file
    if [[ ! -f "$DEPENDENCIES_FILE" ]]; then
        log_error "Dependencies file not found: $DEPENDENCIES_FILE"
        exit 1
    fi

    # Extract images
    local images
    images=$(yq '.spec.images[].image' "$DEPENDENCIES_FILE")

    local total
    total=$(echo "$images" | wc -l)

    # List only mode
    if [[ "$list_only" == "true" ]]; then
        echo "$images"
        exit 0
    fi

    # Detect runtime
    local runtime
    runtime=$(detect_runtime)

    if [[ "$runtime" == "none" ]]; then
        log_error "No container runtime detected"
        log_error "Mount the runtime socket to enable image operations"
        exit 1
    fi

    log_info "Using container runtime: $runtime"
    log_info "Total images to pull: $total"

    # Create export directory if needed
    if [[ -n "$export_dir" ]]; then
        mkdir -p "$export_dir"
        log_info "Will export images to: $export_dir"
    fi

    # Pull images
    local current=0
    local failed=0

    while IFS= read -r image; do
        current=$((current + 1))
        log_info "[$current/$total] Pulling: $image"

        if pull_image "$image" "$runtime"; then
            if [[ -n "$export_dir" ]]; then
                log_info "  Exporting to tarball..."
                export_image "$image" "$runtime" "$export_dir" || log_warn "  Export failed"
            fi
        else
            log_warn "  Failed to pull: $image"
            failed=$((failed + 1))
        fi
    done <<< "$images"

    echo ""
    log_info "Pull complete: $((total - failed))/$total successful"

    if [[ $failed -gt 0 ]]; then
        log_warn "$failed images failed to pull"
        exit 1
    fi
}

main "$@"
