import logging
import os
import subprocess
import sys
from datetime import datetime, timezone

import yaml

from . import TARGET_ENVIRONMENT
from .aws import AWSCredentials
from .git import GitManager
from .pipeline import PipelineMonitor

log = logging.getLogger(__name__)


class E2EOrchestrator:
    """Main orchestration logic for the full e2e lifecycle."""

    def __init__(self, repo: str, branch: str, creds_dir: str, region: str):
        self.repo = repo
        self.branch = branch
        self.creds_dir = creds_dir
        self.region = region
        self.aws: AWSCredentials | None = None
        self.monitor: PipelineMonitor | None = None
        self.git = None
        self.provision_start = None

    def run(self):
        """Run the full e2e lifecycle: provision -> test -> teardown."""
        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git

        # Phase 1: Setup
        self._setup_aws()
        git.create_ci_branch()

        # Inject e2e environment into config.yaml (not checked into the repo)
        self._inject_e2e_config(git)
        git.render_and_push("ci: add e2e environment and render deploy files")

        # Bootstrap pipeline provisioner
        self.monitor = PipelineMonitor(self.aws.session)
        self.provision_start = datetime.now(timezone.utc)
        self._bootstrap_pipeline_provisioner(git)

        # Teardown must run even if provision/test fails, to clean up infrastructure
        try:
            # Phase 2: Provision via GitOps
            self._provision(git)

            # Phase 3: Test (placeholder)
            self._test()
        finally:
            # Phase 4: Teardown (GitOps-driven)
            self._teardown(git)

    def _setup_aws(self):
        """Set up AWS credentials and trust policies."""
        log.info("")
        log.info("==========================================")
        log.info("Phase 1: Setup")
        log.info("==========================================")

        self.aws = AWSCredentials(self.creds_dir, self.region)
        self.aws.setup_central_account()
        self.aws.setup_target_account_trust("regional")
        self.aws.setup_target_account_trust("management")

    def _inject_e2e_config(self, git: GitManager):
        """Inject the e2e environment into config.yaml using discovered account IDs."""
        regional_account_id = self.aws.get_target_account_id("regional")
        management_account_id = self.aws.get_target_account_id("management")

        log.info(
            "Injecting e2e environment: region=%s, regional=%s, management=%s",
            self.region,
            regional_account_id,
            management_account_id,
        )

        def add_e2e_env(config):
            config.setdefault("environments", {})[TARGET_ENVIRONMENT] = {
                "region_deployments": {
                    self.region: {
                        "account_id": regional_account_id,
                        "management_clusters": {
                            "mc01": {
                                "account_id": management_account_id,
                            },
                        },
                    },
                },
            }

        config_path = git.work_dir / "config.yaml"
        with open(config_path) as f:
            config = yaml.safe_load(f)

        add_e2e_env(config)

        with open(config_path, "w") as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    def _bootstrap_pipeline_provisioner(self, git: GitManager):
        """Bootstrap the pipeline-provisioner pointing at the CI branch."""
        log.info("")
        log.info("==========================================")
        log.info("Bootstrapping Pipeline Provisioner")
        log.info("==========================================")

        bootstrap_script = git.work_dir / "scripts" / "bootstrap-central-account.sh"

        if not bootstrap_script.exists():
            raise FileNotFoundError(f"Bootstrap script not found at: {bootstrap_script}")

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)
        env["GITHUB_REPOSITORY"] = git.fork_repo
        env["GITHUB_BRANCH"] = git.ci_branch
        env["TARGET_ENVIRONMENT"] = TARGET_ENVIRONMENT

        log.info("Executing: %s", bootstrap_script)
        log.info("Env: REPO=%s, BRANCH=%s", git.fork_repo, git.ci_branch)

        sys.stdout.flush()
        sys.stderr.flush()

        process = subprocess.Popen(
            ["/bin/bash", str(bootstrap_script)],
            cwd=git.work_dir,
            env=env,
            stdout=sys.stdout,
            stderr=sys.stderr,
            text=True,
        )
        process.wait()

        if process.returncode != 0:
            raise RuntimeError(
                f"bootstrap-central-account.sh failed with exit code {process.returncode}. "
                "Check the logs above for the specific shell error."
            )
        log.info("Pipeline provisioner bootstrapped with branch: %s", git.ci_branch)

    def _provision(self, git: GitManager):
        """Provision infrastructure via GitOps (push config, wait for pipelines)."""
        log.info("")
        log.info("==========================================")
        log.info("Phase 2: Provision via GitOps")
        log.info("==========================================")

        # Wait for pipeline-provisioner to auto-trigger
        provisioner_exec_id = self.monitor.wait_for_auto_trigger(
            "pipeline-provisioner",
            self.provision_start,
        )
        self.monitor.wait_for_completion("pipeline-provisioner", provisioner_exec_id)

        # Discover and wait for RC/MC pipelines
        rc_pipelines = self.monitor.discover_pipelines("rc-pipe-", self.provision_start)
        mc_pipelines = self.monitor.discover_pipelines("mc-pipe-", self.provision_start)

        all_pipelines = rc_pipelines + mc_pipelines
        if not all_pipelines:
            raise RuntimeError("No RC/MC pipelines found after provisioner completed.")

        failed = 0
        for name, exec_id in all_pipelines:
            try:
                self.monitor.wait_for_completion(name, exec_id)
            except (RuntimeError, TimeoutError) as e:
                log.error("Pipeline failed: %s", e)
                failed += 1

        if failed > 0:
            raise RuntimeError(f"{failed} pipeline(s) failed during provisioning.")

        log.info("All pipelines completed successfully.")

    def _test(self):
        """Run the testing suite (placeholder for future integration)."""
        log.info("")
        log.info("==========================================")
        log.info("Phase 3: Test (placeholder)")
        log.info("==========================================")
        log.info("Testing suite not yet integrated — skipping.")

    def _teardown(self, git: GitManager):
        """Tear down infrastructure via GitOps and destroy the pipeline-provisioner."""

        # Phase 4a: Infrastructure teardown
        log.info("")
        log.info("==========================================")
        log.info("Phase 4a: Infrastructure Teardown")
        log.info("==========================================")

        teardown_start = datetime.now(timezone.utc)

        def set_delete_flag(config):
            e2e_env = config.get("environments", {}).get(TARGET_ENVIRONMENT, {})
            for rd_name, rd_config in e2e_env.get("region_deployments", {}).items():
                if rd_config is None:
                    e2e_env["region_deployments"][rd_name] = rd_config = {}
                rd_config["delete"] = True
                for mc_name, mc_config in rd_config.get("management_clusters", {}).items():
                    if mc_config is None:
                        rd_config["management_clusters"][mc_name] = mc_config = {}
                    mc_config["delete"] = True

        git.modify_config(set_delete_flag)

        # Wait for pipeline-provisioner to pick up the change
        provisioner_exec_id = self.monitor.wait_for_auto_trigger(
            "pipeline-provisioner", teardown_start
        )
        self.monitor.wait_for_completion("pipeline-provisioner", provisioner_exec_id)

        # Discover and wait for RC/MC pipeline executions (infra destroy)
        rc_pipelines = self.monitor.discover_pipelines("rc-pipe-", teardown_start)
        mc_pipelines = self.monitor.discover_pipelines("mc-pipe-", teardown_start)

        # Wait for MC pipelines first (destroy MCs before RC)
        for name, exec_id in mc_pipelines:
            self.monitor.wait_for_completion(name, exec_id)

        for name, exec_id in rc_pipelines:
            self.monitor.wait_for_completion(name, exec_id)

        # Phase 4b: Pipeline teardown
        log.info("")
        log.info("==========================================")
        log.info("Phase 4b: Pipeline Teardown")
        log.info("==========================================")

        pipeline_teardown_start = datetime.now(timezone.utc)

        def set_delete_pipeline_flag(config):
            e2e_env = config.get("environments", {}).get(TARGET_ENVIRONMENT, {})
            for rd_name, rd_config in e2e_env.get("region_deployments", {}).items():
                if rd_config is None:
                    e2e_env["region_deployments"][rd_name] = rd_config = {}
                rd_config["delete_pipeline"] = True
                for mc_name, mc_config in rd_config.get("management_clusters", {}).items():
                    if mc_config is None:
                        rd_config["management_clusters"][mc_name] = mc_config = {}
                    mc_config["delete_pipeline"] = True

        git.modify_config(set_delete_pipeline_flag)

        # Wait for pipeline-provisioner to destroy the pipelines
        provisioner_exec_id = self.monitor.wait_for_auto_trigger(
            "pipeline-provisioner", pipeline_teardown_start
        )
        self.monitor.wait_for_completion("pipeline-provisioner", provisioner_exec_id)

        # Phase 5: Destroy pipeline-provisioner via terraform destroy
        log.info("Destroying pipeline-provisioner...")
        self._destroy_pipeline_provisioner(git)

        log.info("Teardown complete.")

    def _destroy_pipeline_provisioner(self, git: GitManager):
        """Destroy the pipeline-provisioner via terraform destroy."""
        bootstrap_dir = git.work_dir / "terraform" / "config" / "central-account-bootstrap"

        account_id = self.aws.session.client("sts").get_caller_identity()["Account"]
        state_bucket = f"terraform-state-{account_id}"

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)

        subprocess.run(
            [
                "terraform",
                "init",
                "-reconfigure",
                f"-backend-config=bucket={state_bucket}",
                "-backend-config=key=central-account-bootstrap/terraform.tfstate",
                f"-backend-config=region={self.region}",
                "-backend-config=use_lockfile=true",
            ],
            cwd=bootstrap_dir,
            env=env,
            check=True,
        )

        subprocess.run(
            ["terraform", "destroy", "-auto-approve"],
            cwd=bootstrap_dir,
            env=env,
            check=True,
        )
        log.info("Pipeline-provisioner destroyed.")
