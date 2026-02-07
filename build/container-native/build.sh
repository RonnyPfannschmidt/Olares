#!/bin/bash
# Container-Native Olares Build Script
#
# This script builds the container-native version of Olares:
# - Installer container image
# - Bootable OS image (bootc)
# - Tool wrappers
#
# Usage:
#   ./build.sh [command] [options]
#
# Commands:
#   all             Build everything
#   installer       Build installer container only
#   os              Build bootc OS image only
#   wrappers        Generate tool wrapper scripts only
#   iso             Build bootable ISO (requires bootc-image-builder)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build"

# Configuration
VERSION="${VERSION:-dev}"
REGISTRY="${REGISTRY:-ghcr.io/olares}"
PLATFORM="${PLATFORM:-linux/amd64}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "${BLUE}==>${NC} $*"; }

# Detect container runtime
detect_runtime() {
    if command -v podman &>/dev/null; then
        echo "podman"
    elif command -v docker &>/dev/null; then
        echo "docker"
    else
        log_error "No container runtime found (podman or docker required)"
        exit 1
    fi
}

RUNTIME=$(detect_runtime)
log_info "Using container runtime: $RUNTIME"

# Build installer container
build_installer() {
    log_step "Building installer container image..."
    
    local image="${REGISTRY}/installer:${VERSION}"
    
    # Build using repo root as context (matches CI workflow)
    $RUNTIME build \
        --platform "$PLATFORM" \
        -t "$image" \
        -f "${SCRIPT_DIR}/Containerfile.installer" \
        "$PROJECT_ROOT"
    
    log_info "Built: $image"
}

# Build bootc OS image
build_os() {
    log_step "Building bootc OS image..."
    
    local image="${REGISTRY}/os:${VERSION}"
    
    # Create build context
    local context_dir="${BUILD_DIR}/os-context"
    rm -rf "$context_dir"
    mkdir -p "$context_dir"
    
    cp "${SCRIPT_DIR}/Containerfile.olares-os" "$context_dir/Containerfile"
    
    # Build
    $RUNTIME build \
        --platform "$PLATFORM" \
        -t "$image" \
        -f "$context_dir/Containerfile" \
        "$context_dir"
    
    log_info "Built: $image"
}

# Generate tool wrappers
build_wrappers() {
    log_step "Generating tool wrapper scripts..."
    
    local output_dir="${BUILD_DIR}/bin"
    
    python3 "${SCRIPT_DIR}/parse-dependencies.py" \
        "${SCRIPT_DIR}/dependencies.yaml" \
        -f tool-wrappers \
        --output-dir "$output_dir"
    
    log_info "Generated wrappers in: $output_dir"
}

# Generate images list
generate_images_list() {
    log_step "Generating images list..."
    
    python3 "${SCRIPT_DIR}/parse-dependencies.py" \
        "${SCRIPT_DIR}/dependencies.yaml" \
        -f images-list \
        > "${BUILD_DIR}/images.txt"
    
    log_info "Generated: ${BUILD_DIR}/images.txt"
}

# Build netinstall image (minimal image that rebases to full OS on first boot)
build_netinstall() {
    log_step "Building netinstall image..."
    
    local image="${REGISTRY}/netinstall:${VERSION}"
    local target_registry="${TARGET_REGISTRY:-$REGISTRY}"
    local target_tag="${TARGET_TAG:-$VERSION}"
    
    $RUNTIME build \
        --platform "$PLATFORM" \
        --build-arg "OLARES_REGISTRY=${target_registry}" \
        --build-arg "OLARES_TAG=${target_tag}" \
        --build-arg "OLARES_IMAGE=os" \
        -t "$image" \
        -f "${SCRIPT_DIR}/Containerfile.netinstall" \
        "${SCRIPT_DIR}"
    
    log_info "Built: $image"
    log_info "This image will rebase to: ${target_registry}/olares-os:${target_tag} on first boot"
}

