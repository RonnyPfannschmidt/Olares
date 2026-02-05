# Container-Native Build System

This directory contains the new container-native build system for Olares, designed to minimize host-level binary dependencies by running everything possible as containers.

## Philosophy

**Before (Legacy):**
- Download 22+ binaries directly to host
- Mix of host binaries and container images
- Custom CDN hosting for all artifacts
- Complex multi-architecture binary management

**After (Container-Native):**
- Only 4 bootstrap binaries on host (containerd, runc, CNI, kubelet)
- Everything else runs as containers
- Standard OCI registries for distribution
- Atomic upgrades via bootc (future)

## Files

| File | Purpose |
|------|---------|
| `dependencies.yaml` | Single source of truth for all dependencies |
| `parse-dependencies.py` | Tool to parse manifest and generate outputs |
| `Containerfile.installer` | (TODO) Installer runs as container |
| `Containerfile.olares-os` | (TODO) Bootc-based OS image |

## Dependency Categories

### Bootstrap Binaries (Must be on host)
These bootstrap the container runtime - you need them to run containers:
- `containerd` - Container runtime daemon
- `runc` - OCI runtime
- `cni-plugins` - Container networking
- `kubelet` - Kubernetes node agent (or `k3s` as alternative)

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
- k3s pre-installed in image
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
    # Only truly required host binaries
    - id: kubelet
      version: "1.33.3"
      artifacts:
        linux/amd64:
          url: https://dl.k8s.io/.../kubelet
          sha256: abc123...  # Integrity verification!
  images:
    # kubectl is now a container
    - image: bitnami/kubectl:1.33.3
      alias: kubectl
      replaces: "infrastructure/kubernetes kubectl binary"
```

## Benefits

| Aspect | Legacy | Container-Native |
|--------|--------|------------------|
| Host binaries | 22+ | 4 |
| Integrity verification | None | SHA256 checksums |
| Multi-arch | Separate URLs | Single manifest |
| Updates | Re-download binary | `podman pull` |
| Offline install | Package all binaries | Package images only |
| Security scanning | Manual | Standard container scanning |
