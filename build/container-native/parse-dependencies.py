#!/usr/bin/env python3
"""
Parse the container-native dependencies.yaml and generate various outputs.

This script bridges the new container-native format with the existing build system
during the migration period.

Usage:
    python parse-dependencies.py dependencies.yaml --output-format <format>

Formats:
    - bootstrap-list: List of bootstrap binaries to download
    - images-list: List of container images
    - legacy-components: Generate old-style components file for compatibility
    - tool-wrappers: Generate shell wrapper scripts for containerized tools
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

import yaml


@dataclass
class Artifact:
    url: str
    sha256: str = ""


@dataclass
class BootstrapBinary:
    id: str
    version: str
    description: str
    install_path: str
    artifacts: dict[str, Artifact]


@dataclass
class ContainerImage:
    image: str
    description: str = ""
    alias: str | None = None
    replaces: str | None = None
    required: bool = False


@dataclass
class QuadletImage:
    id: str
    image: str
    description: str = ""
    quadlet_file: str = ""


@dataclass
class DependencyManifest:
    name: str
    version: str
    bootstrap: list[BootstrapBinary] = field(default_factory=list)
    images: list[ContainerImage] = field(default_factory=list)
    quadlet: list[QuadletImage] = field(default_factory=list)


def _parse_bootstrap_items(raw_items: list[dict]) -> list[BootstrapBinary]:
    """Parse bootstrap binary entries from the manifest."""
    result: list[BootstrapBinary] = []
    for item in raw_items:
        artifacts: dict[str, Artifact] = {}
        for arch, artifact_data in item.get("artifacts", {}).items():
            artifacts[arch] = Artifact(
                url=artifact_data.get("url", ""),
                sha256=artifact_data.get("sha256", ""),
            )
        result.append(
            BootstrapBinary(
                id=item["id"],
                version=item.get("version", ""),
                description=item.get("description", ""),
                install_path=item.get("installPath", "/usr/local/bin"),
                artifacts=artifacts,
            )
        )
    return result


def _parse_quadlet_items(raw_items: list[dict]) -> list[QuadletImage]:
    """Parse quadlet image entries from the manifest."""
    return [
        QuadletImage(
            id=item["id"],
            image=item["image"],
            description=item.get("description", ""),
            quadlet_file=item.get("quadletFile", ""),
        )
        for item in raw_items
    ]


def _parse_image_items(raw_items: list[dict]) -> list[ContainerImage]:
    """Parse container image entries from the manifest."""
    return [
        ContainerImage(
            image=item["image"],
            description=item.get("description", ""),
            alias=item.get("alias"),
            replaces=item.get("replaces"),
            required=item.get("required", False),
        )
        for item in raw_items
    ]


def parse_manifest(path: Path) -> DependencyManifest:
    """Parse the dependencies.yaml file."""
    with open(path) as f:
        data = yaml.safe_load(f)

    spec = data.get("spec", {})
    metadata = data.get("metadata", {})

    # Support both "bootstrap" and "bootstrap_legacy" keys
    bootstrap_raw = spec.get("bootstrap_legacy", spec.get("bootstrap", []))
    bootstrap = _parse_bootstrap_items(bootstrap_raw)

    quadlet = _parse_quadlet_items(spec.get("quadlet", []))
    images = _parse_image_items(spec.get("images", []))

    return DependencyManifest(
        name=metadata.get("name", "unknown"),
        version=metadata.get("version", "0.0.0"),
        bootstrap=bootstrap,
        images=images,
        quadlet=quadlet,
    )


def output_bootstrap_list(manifest: DependencyManifest, arch: str = "linux/amd64") -> None:
    """Output list of bootstrap binaries for a given architecture."""
    for binary in manifest.bootstrap:
        artifact = binary.artifacts.get(arch)
        if artifact:
            print(f"{binary.id}:{binary.version}:{artifact.url}")


def output_images_list(manifest: DependencyManifest) -> None:
    """Output list of container images."""
    for image in manifest.images:
        print(image.image)


def output_images_with_aliases(manifest: DependencyManifest) -> None:
    """Output images with their aliases (for tool wrappers)."""
    for image in manifest.images:
        if image.alias:
            print(f"{image.alias}={image.image}")


def output_legacy_components(
    manifest: DependencyManifest, arch: str = "linux/amd64"
) -> None:
    """Generate legacy components file format for compatibility."""
    # Format: name,path,amd64_url,arm64_url,id
    for binary in manifest.bootstrap:
        amd64 = binary.artifacts.get("linux/amd64")
        arm64 = binary.artifacts.get("linux/arm64")
        if amd64 and arm64:
            print(
                f"{binary.id}-{binary.version},"
                f"{binary.install_path},"
                f"{amd64.url},"
                f"{arm64.url},"
                f"{binary.id}"
            )


def generate_tool_wrapper(alias: str, image: str) -> str:
    """Generate a shell wrapper script for a containerized tool."""
    return f'''#!/bin/bash
# Auto-generated wrapper for {alias}
# Runs {image} as a container instead of native binary

set -euo pipefail

# Detect container runtime
if command -v podman &>/dev/null; then
    RUNTIME=podman
elif command -v nerdctl &>/dev/null; then
    RUNTIME=nerdctl
elif command -v docker &>/dev/null; then
    RUNTIME=docker
else
    echo "Error: No container runtime found (podman, nerdctl, or docker)" >&2
    exit 1
fi

# For kubectl/helm, mount kubeconfig
MOUNTS=""
if [[ "{alias}" == "kubectl" || "{alias}" == "helm" || "{alias}" == "velero" ]]; then
    KUBECONFIG="${{KUBECONFIG:-$HOME/.kube/config}}"
    if [[ -f "$KUBECONFIG" ]]; then
        MOUNTS="-v $KUBECONFIG:/root/.kube/config:ro"
    fi
fi

# Mount current directory for file access
MOUNTS="$MOUNTS -v $(pwd):/work -w /work"

# Run the container
exec $RUNTIME run --rm -i ${{TTY:+-t}} --net=host $MOUNTS \\
    {image} {alias} "$@"
'''


def output_tool_wrappers(manifest: DependencyManifest, output_dir: Path) -> None:
    """Generate wrapper scripts for all tools with aliases."""
    output_dir.mkdir(parents=True, exist_ok=True)

    for image in manifest.images:
        if image.alias:
            wrapper_path = output_dir / image.alias
            wrapper_content = generate_tool_wrapper(image.alias, image.image)
            wrapper_path.write_text(wrapper_content)
            wrapper_path.chmod(0o755)
            print(f"Generated: {wrapper_path}")


def output_json(manifest: DependencyManifest) -> None:
    """Output manifest as JSON for programmatic consumption."""
    data = {
        "name": manifest.name,
        "version": manifest.version,
        "quadlet": [
            {
                "id": q.id,
                "image": q.image,
                "description": q.description,
                "quadletFile": q.quadlet_file,
            }
            for q in manifest.quadlet
        ],
        "bootstrap": [
            {
                "id": b.id,
                "version": b.version,
                "description": b.description,
                "installPath": b.install_path,
                "artifacts": {
                    arch: {"url": a.url, "sha256": a.sha256}
                    for arch, a in b.artifacts.items()
                },
            }
            for b in manifest.bootstrap
        ],
        "images": [
            {
                "image": i.image,
                "description": i.description,
                "alias": i.alias,
                "replaces": i.replaces,
                "required": i.required,
            }
            for i in manifest.images
        ],
    }
    print(json.dumps(data, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Parse container-native dependencies manifest"
    )
    parser.add_argument("manifest", type=Path, help="Path to dependencies.yaml")
    parser.add_argument(
        "--output-format",
        "-f",
        choices=[
            "bootstrap-list",
            "images-list",
            "images-with-aliases",
            "legacy-components",
            "tool-wrappers",
            "json",
        ],
        default="images-list",
        help="Output format",
    )
    parser.add_argument(
        "--arch",
        default="linux/amd64",
        help="Architecture for binary URLs (default: linux/amd64)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./bin"),
        help="Output directory for tool wrappers",
    )

    args = parser.parse_args()

    if not args.manifest.exists():
        print(f"Error: {args.manifest} not found", file=sys.stderr)
        return 1

    manifest = parse_manifest(args.manifest)

    if args.output_format == "bootstrap-list":
        output_bootstrap_list(manifest, args.arch)
    elif args.output_format == "images-list":
        output_images_list(manifest)
    elif args.output_format == "images-with-aliases":
        output_images_with_aliases(manifest)
    elif args.output_format == "legacy-components":
        output_legacy_components(manifest, args.arch)
    elif args.output_format == "tool-wrappers":
        output_tool_wrappers(manifest, args.output_dir)
    elif args.output_format == "json":
        output_json(manifest)

    return 0


if __name__ == "__main__":
    sys.exit(main())
