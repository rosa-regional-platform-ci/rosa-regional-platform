import json
import logging
import os
import re
import subprocess
import tempfile
import uuid
from pathlib import Path

import yaml

log = logging.getLogger(__name__)


class GitManager:
    """Manages git operations for CI branch lifecycle.

    Creates a CI-owned branch from a source repo/branch, handles commits and
    pushes, and cleans up the branch on exit. Acts as a context manager to
    ensure cleanup always runs.
    """

    def __init__(self, creds_dir: str, repo: str, branch: str):
        self.creds_dir = Path(creds_dir)
        self.source_repo = repo
        self.source_branch = branch
        self.work_dir = None
        self.ci_branch = None
        self.fork_repo = None
        self._tmpdir = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()
        return False

    def _git_token(self) -> str:
        """Read the git token from credentials directory or environment."""
        env_token = os.environ.get("GIT_TOKEN")
        if env_token:
            return env_token
        return (self.creds_dir / "git_token").read_text().strip()

    def _run_git(self, *args, cwd=None, check=True) -> subprocess.CompletedProcess:
        """Run a git command. Stderr flows to the terminal for visibility."""
        cmd = ["git"] + list(args)
        result = subprocess.run(cmd, cwd=cwd or self.work_dir, check=False, stdout=subprocess.PIPE, text=True)
        if check and result.returncode != 0:
            raise RuntimeError(f"git {args[0]} failed (exit {result.returncode})")
        return result

    def _resolve_fork_owner(self, token: str) -> str:
        """Get the GitHub username associated with the git token."""
        import urllib.request

        req = urllib.request.Request(
            "https://api.github.com/user",
            headers={"Authorization": f"token {token}"},
        )
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
        return data["login"]

    def create_ci_branch(self):
        """Clone source repo/branch and create a CI branch.

        Clones from the source (upstream) repo, then adds the token owner's
        fork as a 'ci' remote and pushes the CI branch there.

        Branch naming: <short-hash>-<sanitized-branch>-ci
        """
        short_hash = "dca1ae" # uuid.uuid4().hex[:6]
        sanitized = re.sub(r"[/]", "-", self.source_branch)
        self.ci_branch = f"{short_hash}-{sanitized}-ci"

        token = self._git_token()
        clone_url = f"https://x-access-token:{token}@github.com/{self.source_repo}.git"

        self._tmpdir = tempfile.mkdtemp(prefix="e2e-")
        self.work_dir = Path(self._tmpdir) / "repo"

        log.info("Cloning %s (branch: %s)", self.source_repo, self.source_branch)
        self._run_git(
            "clone", "--branch", self.source_branch, "--single-branch", clone_url, str(self.work_dir),
            cwd=".",
        )

        # Configure git identity
        self._run_git("config", "user.email", "ci-bot@rosa-regional-platform.dev")
        self._run_git("config", "user.name", "ROSA CI Bot")

        # Add the token owner's fork as the push remote
        fork_owner = self._resolve_fork_owner(token)
        repo_name = self.source_repo.split("/")[-1]
        self.fork_repo = f"{fork_owner}/{repo_name}"
        fork_url = f"https://x-access-token:{token}@github.com/{self.fork_repo}.git"
        self._run_git("remote", "add", "ci", fork_url)
        log.info("Push remote: %s (fork of %s)", self.fork_repo, self.source_repo)

        # Create and push CI branch to the fork
        self._run_git("checkout", "-b", self.ci_branch)
        self._run_git("push", "-u", "ci", self.ci_branch)

        log.info("Created CI branch: %s on %s", self.ci_branch, self.fork_repo)

    def push(self, message: str):
        """Stage all changes, commit, and push to the CI branch."""
        self._run_git("add", "-A")

        result = self._run_git("diff", "--cached", "--quiet", check=False)
        if result.returncode == 0:
            log.info("No changes to commit, skipping push")
            return

        self._run_git("commit", "-m", message)
        self._run_git("push", "ci", self.ci_branch)
        log.info("Pushed: %s", message)

    def render_and_push(self, message: str):
        """Run render.py in the work directory, then commit and push."""
        render_script = self.work_dir / "scripts" / "render.py"
        log.info("Running render.py")
        subprocess.run(
            ["uv", "run", str(render_script)],
            cwd=self.work_dir,
            check=True,
        )
        self.push(message)

    def modify_config(self, callback):
        """Load config.yaml, apply callback modifications, render, and push.

        Args:
            callback: A function that receives and modifies the config dict.
        """
        config_path = self.work_dir / "config.yaml"
        with open(config_path) as f:
            config = yaml.safe_load(f)

        callback(config)

        with open(config_path, "w") as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

        self.render_and_push("ci: update config.yaml")

    def cleanup(self):
        """Delete the remote CI branch and clean up the temp directory."""
        if self.ci_branch and self.work_dir and self.work_dir.exists():
            log.info("Cleaning up CI branch: %s", self.ci_branch)
            self._run_git("push", "ci", "--delete", self.ci_branch, check=False)

        if self._tmpdir:
            import shutil

            shutil.rmtree(self._tmpdir, ignore_errors=True)
            self._tmpdir = None
