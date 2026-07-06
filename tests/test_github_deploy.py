import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from acte.github_deploy import GitHubDeployError, deploy_package


class FakeGitHubClient:
    def __init__(self, token):
        self.token = token

    def authenticated_login(self):
        return "alice"

    def ensure_repo(self, repo_name, private):
        raise AssertionError("dry run must not create repositories")


class GitHubDeployTests(unittest.TestCase):
    def test_dry_run_uses_authenticated_owner(self):
        with tempfile.TemporaryDirectory() as tmp, patch("acte.github_deploy.GitHubClient", FakeGitHubClient):
            manifest = deploy_package(
                package_dir=Path(tmp),
                repo_name="target-repo",
                token="secret-token",
                expected_owner="alice",
                private=False,
                dry_run=True,
            )
        self.assertEqual(manifest["owner"], "alice")
        self.assertEqual(manifest["remote_url"], "https://github.com/alice/target-repo.git")
        self.assertEqual(manifest["branch"], "master")
        self.assertFalse(manifest["created"])

    def test_expected_owner_mismatch_fails_before_deploy(self):
        with tempfile.TemporaryDirectory() as tmp, patch("acte.github_deploy.GitHubClient", FakeGitHubClient):
            with self.assertRaises(GitHubDeployError):
                deploy_package(
                    package_dir=Path(tmp),
                    repo_name="target-repo",
                    token="secret-token",
                    expected_owner="bob",
                    private=False,
                    dry_run=True,
                )


if __name__ == "__main__":
    unittest.main()
