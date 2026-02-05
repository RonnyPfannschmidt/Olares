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


@dataclass
class WorkflowRun:
    """Information about a GitHub Actions workflow run."""

    id: int
    status: str  # queued, in_progress, completed
    conclusion: str | None  # success, failure, cancelled, etc.
    name: str
    html_url: str
    created_at: str
    jobs: list[dict]


def get_pr_workflow_runs(owner: str, repo: str, pr_number: int) -> list[WorkflowRun]:
    """Get workflow runs for a PR."""
    # Get the head SHA for this PR
    result = subprocess.run(
        [
            "gh", "pr", "view", str(pr_number),
            "--repo", f"{owner}/{repo}",
            "--json", "headRefOid",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []

    try:
        pr_data = json.loads(result.stdout)
        head_sha = pr_data.get("headRefOid", "")
    except json.JSONDecodeError:
        return []

    # Get workflow runs for this commit
    result = subprocess.run(
        [
            "gh", "run", "list",
            "--repo", f"{owner}/{repo}",
            "--commit", head_sha,
            "--json", "databaseId,status,conclusion,name,url,createdAt",
            "--limit", "10",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []

    try:
        runs_data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    runs = []
    for run in runs_data:
        # Get jobs for this run
        jobs_result = subprocess.run(
            [
                "gh", "run", "view", str(run["databaseId"]),
                "--repo", f"{owner}/{repo}",
                "--json", "jobs",
            ],
            capture_output=True,
            text=True,
        )
        jobs = []
        if jobs_result.returncode == 0:
            try:
                jobs_data = json.loads(jobs_result.stdout)
                jobs = jobs_data.get("jobs", [])
            except json.JSONDecodeError:
                pass

        runs.append(WorkflowRun(
            id=run["databaseId"],
            status=run.get("status", "unknown"),
            conclusion=run.get("conclusion"),
            name=run.get("name", "unknown"),
            html_url=run.get("url", ""),
            created_at=run.get("createdAt", ""),
            jobs=jobs,
        ))

    return runs


def show_workflow_status(owner: str, repo: str, pr_number: int) -> tuple[bool, str | None]:
    """Show the status of PR workflow runs. Returns (ready, status)."""
    print("\nChecking GitHub Actions status...")
    
    runs = get_pr_workflow_runs(owner, repo, pr_number)
    
    # Filter to PR Build Images workflow
    image_runs = [r for r in runs if "PR Build" in r.name or "build" in r.name.lower()]
    
    if not image_runs:
        print("  No image build workflows found for this PR")
        print("  The workflow may not have triggered yet.")
        return False, "no_workflow"
    
    latest_run = image_runs[0]
    
    # Status symbols
    status_symbols = {
        "completed": "✅" if latest_run.conclusion == "success" else "❌",
        "in_progress": "🔄",
        "queued": "⏳",
    }
    symbol = status_symbols.get(latest_run.status, "❓")
    
    print(f"\n  {symbol} {latest_run.name}")
    print(f"     Status: {latest_run.status}", end="")
    if latest_run.conclusion:
        print(f" ({latest_run.conclusion})")
    else:
        print()
    print(f"     URL: {latest_run.html_url}")
    
    # Show job details if in progress
    if latest_run.status == "in_progress" and latest_run.jobs:
        print("\n  Jobs:")
        for job in latest_run.jobs:
            job_status = job.get("status", "unknown")
            job_conclusion = job.get("conclusion")
            job_name = job.get("name", "unknown")
            
            if job_status == "completed":
                job_symbol = "✅" if job_conclusion == "success" else "❌"
            elif job_status == "in_progress":
                job_symbol = "🔄"
            elif job_status == "queued":
                job_symbol = "⏳"
            else:
                job_symbol = "  "
            
            print(f"    {job_symbol} {job_name}")
    
    # Check if images should be ready
    if latest_run.status == "completed" and latest_run.conclusion == "success":
        print("\n  ✅ Images should be ready!")
        return True, "success"
    elif latest_run.status == "completed":
        print(f"\n  ❌ Build failed: {latest_run.conclusion}")
        return False, "failed"
    else:
        print("\n  ⏳ Build in progress...")
        return False, "in_progress"


def wait_for_workflow(owner: str, repo: str, pr_number: int) -> bool:
    """Wait for workflow to complete. Returns True if successful."""
    import time
    
    print("\nWaiting for workflow to complete...")
    print("Press Ctrl+C to stop waiting\n")
    
    poll_interval = 30  # seconds
    max_wait = 3600  # 1 hour
    elapsed = 0
    
    try:
        while elapsed < max_wait:
            ready, status = show_workflow_status(owner, repo, pr_number)
            
            if ready:
                return True
            elif status == "failed":
                return False
            elif status == "no_workflow":
                print(f"\nWaiting for workflow to start... (retry in {poll_interval}s)")
            else:
                print(f"\nWaiting... (retry in {poll_interval}s)")
            
            time.sleep(poll_interval)
            elapsed += poll_interval
            print("\n" + "=" * 50)
        
        print(f"\nTimeout after {max_wait}s")
        return False
    except KeyboardInterrupt:
        print("\n\nStopped waiting.")
        return False


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
        "--pull=always",  # Always pull latest image
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
    parser.add_argument(
        "--wait",
        "-w",
        action="store_true",
        help="Wait for workflow to complete before starting VM",
    )
    parser.add_argument(
        "--status-only",
        action="store_true",
        help="Only show workflow status, don't start VM",
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

    # Check workflow status and if image exists
    image = f"{pr_info.registry}/olares-test-vm:{pr_info.tag}"
    
    images_ready, status = show_workflow_status(owner, repo, pr_info.number)
    
    # If --status-only, just show status and exit
    if args.status_only:
        return 0 if images_ready else 1
    
    # If --wait, wait for workflow to complete
    if args.wait and not images_ready and status == "in_progress":
        images_ready = wait_for_workflow(owner, repo, pr_info.number)
        if not images_ready:
            print("\nWorkflow did not complete successfully.")
            return 1
    
    print(f"\nChecking if image exists: {image}")
    image_exists = check_image_exists(image)
    
    if image_exists:
        print("  ✅ Image found!")
    elif images_ready:
        print("  ⚠️  Workflow succeeded but image not found (may need to wait for registry)")
    else:
        print("  ❌ Image not found")
        if not args.dry_run:
            print("\nOptions:")
            print("  1. Run with --wait to wait for workflow")
            print("  2. Continue anyway (VM will fail to pull image)")
            print(f"  3. Check: https://github.com/{owner}/{repo}/actions")
            response = input("\nContinue anyway? [y/N] ")
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
