#!/bin/bash
# Olares Installer Entrypoint
#
# This script is the entrypoint for the containerized installer.
# It dispatches to the appropriate sub-command.

set -euo pipefail

SCRIPTS_DIR="/olares/scripts"

usage() {
    cat <<EOF
Olares Container-Native Installer

Usage: olares-installer <command> [options]

Commands:
    install         Install Olares on this node
    upgrade         Upgrade an existing Olares installation
    uninstall       Remove Olares from this node
    pull-images     Pre-pull all required container images
    status          Check installation status
    help            Show this help message

Options:
    --version       Olares version to install (default: from manifest)
    --config        Path to configuration file
    --dry-run       Show what would be done without making changes

Environment Variables:
    KUBECONFIG              Path to kubeconfig (default: /host-etc/kubernetes/admin.conf)
    OLARES_DATA_DIR         Data directory (default: /host-var-lib/olares)
    OLARES_CHARTS_DIR       Helm charts directory (default: /olares/charts)
    CONTAINER_RUNTIME       Container runtime socket path

Examples:
    # Install Olares (Quadlet-based OS with podman)
    podman run --rm -it --privileged --net=host \\
        -v /run/podman:/var/run/podman \\
        -v /etc:/host-etc \\
        -v /var/lib:/host-var-lib \\
        ghcr.io/olares/installer:latest install

    # Pre-pull images (NOTE: on Quadlet OS, images pulled here go to
    # host podman, not k3s containerd - k3s pulls images on demand)
    podman run --rm -it --net=host \\
        -v /run/podman:/var/run/podman \\
        ghcr.io/olares/installer:latest pull-images

EOF
}

# Ensure we have access to container runtime
#
# NOTE: On Quadlet-based Olares OS, the host runtime is podman and k3s runs
# as a container with its own embedded containerd. Images pulled via podman
# are NOT visible to k3s. For pre-pulling into k3s, use crictl (which execs
# into the k3s container) or let k3s pull images on demand.
check_runtime() {
    if [[ -S /var/run/podman/podman.sock ]]; then
        export CONTAINER_RUNTIME="podman"
        export CONTAINER_SOCKET="/var/run/podman/podman.sock"
        echo "Using podman runtime"
    elif [[ -S /var/run/containerd/containerd.sock ]]; then
        export CONTAINER_RUNTIME="containerd"
        export CONTAINER_SOCKET="/var/run/containerd/containerd.sock"
        echo "Using containerd runtime"
    elif [[ -S /var/run/docker.sock ]]; then
        export CONTAINER_RUNTIME="docker"
        export CONTAINER_SOCKET="/var/run/docker.sock"
        echo "Using docker runtime"
    elif [[ -S /var/run/crio/crio.sock ]]; then
        export CONTAINER_RUNTIME="crio"
        export CONTAINER_SOCKET="/var/run/crio/crio.sock"
        echo "Using cri-o runtime"
    else
        echo "Warning: No container runtime socket found"
        echo "Mount the runtime socket for image operations"
    fi
}

main() {
    local command="${1:-help}"
    shift || true

    check_runtime

    case "$command" in
        install)
            exec "${SCRIPTS_DIR}/install.sh" "$@"
            ;;
        upgrade)
            exec "${SCRIPTS_DIR}/upgrade.sh" "$@"
            ;;
        uninstall)
            exec "${SCRIPTS_DIR}/uninstall.sh" "$@"
            ;;
        pull-images)
            exec "${SCRIPTS_DIR}/pull-images.sh" "$@"
            ;;
        status)
            exec "${SCRIPTS_DIR}/status.sh" "$@"
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
