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
- **Only 2 bootstrap binaries** on host: `k3s` + `cni-plugins`
- Everything else runs as containers
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

## Files

| File | Purpose |
|------|---------|
| `dependencies.yaml` | Single source of truth for all dependencies |
| `parse-dependencies.py` | Tool to parse manifest and generate outputs |
| `Containerfile.installer` | Installer runs as container |
| `Containerfile.olares-os` | Bootc-based OS image with k3s |

## Dependency Categories

### Bootstrap Binaries (Must be on host)
Only 2 binaries needed for container-native k3s mode:
- `k3s` - Lightweight Kubernetes (includes containerd, kubelet, kubectl)
- `cni-plugins` - For Calico networking (k3s has flannel built-in, but Olares uses Calico)

### Container Images (Everything else)
All other tools run as containers:
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

### Phase 4: Bootc OS Image
- Create `Containerfile.olares-os`
- k3s baked into the image (only bootstrap binary needed)
- CNI plugins included for Calico
- Atomic upgrades via `bootc upgrade`

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

| Aspect | Legacy | Container-Native |
|--------|--------|------------------|
| Host binaries | 22+ | **2** (k3s + cni-plugins) |
| Integrity verification | None | SHA256 checksums |
| Multi-arch | Separate URLs | Single manifest |
| Updates | Re-download binary | `bootc upgrade` |
| Offline install | Package all binaries | Package images only |
| Security scanning | Manual | Standard container scanning |
| Deployment modes | k3s OR kubeadm | k3s only (simpler) |
