#!/bin/bash
# Check Olares installation status

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/host-etc/kubernetes/admin.conf}"
OLARES_DATA_DIR="${OLARES_DATA_DIR:-/host-var-lib/olares}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_mark="${GREEN}✓${NC}"
cross_mark="${RED}✗${NC}"
warn_mark="${YELLOW}!${NC}"

echo "Olares Installation Status"
echo "=========================="
echo ""

# Check installation marker
if [[ -f "${OLARES_DATA_DIR}/installed" ]]; then
    echo -e "$check_mark Olares installation marker found"
    echo "  $(cat "${OLARES_DATA_DIR}/installed")"
else
    echo -e "$cross_mark Olares installation marker not found"
fi
echo ""

# Check Kubernetes connectivity
echo "Kubernetes Status:"
if kubectl --kubeconfig="$KUBECONFIG" cluster-info &>/dev/null; then
    echo -e "  $check_mark API server reachable"
    
    # Check nodes
    nodes=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o name 2>/dev/null | wc -l)
    echo -e "  $check_mark Nodes: $nodes"
    
    # Check namespaces
    for ns in olares-system user-system; do
        if kubectl --kubeconfig="$KUBECONFIG" get namespace "$ns" &>/dev/null; then
            echo -e "  $check_mark Namespace: $ns"
        else
            echo -e "  $cross_mark Namespace: $ns (not found)"
        fi
    done
else
    echo -e "  $cross_mark Cannot connect to Kubernetes API"
    echo "  Check KUBECONFIG or ensure cluster is running"
fi
echo ""

# Check container runtime
echo "Container Runtime:"
if [[ -S /var/run/containerd/containerd.sock ]]; then
    echo -e "  $check_mark containerd socket available"
elif [[ -S /var/run/docker.sock ]]; then
    echo -e "  $check_mark docker socket available"
else
    echo -e "  $warn_mark No container runtime socket mounted"
fi
echo ""

# Check key pods
echo "Key Pods Status:"
if kubectl --kubeconfig="$KUBECONFIG" cluster-info &>/dev/null; then
    kubectl --kubeconfig="$KUBECONFIG" get pods -n olares-system -o wide 2>/dev/null || echo "  No pods in olares-system"
fi
