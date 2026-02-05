# Olares Test VM Infrastructure

This directory contains tools for testing Olares in VMs with automatic updates from PR images.

## Overview

Two approaches for testing:

1. **Test VM Container** (`Containerfile.test-vm`): Runs QEMU in a container
2. **Self-Updating OS** (`Containerfile.test-os`): OS image that auto-updates on boot

## Approach 1: Test VM Container

Run an Olares VM inside a container with KVM acceleration.

### Build

```bash
podman build -t olares-test-vm -f Containerfile.test-vm .
```

### Run

```bash
# Create persistent storage directory
mkdir -p ~/olares-test-data

# Run the test VM
podman run --rm -it --privileged \
    --device /dev/kvm \
    -v ~/olares-test-data:/vm \
    -e OLARES_REGISTRY=ghcr.io/myuser \
    -e OLARES_TAG=pr-123 \
    -p 2222:2222 \
    -p 5900:5900 \
    -p 6443:6443 \
    olares-test-vm
```

### First Run

On first run (no disk image):
1. Downloads netinstall image from registry
2. Builds QCOW2 disk image
3. Boots VM
4. VM rebases to full Olares OS and reboots

### Subsequent Runs

On each boot:
1. Boots existing disk
2. Cloud-init checks for updates
3. If update available, applies and reboots
4. Continues into Olares

### Connect

```bash
# SSH (after Olares is up)
ssh -p 2222 root@localhost

# VNC (for console access)
vncviewer localhost:5900

# Kubernetes API
export KUBECONFIG=~/.kube/olares-test
kubectl --server=https://localhost:6443 get nodes
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLARES_REGISTRY` | `ghcr.io/olares` | Container registry |
| `OLARES_TAG` | `latest` | Image tag (e.g., `pr-123`) |
| `OLARES_IMAGE` | `os` | Image name |
| `VM_MEMORY` | `4096` | VM memory in MB |
| `VM_CPUS` | `2` | VM CPU count |
| `VM_DISK_SIZE` | `50G` | Disk size |
| `VM_SSH_PORT` | `2222` | SSH port mapping |
| `VM_VNC_PORT` | `5900` | VNC port |

## Approach 2: Self-Updating OS Image

Build a test OS image that auto-updates on every boot.

### Build

```bash
# Build test OS from PR image
podman build \
    --build-arg BASE_IMAGE=ghcr.io/myuser/olares-os:pr-123 \
    -t olares-test-os:pr-123 \
    -f Containerfile.test-os .
```

### Create VM

```bash
# Build QCOW2 from test OS
sudo podman run --rm --privileged \
    -v ./output:/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    olares-test-os:pr-123

# Or use the build script
cd ../
sudo ./build.sh qcow2 olares-test-os:pr-123
```

### Boot Flow

```
┌─────────────────┐
│    VM Boots     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ olares-auto-    │
│ update.service  │
│ runs            │
└────────┬────────┘
         │
         ▼
┌─────────────────┐    Yes    ┌─────────────────┐
│ Update          │ ────────> │ bootc upgrade   │
│ available?      │           │ + reboot        │
└────────┬────────┘           └─────────────────┘
         │ No
         ▼
┌─────────────────┐
│ Continue boot   │
│ into Olares     │
└─────────────────┘
```

### Check Status

Inside the VM:

```bash
# Show test status
olares-test-status

# View update log
journalctl -u olares-auto-update

# Manual update check
bootc upgrade --check
```

## PR Testing Workflow

### 1. PR Builds Images

When you open a PR, the `pr-build-images.yaml` workflow builds:
- `ghcr.io/<your-fork>/olares-os:pr-<number>`
- `ghcr.io/<your-fork>/olares-netinstall:pr-<number>`
- Other component images

### 2. Start Test VM

```bash
# Use the test VM container
podman run --rm -it --privileged \
    --device /dev/kvm \
    -v ~/pr-123-test:/vm \
    -e OLARES_REGISTRY=ghcr.io/your-fork \
    -e OLARES_TAG=pr-123 \
    olares-test-vm
```

### 3. Push New Commits

When you push new commits:
1. PR workflow rebuilds images with same tag
2. Next VM boot auto-updates to new images
3. No need to recreate disk or restart container

### 4. Test and Iterate

- Make changes
- Push
- Wait for images to build
- Reboot VM (or it will update on next scheduled check)
- Test

## Tips

### Share Host Container Storage (True Storage Sharing)

The Olares OS uses **podman as the container runtime** (via cri-dockerd), which means
the guest VM uses the same storage format as the host. You can share storage via virtiofs:

```bash
# Share host storage with guest (requires virtiofs support)
podman run --rm -it --privileged \
    --device /dev/kvm \
    -v ~/olares-test-data:/vm \
    -v ~/.local/share/containers/storage:/shared-storage:ro \
    -e VM_SHARE_STORAGE=true \
    -e OLARES_REGISTRY=ghcr.io/myuser \
    -e OLARES_TAG=pr-123 \
    olares-test-vm
```

**How it works:**
1. Host podman storage mounted into test-vm container
2. virtiofs shares `/shared-storage` to guest at `/var/lib/containers/storage`
3. Guest's k3s (via cri-dockerd → podman) uses the shared storage
4. Images already pulled on host are immediately available in guest!

**Benefits:**
- No duplicate image downloads
- Faster VM startup (images already present)
- Less disk space usage

**Notes:**
- Requires matching storage driver (usually `overlay`)
- Guest storage is read-only from shared; writes go to local overlay

### Faster Iteration

For faster iteration during development:

```bash
# SSH into running VM
ssh -p 2222 root@localhost

# Manually trigger update
bootc upgrade

# Reboot to apply
systemctl reboot
```

### Persistent Data

Data in `/vm` is persistent between container restarts:
- `disk.qcow2` - VM disk image
- `cidata/` - Cloud-init configuration
- `cidata.iso` - Cloud-init ISO

### Debugging

```bash
# Inside VM: check bootc status
bootc status

# Inside VM: check update log
cat /var/log/olares-auto-update.log

# Inside VM: check k3s status
systemctl status k3s
kubectl get nodes
kubectl get pods -A
```

### Clean Start

```bash
# Remove disk to start fresh
rm -rf ~/olares-test-data/disk.qcow2

# Next run will create new disk from netinstall
```