# Build bootable ISO (requires sudo and bootc-image-builder)
build_iso() {
    log_step "Building bootable ISO..."
    
    local image="${REGISTRY}/os:${VERSION}"
    local output_dir="${BUILD_DIR}/iso"
    
    mkdir -p "$output_dir"
    
    if [[ "$RUNTIME" == "podman" ]]; then
        sudo podman run --rm --privileged \
            --security-opt label=type:unconfined_t \
            -v "${output_dir}:/output" \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type iso \
            --output /output \
            "$image"
    else
        sudo docker run --rm --privileged \
            -v "${output_dir}:/output" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type iso \
            --output /output \
            "$image"
    fi
    
    log_info "ISO generated in: $output_dir"
}

# Build QCOW2 VM image
build_qcow2() {
    log_step "Building QCOW2 VM image..."
    
    local image="${1:-${REGISTRY}/os:${VERSION}}"
    local output_dir="${BUILD_DIR}/vm"
    
    mkdir -p "$output_dir"
    
    if [[ "$RUNTIME" == "podman" ]]; then
        sudo podman run --rm --privileged \
            --security-opt label=type:unconfined_t \
            -v "${output_dir}:/output" \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type qcow2 \
            --output /output \
            "$image"
    else
        sudo docker run --rm --privileged \
            -v "${output_dir}:/output" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type qcow2 \
            --output /output \
            "$image"
    fi
    
    log_info "QCOW2 generated in: $output_dir"
}

# Push images to registry
push_images() {
    log_step "Pushing images to registry..."
    
    $RUNTIME push "${REGISTRY}/installer:${VERSION}"
    $RUNTIME push "${REGISTRY}/os:${VERSION}"
    
    log_info "Images pushed to registry"
}

# Clean build artifacts
clean() {
    log_step "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    log_info "Clean complete"
}

# Show help
usage() {
    cat <<EOF
Container-Native Olares Build Script

Usage: $0 [command] [options]

Commands:
    all             Build everything (installer + OS + wrappers)
    installer       Build installer container image
    os              Build bootc OS image
    netinstall      Build netinstall image (minimal, rebases on first boot)
    wrappers        Generate tool wrapper scripts
    images-list     Generate list of container images
    iso             Build bootable ISO (requires root)
    qcow2           Build QCOW2 VM image (requires root)
    push            Push images to registry
    clean           Remove build artifacts
    help            Show this help

Options:
    VERSION=x.y.z       Set version (default: dev)
    REGISTRY=...        Set registry (default: ghcr.io/olares)
    PLATFORM=...        Set platform (default: linux/amd64)
    TARGET_REGISTRY=... Registry the netinstall will pull from (for PR testing)
    TARGET_TAG=...      Tag the netinstall will pull (for PR testing)

Examples:
    # Build everything
    VERSION=1.0.0 ./build.sh all

    # Build only the OS image
    ./build.sh os

    # Build netinstall pointing to a PR
    TARGET_REGISTRY=ghcr.io/myuser TARGET_TAG=pr-123 ./build.sh netinstall

    # Build and push
    VERSION=1.0.0 ./build.sh all && ./build.sh push

    # Generate ISO
    sudo VERSION=1.0.0 ./build.sh iso

    # Generate QCOW2 for testing in VM
    sudo VERSION=1.0.0 ./build.sh qcow2

PR Testing:
    # Build netinstall that points to PR images
    TARGET_REGISTRY=ghcr.io/contributor TARGET_TAG=pr-42 ./build.sh netinstall
    
    # Build QCOW2 from netinstall
    sudo ./build.sh qcow2 \${REGISTRY}/netinstall:\${VERSION}
    
    # Boot VM - it will automatically pull full image on first boot

EOF
}

# Main
main() {
    mkdir -p "$BUILD_DIR"
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        all)
            generate_images_list
            build_wrappers
            build_installer
            build_os
            ;;
        installer)
            build_installer
            ;;
        os)
            build_os
            ;;
        netinstall)
            build_netinstall
            ;;
        wrappers)
            build_wrappers
            ;;
        images-list)
            generate_images_list
            ;;
        iso)
            build_os
            build_iso
            ;;
        qcow2)
            build_qcow2 "$@"
            ;;
        push)
            push_images
            ;;
        clean)
            clean
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
