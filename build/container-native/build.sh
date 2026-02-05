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
    
    # Create build context with necessary files
    local context_dir="${BUILD_DIR}/installer-context"
    rm -rf "$context_dir"
    mkdir -p "$context_dir"
    
    # Copy required files
    cp -r "${SCRIPT_DIR}/scripts" "$context_dir/"
    cp "${SCRIPT_DIR}/dependencies.yaml" "$context_dir/"
    cp "${SCRIPT_DIR}/Containerfile.installer" "$context_dir/Containerfile"
    
    # Copy wizard config (Helm charts)
    if [[ -d "${PROJECT_ROOT}/build/base-package/wizard" ]]; then
        cp -r "${PROJECT_ROOT}/build/base-package/wizard" "$context_dir/"
    else
        mkdir -p "$context_dir/wizard/config"
        log_warn "Wizard config not found, creating placeholder"
    fi
    
    # Build
    $RUNTIME build \
        --platform "$PLATFORM" \
        -t "$image" \
        -f "$context_dir/Containerfile" \
        "$context_dir"
    
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
    wrappers        Generate tool wrapper scripts
    images-list     Generate list of container images
    iso             Build bootable ISO (requires root)
    push            Push images to registry
    clean           Remove build artifacts
    help            Show this help

Options:
    VERSION=x.y.z   Set version (default: dev)
    REGISTRY=...    Set registry (default: ghcr.io/olares)
    PLATFORM=...    Set platform (default: linux/amd64)

Examples:
    # Build everything
    VERSION=1.0.0 ./build.sh all

    # Build only the OS image
    ./build.sh os

    # Build and push
    VERSION=1.0.0 ./build.sh all && ./build.sh push

    # Generate ISO
    sudo VERSION=1.0.0 ./build.sh iso

EOF
}

# Main
main() {
    mkdir -p "$BUILD_DIR"
    
    local command="${1:-help}"
    
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
