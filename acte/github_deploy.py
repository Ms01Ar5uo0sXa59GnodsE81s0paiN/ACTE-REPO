from __future__ import annotations

import argparse
import json
import os
import subprocess
import urllib.error
import urllib.request
from urllib.parse import quote
from pathlib import Path
from typing import Any, Dict, Optional

from .foundry import copy_package_for_deepwiki
from .intake import active_target
from .io import write_json


class GitHubDeployError(RuntimeError):
    pass


class GitHubClient:
    def __init__(self, token: str, api_url: str = "https://api.github.com"):
        if not token:
            raise GitHubDeployError("missing GitHub token")
        self.token = token
        self.api_url = api_url.rstrip("/")

    def request(self, method: str, path: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        data = None
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "acte-deployer/1.0",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{self.api_url}{path}", data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise GitHubDeployError(f"GitHub API {method} {path} failed: HTTP {exc.code}: {body}") from exc
        if not body:
            return {}
        parsed = json.loads(body)
        if not isinstance(parsed, dict):
            raise GitHubDeployError("GitHub API response was not an object")
        return parsed

    def authenticated_login(self) -> str:
        user = self.request("GET", "/user")
        login = user.get("login")
        if not isinstance(login, str) or not login:
            raise GitHubDeployError("could not resolve authenticated GitHub login")
        return login

    def ensure_repo(self, owner: str, repo_name: str, private: bool) -> tuple[Dict[str, Any], bool]:
        owner_path = quote(owner, safe="")
        repo_path = quote(repo_name, safe="")
        try:
            return self.request("GET", f"/repos/{owner_path}/{repo_path}"), False
        except GitHubDeployError as exc:
            if "HTTP 404" not in str(exc):
                raise
        payload = {"name": repo_name, "private": private, "auto_init": False}
        return self.request("POST", "/user/repos", payload), True


def run_git(args: list[str], cwd: Path) -> None:
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.replace(os.environ.get("ACTE_DEPLOY_TOKEN", ""), "***")
        stdout = result.stdout.replace(os.environ.get("ACTE_DEPLOY_TOKEN", ""), "***")
        raise GitHubDeployError(f"git command failed: {' '.join(args[:2])}\n{stdout}\n{stderr}")


def ensure_git_commit(package_dir: Path, branch: str) -> None:
    if not (package_dir / ".git").exists():
        run_git(["git", "init"], package_dir)
    run_git(["git", "config", "user.email", "acte-deployer@users.noreply.github.com"], package_dir)
    run_git(["git", "config", "user.name", "ACTE Deployer"], package_dir)
    run_git(["git", "add", "-A"], package_dir)
    status = subprocess.run(["git", "status", "--porcelain"], cwd=package_dir, text=True, capture_output=True, check=True)
    if status.stdout.strip():
        run_git(["git", "commit", "-m", "materialize ACTE target package"], package_dir)
    run_git(["git", "branch", "-M", branch], package_dir)


def set_clean_origin(package_dir: Path, remote_url: str) -> None:
    remotes = subprocess.run(["git", "remote"], cwd=package_dir, text=True, capture_output=True, check=True)
    if "origin" in remotes.stdout.splitlines():
        run_git(["git", "remote", "remove", "origin"], package_dir)
    run_git(["git", "remote", "add", "origin", remote_url], package_dir)


def deploy_package(
    *,
    package_dir: Path,
    repo_name: str,
    token: str,
    expected_owner: str,
    forbidden_owner: str = "",
    private: bool,
    branch: str = "master",
    dry_run: bool = False,
) -> Dict[str, Any]:
    if not package_dir.exists() or not package_dir.is_dir():
        raise GitHubDeployError(f"package directory does not exist: {package_dir}")
    client = GitHubClient(token)
    login = client.authenticated_login()
    if expected_owner and login.lower() != expected_owner.lower():
        raise GitHubDeployError(
            f"ACTE_DEPLOY_TOKEN belongs to {login!r}, not expected owner {expected_owner!r}; refusing deploy"
        )
    if forbidden_owner and login.lower() == forbidden_owner.lower():
        raise GitHubDeployError(
            f"ACTE_DEPLOY_TOKEN belongs to forbidden owner {login!r}; refusing to deploy back into the controller account"
        )
    owner = login
    remote_url = f"https://github.com/{owner}/{repo_name}.git"
    manifest = {
        "schema_version": "acte-github-deploy-v1",
        "owner": owner,
        "repo_name": repo_name,
        "remote_url": remote_url,
        "branch": branch,
        "private": private,
        "package_dir": str(package_dir),
        "dry_run": dry_run,
    }
    if dry_run:
        manifest["created"] = False
        manifest["pushed"] = False
        return manifest

    _, created_repo = client.ensure_repo(owner, repo_name, private=private)
    ensure_git_commit(package_dir, branch)
    push_url = f"https://x-access-token:{token}@github.com/{owner}/{repo_name}.git"
    run_git(["git", "push", "--force", push_url, f"{branch}:{branch}"], package_dir)
    set_clean_origin(package_dir, remote_url)
    manifest["created"] = created_repo
    manifest["pushed"] = True
    return manifest


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Deploy active ACTE target package to the token owner's GitHub account.")
    parser.add_argument("--repo-name", required=True)
    parser.add_argument("--expected-owner", default=os.environ.get("ACTE_EXPECTED_GITHUB_OWNER", ""))
    parser.add_argument("--forbidden-owner", default=os.environ.get("ACTE_FORBIDDEN_GITHUB_OWNER", ""))
    parser.add_argument("--private", action="store_true")
    parser.add_argument("--branch", default="master")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    target = active_target()
    package_dir = copy_package_for_deepwiki(target)
    token = os.environ.get("ACTE_DEPLOY_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    manifest = deploy_package(
        package_dir=package_dir,
        repo_name=args.repo_name,
        token=token,
        expected_owner=args.expected_owner,
        forbidden_owner=args.forbidden_owner,
        private=args.private,
        branch=args.branch,
        dry_run=args.dry_run,
    )
    write_json(target["paths"]["deploy_manifest"], manifest)
    write_json("setup/github_deploy.json", manifest)
    print(f"github_owner={manifest['owner']}")
    print(f"remote_url={manifest['remote_url']}")
    print(f"dry_run={manifest['dry_run']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
