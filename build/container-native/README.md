# Container-Native Build System

This directory contains the new container-native build system for Olares, designed to minimize host-level binary dependencies by running everything possible as containers.

## Philosophy

**Before (Legacy):**
- Download 22+ binaries directly to host
- Mix of host binaries and container images
- Custom CDN hosting for all artifacts
- Complex multi-architecture binary management
- Supports both k3s and kubeadm deployment modes

**After (Container-Native):**
- **Zero bootstrap binaries** with Quadlet approach (k3s runs as container!)
- Calico CNI plugins installed by DaemonSet (from container images)
- Everything runs as containers
- Standard OCI registries for distribution
- Atomic upgrades via bootc
- k3s mode exclusively (simpler, k3s includes containerd+kubelet+kubectl)

## Why k3s?

The legacy Olares supports two deployment modes:
1. **kubeadm mode**: Requires containerd, runc, kubelet, kubeadm, kubectl, cni-plugins (6+ binaries)
2. **k3s mode**: Requires only k3s + cni-plugins (2 binaries!)

k3s is a single binary that includes:
- `containerd` (container runtime)
- `kubelet` (node agent)
- `kubectl` (CLI, via symlink)
- `crictl`, `ctr` (container tools)

For the container-native build, we use **k3s mode exclusively** because:
- Minimal bootstrap requirements
- Single binary to update
- Proven in production (Rancher, k3os)
- Perfect fit for bootc-based immutable OS

## Quadlet: Zero Bootstrap Binaries

The ultimate container-native approach runs **k3s itself as a container** using Podman Quadlet:

```
quadlet/k3s.container  →  systemd generates  →  k3s.service
```

**Benefits:**
- **Zero binaries** to install on host (only Podman needed, which comes with bootc)
- **Atomic updates**: Change image tag, restart service
- **Systemd native**: `systemctl start/stop/status k3s`
- **Easy rollback**: Revert to previous image version

**How it works:**
1. Quadlet files placed in `/usr/share/containers/systemd/`
2. systemd generator converts `.container` → `.service` at boot
3. k3s runs as privileged container with required mounts

See `quadlet/README.md` for details.

## Files

| File | Purpose |
|------|---------|
| `dependencies.yaml` | Single source of truth for all dependencies |
| `parse-dependencies.py` | Tool to parse manifest and generate outputs |
| `Containerfile.installer` | Installer runs as container |
| `Containerfile.olares-os` | Bootc-based OS image with k3s binary |
| `quadlet/` | **Quadlet units for running k3s as container** |
| `quadlet/k3s.container` | k3s Quadlet unit (zero binaries approach) |
| `quadlet/k3s-data.volume` | Persistent volume for k3s data |

## Dependency Categories

### Quadlet Mode (Fully Container-Native)
- `k3s` runs as a container via Podman Quadlet
- Calico CNI plugins installed by DaemonSet (from `calico/cni` image)
- CLI tools (`kubectl`, `helm`) are wrapper scripts that exec into containers
- **Zero host binaries** - everything comes from container images

### Legacy Binary Mode (Fallback)
For systems without Podman/Quadlet:
- `k3s` binary downloaded to `/usr/local/bin`
- `cni-plugins` downloaded to `/opt/cni/bin`

### Container Images
All components run as containers:
- `rancher/k3s` - k3s itself (in Quadlet mode)
- `calico/*` - Calico networking (CNI plugins installed via DaemonSet)
- `kubectl`, `helm`, `etcdctl` - CLI tools
- `minio`, `redis`, `postgres` - Databases/storage
- `velero`, `restic` - Backup tools
- Kubernetes control plane components

## Usage

### List container images
```bash
python3 parse-dependencies.py dependencies.yaml -f images-list
```

### List bootstrap binaries
```bash
python3 parse-dependencies.py dependencies.yaml -f bootstrap-list --arch linux/amd64
```

### Generate tool wrapper scripts
```bash
python3 parse-dependencies.py dependencies.yaml -f tool-wrappers --output-dir ./bin
```

### Generate legacy components file (migration compatibility)
```bash
python3 parse-dependencies.py dependencies.yaml -f legacy-components
```

### Export as JSON
```bash
python3 parse-dependencies.py dependencies.yaml -f json
```

## Tool Wrappers

Instead of installing binaries, we generate thin shell wrappers that run tools as containers:

```bash
# Example: kubectl wrapper
$ cat bin/kubectl
#!/bin/bash
exec podman run --rm -i -t --net=host \
    -v $HOME/.kube/config:/root/.kube/config:ro \
    bitnami/kubectl:1.33.3 kubectl "$@"
```

This provides:
- No binary installation needed
- Automatic multi-arch support
- Easy version updates (change image tag)
- Consistent environment

## Migration Path

### Phase 1: New Manifest Format ✅
- Create `dependencies.yaml` with bootstrap/container separation
- Tool to parse and generate outputs

### Phase 2: Replace Binaries with Containers
- Update build scripts to use container images
- Generate and install tool wrappers
- Remove binary downloads for replaced tools

### Phase 3: Containerized Installer
- Create `Containerfile.installer`
- Install process runs inside container
- Only bootstrap binaries on host

### Phase 4: Bootc OS Image (Binary Approach)
- Create `Containerfile.olares-os`
- k3s baked into the image (only bootstrap binary needed)
- CNI plugins included for Calico
- Atomic upgrades via `bootc upgrade`

### Phase 5: Quadlet Approach (Zero Binaries) 🆕
- Create `quadlet/k3s.container` unit
- k3s runs as privileged container
- No bootstrap binaries needed on host
- Systemd manages container lifecycle

## Comparison with Legacy

### Legacy `.olares/Olares.yaml`
```yaml
apiVersion: v1
target: prebuilt
output:
  binaries:
    - id: kubectl
      name: kubectl-v1.33.3,pkg/kube/v1.33.3
      amd64: https://dl.k8s.io/.../kubectl
      arm64: https://dl.k8s.io/.../kubectl
  containers:
    - name: registry.k8s.io/kube-apiserver:v1.33.3
```

### New `dependencies.yaml`
```yaml
spec:
  bootstrap:
    # Only 2 binaries needed!
    - id: k3s
      version: "1.33.3+k3s1"
      description: "Includes containerd, kubelet, kubectl"
      artifacts:
        linux/amd64:
          url: https://github.com/k3s-io/k3s/releases/.../k3s
          sha256: abc123...  # Integrity verification!
      symlinks: [kubectl, crictl, ctr]
    - id: cni-plugins
      version: "1.6.2"
      description: "For Calico networking"
  images:
    # helm runs as container instead of host binary
    - image: alpine/helm:3.17.1
      alias: helm
      replaces: "infrastructure/kubernetes helm binary"
```

## Benefits

| Aspect | Legacy | Container-Native (binary) | Container-Native (Quadlet) |
|--------|--------|---------------------------|----------------------------|
| Host binaries | 22+ | 2 (k3s + cni-plugins) | **0** (k3s is a container!) |
| Integrity verification | None | SHA256 checksums | Image signatures |
| Multi-arch | Separate URLs | Single manifest | Single image manifest |
| Updates | Re-download binary | `bootc upgrade` | `podman pull` + restart |
| Offline install | Package all binaries | Package images only | Package images only |
| Security scanning | Manual | Standard scanning | Standard scanning |
| Deployment modes | k3s OR kubeadm | k3s only | k3s only |
| Rollback | Manual | bootc rollback | Image tag revert |
