#!/usr/bin/env python3
"""
Run Olares test VM from current branch's PR images.

This script:
1. Detects the current git branch
2. Finds the associated PR on GitHub
3. Runs the test VM container with the correct registry/tag

Usage:
    ./run-test-from-pr.py [--dry-run] [--share-storage]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class PRInfo:
    """Information about a GitHub Pull Request."""

    number: int
    owner: str
    repo: str
    head_ref: str
    base_ref: str

    @property
    def registry(self) -> str:
        """GHCR registry path (lowercase required)."""
        return f"ghcr.io/{self.owner.lower()}"

    @property
    def tag(self) -> str:
        """Image tag for this PR."""
        return f"pr-{self.number}"


def get_current_branch() -> str | None:
    """Get the current git branch name."""
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def get_remote_url(remote: str = "origin") -> str | None:
    """Get the URL of a git remote."""
    result = subprocess.run(
        ["git", "remote", "get-url", remote],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def parse_github_url(url: str) -> tuple[str, str] | None:
    """Parse owner/repo from a GitHub URL."""
    # Handle SSH format: git@github.com:owner/repo.git
    if url.startswith("git@github.com:"):
        path = url.replace("git@github.com:", "").replace(".git", "")
        parts = path.split("/")
        if len(parts) == 2:
            return parts[0], parts[1]

    # Handle HTTPS format: https://github.com/owner/repo.git
    if "github.com" in url:
        path = url.split("github.com/")[-1].replace(".git", "")
        parts = path.split("/")
        if len(parts) >= 2:
            return parts[0], parts[1]

    return None


def find_pr_for_branch(branch: str, owner: str, repo: str) -> PRInfo | None:
    """Find a PR associated with the given branch using gh CLI."""
    # Try to find PR where this branch is the head
    result = subprocess.run(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            f"{owner}/{repo}",
            "--head",
            branch,
            "--json",
            "number,headRefName,baseRefName,headRepositoryOwner",
            "--limit",
            "1",
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return None

    try:
        prs = json.loads(result.stdout)
        if not prs:
            return None

        pr = prs[0]
        # The headRepositoryOwner is the fork owner (for PRs from forks)
        pr_owner = pr.get("headRepositoryOwner", {}).get("login", owner)

        return PRInfo(
            number=pr["number"],
            owner=pr_owner,
            repo=repo,
            head_ref=pr["headRefName"],
            base_ref=pr["baseRefName"],
        )
    except (json.JSONDecodeError, KeyError):
        return None


def check_image_exists(image: str) -> bool:
    """Check if a container image exists in the registry."""
    result = subprocess.run(
        ["podman", "manifest", "exists", image],
        capture_output=True,
        text=True,
    )
    # Also try skopeo for remote check
    if result.returncode != 0:
        result = subprocess.run(
            ["skopeo", "inspect", f"docker://{image}"],
            capture_output=True,
            text=True,
        )
    return result.returncode == 0


def build_podman_command(
    pr_info: PRInfo,
    *,
    share_storage: bool = False,
    data_dir: Path | None = None,
    network_mode: str = "tap",
    hostname: str | None = None,
) -> list[str]:
    """Build the podman run command for the test VM."""
    if data_dir is None:
        data_dir = Path.home() / f"olares-pr-{pr_info.number}"

    if hostname is None:
        hostname = f"olares-pr-{pr_info.number}"

    cmd = [
        "podman",
        "run",
        "--rm",
        "-it",
        "--privileged",
        "--device",
        "/dev/kvm",
        "-v",
        f"{data_dir}:/vm",
        "-e",
        f"OLARES_REGISTRY={pr_info.registry}",
        "-e",
        f"OLARES_TAG={pr_info.tag}",
        "-e",
        f"VM_NETWORK_MODE={network_mode}",
        "-e",
        f"VM_HOSTNAME={hostname}",
    ]

    # Port forwarding only needed for user mode or VNC
    if network_mode == "user":
        cmd.extend([
            "-p", "2222:2222",
            "-p", "6443:6443",
            "-p", "8080:8080",
            "-p", "8443:8443",
        ])
    # Always expose VNC
    cmd.extend(["-p", "5900:5900"])

    # Add storage sharing if requested
    if share_storage:
        # Detect rootless vs rootful podman storage
        rootless_storage = Path.home() / ".local/share/containers/storage"
        rootful_storage = Path("/var/lib/containers/storage")

        if rootless_storage.exists():
            storage_path = rootless_storage
        elif rootful_storage.exists():
            storage_path = rootful_storage
        else:
            print(
                "Warning: Could not find podman storage, skipping share",
                file=sys.stderr,
            )
            storage_path = None

        if storage_path:
            cmd.extend(["-v", f"{storage_path}:/shared-storage:ro"])
            cmd.extend(["-e", "VM_SHARE_STORAGE=true"])

    # Add the image
    image = f"{pr_info.registry}/olares-test-vm:{pr_info.tag}"
    cmd.append(image)

    return cmd


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Run Olares test VM from current branch's PR images",
    )
    parser.add_argument(
        "--dry-run",
        "-n",
        action="store_true",
        help="Print the command without running it",
    )
    parser.add_argument(
        "--share-storage",
        "-s",
        action="store_true",
        help="Share host podman storage with the VM",
    )
    parser.add_argument(
        "--data-dir",
        "-d",
        type=Path,
        help="Directory for VM data (default: ~/olares-pr-<N>)",
    )
    parser.add_argument(
        "--pr",
        "-p",
        type=int,
        help="PR number (auto-detected from branch if not specified)",
    )
    parser.add_argument(
        "--owner",
        "-o",
        help="Repository owner (auto-detected if not specified)",
    )
    parser.add_argument(
        "--network",
        choices=["tap", "user"],
        default="tap",
        help="Network mode: tap (VM gets own IP) or user (port forwarding)",
    )
    parser.add_argument(
        "--hostname",
        default=None,
        help="VM hostname (default: olares-pr-<N>)",
    )
    args = parser.parse_args()

    # Get current branch
    branch = get_current_branch()
    if not branch:
        print("Error: Not in a git repository or could not determine branch")
        return 1

    print(f"Current branch: {branch}")

    # Get repository info from remote
    remote_url = get_remote_url()
    if not remote_url:
        print("Error: Could not get remote URL")
        return 1

    parsed = parse_github_url(remote_url)
    if not parsed:
        print(f"Error: Could not parse GitHub URL: {remote_url}")
        return 1

    owner, repo = parsed
    print(f"Repository: {owner}/{repo}")

    # Find PR for this branch
    if args.pr:
        # Manual PR specified
        pr_info = PRInfo(
            number=args.pr,
            owner=args.owner or owner,
            repo=repo,
            head_ref=branch,
            base_ref="main",
        )
    else:
        pr_info = find_pr_for_branch(branch, owner, repo)
        if not pr_info:
            print(f"Error: No PR found for branch '{branch}'")
            print("  Hint: Create a PR or specify --pr NUMBER")
            return 1

    print(f"PR #{pr_info.number}: {pr_info.head_ref} → {pr_info.base_ref}")
    print(f"Registry: {pr_info.registry}")
    print(f"Tag: {pr_info.tag}")
    print(f"Network: {args.network}")
    
    vm_hostname = args.hostname or f"olares-pr-{pr_info.number}"
    if args.network == "tap":
        print(f"VM hostname: {vm_hostname}")
        print(f"  After boot: ssh root@{vm_hostname}")
    else:
        print(f"  After boot: ssh -p 2222 root@localhost")

    # Build the command
    cmd = build_podman_command(
        pr_info,
        share_storage=args.share_storage,
        data_dir=args.data_dir,
        network_mode=args.network,
        hostname=args.hostname,
    )

    # Check if image exists
    image = f"{pr_info.registry}/olares-test-vm:{pr_info.tag}"
    print(f"\nChecking if image exists: {image}")

    if not check_image_exists(image):
        print(f"Warning: Image may not exist yet: {image}")
        print("  The PR workflow may still be building images.")
        print("  Check: https://github.com/{owner}/{repo}/actions")
        if not args.dry_run:
            response = input("Continue anyway? [y/N] ")
            if response.lower() != "y":
                return 1

    # Create data directory
    data_dir = args.data_dir or Path.home() / f"olares-pr-{pr_info.number}"
    if not args.dry_run:
        data_dir.mkdir(parents=True, exist_ok=True)
        print(f"Data directory: {data_dir}")

    # Run or print command
    print("\nCommand:")
    print("  " + " \\\n    ".join(cmd))

    if args.dry_run:
        print("\n(dry run - not executing)")
        return 0

    print("\nStarting test VM...")
    print("=" * 60)

    result = subprocess.run(cmd)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
