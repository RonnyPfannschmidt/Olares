#!/bin/bash
# Smoke test for Olares OS VM
#
# Runs on the CI host, SSHes into the booted VM to verify:
# - systemd services are running
# - k3s is ready and node is Ready
# - basic Kubernetes operations work (namespace, pod)
#
# Usage:
#   SSH_KEY=/tmp/ci-key SSH_PORT=2222 ./smoke-test.sh
#
# Environment:
#   SSH_KEY   - Path to SSH private key (required)
#   SSH_PORT  - SSH port on localhost (default: 2222)
#   SSH_HOST  - SSH host (default: localhost)
#   K3S_TIMEOUT - Seconds to wait for k3s (default: 600)

set -euo pipefail

SSH_KEY="${SSH_KEY:?SSH_KEY must be set}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-localhost}"
K3S_TIMEOUT="${K3S_TIMEOUT:-600}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $*"; }
fail() { echo -e "${RED}FAIL${NC}: $*"; }
info() { echo -e "${YELLOW}----${NC}: $*"; }

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    info "Running: $name"
    if "$@"; then
        pass "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        fail "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# SSH into the VM
ssh_cmd() {
    ssh -i "$SSH_KEY" -p "$SSH_PORT" $SSH_OPTS root@"$SSH_HOST" "$@"
}

# ===========================================================================
# Wait phases
# ===========================================================================

wait_for_ssh() {
    info "Waiting for SSH (up to 5 minutes)..."
    local deadline=$((SECONDS + 300))

    while [[ $SECONDS -lt $deadline ]]; do
        if ssh_cmd true 2>/dev/null; then
            pass "SSH is reachable"
            return 0
        fi
        sleep 5
    done

    fail "SSH timeout after 5 minutes"
    return 1
}

wait_for_k3s() {
    info "Waiting for k3s to be ready (up to ${K3S_TIMEOUT}s)..."
    local deadline=$((SECONDS + K3S_TIMEOUT))

    while [[ $SECONDS -lt $deadline ]]; do
        if ssh_cmd "kubectl get nodes 2>/dev/null" | grep -q " Ready"; then
            pass "k3s node is Ready"
            return 0
        fi
        sleep 10
    done

    fail "k3s timeout after ${K3S_TIMEOUT}s"
    # Dump diagnostics before failing
    info "Collecting diagnostics..."
    ssh_cmd "systemctl status k3s" 2>/dev/null || true
    ssh_cmd "journalctl -u k3s --no-pager -n 50" 2>/dev/null || true
    return 1
}

# ===========================================================================
# Test cases
# ===========================================================================

test_systemd_k3s() {
    ssh_cmd "systemctl is-active k3s"
}

test_systemd_olares_agent() {
    # olares-agent is oneshot, RemainAfterExit=yes, so check it's not failed
    local status
    status=$(ssh_cmd "systemctl show -p ActiveState olares-agent.service --value")
    [[ "$status" == "active" || "$status" == "activating" ]]
}

test_kubectl_nodes() {
    local output
    output=$(ssh_cmd "kubectl get nodes -o wide")
    echo "$output"
    echo "$output" | grep -q " Ready"
}

test_kubectl_pods_system() {
    ssh_cmd "kubectl get pods -A"
}

test_create_namespace() {
    ssh_cmd "kubectl create namespace smoke-test --dry-run=client -o yaml | kubectl apply -f -"
}

test_run_pod() {
    # Deploy a simple pod
    ssh_cmd "kubectl run smoke-test --image=busybox:1.36 --namespace=smoke-test --restart=Never --command -- sleep 300"

    # Wait for it to be running (up to 3 minutes for image pull)
    info "Waiting for test pod..."
    local deadline=$((SECONDS + 180))
    while [[ $SECONDS -lt $deadline ]]; do
        if ssh_cmd "kubectl get pod smoke-test -n smoke-test -o jsonpath='{.status.phase}'" 2>/dev/null | grep -q "Running"; then
            return 0
        fi
        sleep 5
    done

    fail "Test pod did not reach Running state"
    ssh_cmd "kubectl describe pod smoke-test -n smoke-test" 2>/dev/null || true
    return 1
}

test_cleanup() {
    ssh_cmd "kubectl delete namespace smoke-test --wait=false"
}

test_podman_running() {
    ssh_cmd "podman ps --format '{{.Names}}'" | grep -q "k3s"
}

# ===========================================================================
# Main
# ===========================================================================

main() {
    echo "============================================"
    echo "  Olares OS Smoke Tests"
    echo "============================================"
    echo ""
    echo "  SSH: ${SSH_HOST}:${SSH_PORT}"
    echo "  Key: ${SSH_KEY}"
    echo ""

    # Phase 1: Wait for VM to boot and become reachable
    wait_for_ssh || exit 1

    # Show basic info
    info "OS release:"
    ssh_cmd "cat /etc/os-release | head -5" 2>/dev/null || true
    info "Uptime:"
    ssh_cmd "uptime" 2>/dev/null || true
    echo ""

    # Phase 2: Wait for k3s
    wait_for_k3s || exit 1
    echo ""

    # Phase 3: Run tests
    echo "============================================"
    echo "  Running tests"
    echo "============================================"
    echo ""

    run_test "k3s systemd service is active" test_systemd_k3s
    run_test "olares-agent service ran" test_systemd_olares_agent
    run_test "k3s container running in podman" test_podman_running
    run_test "kubectl get nodes shows Ready" test_kubectl_nodes
    run_test "kubectl get pods -A" test_kubectl_pods_system
    run_test "create smoke-test namespace" test_create_namespace
    run_test "run test pod" test_run_pod
    run_test "cleanup smoke-test namespace" test_cleanup

    # Summary
    echo ""
    echo "============================================"
    echo "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
    echo "============================================"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
