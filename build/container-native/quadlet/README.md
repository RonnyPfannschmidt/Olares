# Quadlet Units for Olares OS

This directory contains Podman Quadlet unit files for running Olares components as systemd-managed containers.

## What is Quadlet?

Quadlet is a systemd generator built into Podman (4.4+) that converts declarative `.container`, `.volume`, `.network` files into systemd service units. This provides:

- **Systemd integration**: Start/stop/restart with `systemctl`
- **Boot persistence**: Containers start automatically on boot
- **Dependency management**: Define service dependencies
- **Logging**: Automatic journald integration
- **Health checks**: Built-in health monitoring

## Files

| File | Description |
|------|-------------|
| `k3s.container` | k3s Kubernetes server as a container |
| `k3s-data.volume` | Persistent storage for k3s data |

## Installation in bootc Image

In the `Containerfile.olares-os`, copy quadlet files to the systemd search path:

```dockerfile
# Copy quadlet units for containerized k3s
COPY quadlet/*.container /usr/share/containers/systemd/
COPY quadlet/*.volume /usr/share/containers/systemd/
```

The quadlet generator runs automatically during boot and creates the corresponding systemd services.

## Usage

After boot, the services are managed via systemctl:

```bash
# Check k3s status
systemctl status k3s

# View logs
journalctl -u k3s -f

# Restart k3s
systemctl restart k3s

# Stop k3s
systemctl stop k3s
```

## Why Containerized k3s?

Running k3s as a container instead of a binary provides:

1. **Zero bootstrap binaries**: No binaries to install on the host
2. **Atomic updates**: Update k3s by changing the image tag
3. **Easy rollback**: Revert to previous image version
4. **Consistent environment**: Same behavior across architectures
5. **Security scanning**: Standard container image scanning works

## k3s Container Requirements

The k3s container requires privileged mode and specific mounts:

```
privileged: true           # Full Kubernetes functionality
tmpfs: /run, /var/run      # Runtime directories
ulimits: nproc=65535       # Process limits
         nofile=65535      # File descriptor limits
volume: /var/lib/rancher/k3s  # Persistent data
```

These are all configured in `k3s.container`.

## Comparison: Binary vs Container

| Aspect | Binary (current) | Quadlet Container |
|--------|-----------------|-------------------|
| Bootstrap binaries | k3s + cni-plugins | **None** |
| Update mechanism | Download new binary | `podman pull` |
| Systemd integration | Custom unit file | Auto-generated |
| Rollback | Manual | Image tag revert |
| Multi-arch | Separate downloads | Single manifest |

## Testing Locally

You can test the quadlet files without bootc:

```bash
# Copy to user quadlet directory
mkdir -p ~/.config/containers/systemd/
cp *.container *.volume ~/.config/containers/systemd/

# Reload systemd to generate services
systemctl --user daemon-reload

# Check generated service
systemctl --user cat k3s.service

# Start (requires root for privileged container)
# For testing, use: sudo podman run ... (see docker-compose in k3s repo)
```

## References

- [Podman Quadlet man page](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [k3s Docker documentation](https://docs.k3s.io/advanced#running-k3s-in-docker)
- [bootc documentation](https://containers.github.io/bootc/)
