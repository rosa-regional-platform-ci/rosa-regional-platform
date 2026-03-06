import logging
import os
import re
import subprocess
import sys
from pathlib import Path

PROVISION_TIMEOUT = 3600  # seconds (1 hour); total time for provisioning
TEARDOWN_TIMEOUT = 3600  # seconds (1 hour); total time for teardown

import yaml

from . import TARGET_ENVIRONMENT
from .aws import AWSCredentials
from .git import GitManager
from .pipeline import PipelineMonitor

log = logging.getLogger(__name__)


class EphemeralEnvOrchestrator:
    """Orchestrates an ephemeral environment lifecycle.

    Provision and teardown are independent operations that can run in separate
    processes. They share state via the ci_prefix (which determines branch names,
    pipeline names, and terraform state keys).

    Usage from CI steps:
        # Step 1: provision
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, ci_prefix)
        env.provision()

        # Step 2: run tests (separate process, same ci_prefix)

        # Step 3: teardown
        env = EphemeralEnvOrchestrator(repo, branch, creds_dir, region, ci_prefix)
        env.teardown()
    """

    def __init__(self, repo: str, branch: str, creds_dir: str, region: str, ci_prefix: str):
        self.repo = repo
        self.branch = branch
        self.creds_dir = creds_dir
        self.region = region
        self.ci_prefix = ci_prefix
        self.provisioner_name = f"{ci_prefix}-pipeline-provisioner"
        # TODO: compute deterministic RC/MC pipeline names from rendered config
        # instead of using prefix-based discovery (e.g. {ci_prefix}-regional-pipe, {ci_prefix}-mc01-pipe)
        self.pipeline_prefix = f"{ci_prefix}-"
        self.aws: AWSCredentials | None = None
        self.monitor: PipelineMonitor | None = None
        self.git: GitManager | None = None

    def provision(self):
        """Provision the ephemeral environment (setup + bootstrap + wait for pipelines)."""
        self._setup_aws()

        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git
        git.create_ci_branch(self.ci_prefix)

        # Inject ephemeral environment into config.yaml (not checked into the repo)
        self._inject_ephemeral_config(git)
        git.render_and_push("ci: add ephemeral environment and render deploy files")

        # Bootstrap pipeline provisioner
        self.monitor = PipelineMonitor(self.aws.session)
        self._bootstrap_pipeline_provisioner(git)

        # Wait for provisioning pipelines
        self._wait_for_provision()

    def teardown(self):
        """Tear down a previously provisioned ephemeral environment.

        Can run independently of provision() — reconnects to the existing
        CI branch and pipeline resources using the ci_prefix.
        """
        self._setup_aws()

        # Collect CodeBuild logs before teardown destroys infrastructure.
        # In Prow, teardown runs as a separate step — this captures logs
        # from the provisioning phase that would otherwise be lost.
        self.collect_codebuild_logs()

        git = GitManager(self.creds_dir, self.repo, self.branch)
        self.git = git
        git.checkout_ci_branch(self.ci_prefix)

        self.monitor = PipelineMonitor(self.aws.session)
        self._run_teardown(git)

    def collect_codebuild_logs(self):
        """Download CloudWatch logs for all CodeBuild projects matching our CI prefix.

        Writes each log group to a separate file in ARTIFACT_DIR (set by Prow)
        so they appear in the Prow artifacts UI. Sensitive values (AWS keys,
        session tokens) are redacted before writing.
        """
        artifact_dir = os.environ.get("ARTIFACT_DIR")
        if not artifact_dir:
            log.warning("ARTIFACT_DIR not set — skipping CodeBuild log collection")
            return

        artifact_path = Path(artifact_dir) / "codebuild-logs"
        artifact_path.mkdir(parents=True, exist_ok=True)

        if not self.aws or not self.aws.session:
            log.warning("AWS session not available — skipping log collection")
            return

        logs_client = self.aws.session.client("logs")
        prefix = f"/aws/codebuild/{self.ci_prefix}-"

        try:
            response = logs_client.describe_log_groups(logGroupNamePrefix=prefix)
        except Exception:
            log.exception("Failed to list CloudWatch log groups")
            return

        log_groups = response.get("logGroups", [])
        if not log_groups:
            log.info("No CloudWatch log groups found with prefix '%s'", prefix)
            return

        log.info("Collecting logs from %d CodeBuild log group(s)...", len(log_groups))

        for lg in log_groups:
            group_name = lg["logGroupName"]
            project_name = group_name.rsplit("/", 1)[-1]

            try:
                streams_resp = logs_client.describe_log_streams(
                    logGroupName=group_name,
                    orderBy="LastEventTime",
                    descending=True,
                )
                stream_list = streams_resp.get("logStreams", [])
                if not stream_list:
                    log.info("  %s: no log streams", group_name)
                    continue

                # Reverse so index 0 = oldest (chronological order)
                stream_list.reverse()

                for idx, stream_info in enumerate(stream_list):
                    stream_name = stream_info["logStreamName"]
                    safe_name = f"{project_name}.{idx}.log"
                    out_file = artifact_path / safe_name

                    events = []
                    kwargs = {
                        "logGroupName": group_name,
                        "logStreamName": stream_name,
                        "startFromHead": True,
                    }
                    while True:
                        resp = logs_client.get_log_events(**kwargs)
                        batch = resp.get("events", [])
                        if not batch:
                            break
                        events.extend(batch)
                        next_token = resp.get("nextForwardToken")
                        if next_token == kwargs.get("nextToken"):
                            break
                        kwargs["nextToken"] = next_token

                    lines = [e["message"] for e in events]
                    content = "\n".join(lines)
                    content = _strip_ansi(content)
                    content = _redact_sensitive(content)

                    out_file.write_text(content)
                    log.info("  %s: %d events -> %s", group_name, len(events), out_file)

            except Exception:
                log.exception("  Failed to collect logs from %s", group_name)

        log.info("CodeBuild logs written to %s", artifact_path)

    def _setup_aws(self):
        """Set up AWS credentials and trust policies."""
        log.info("")
        log.info("==========================================")
        log.info("Setup: AWS Credentials")
        log.info("==========================================")

        self.aws = AWSCredentials(self.creds_dir, self.region)
        self.aws.setup_central_account()
        self.aws.setup_target_account_trust("regional")
        self.aws.setup_target_account_trust("management")

    def _inject_ephemeral_config(self, git: GitManager):
        """Inject the ephemeral environment into config.yaml using discovered account IDs."""
        regional_account_id = self.aws.get_target_account_id("regional")
        management_account_id = self.aws.get_target_account_id("management")

        log.info(
            "Injecting ephemeral environment: region=%s, regional=%s, management=%s",
            self.region,
            regional_account_id,
            management_account_id,
        )

        def add_env(config):
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

        add_env(config)

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
        env["NAME_PREFIX"] = git.ci_prefix

        log.info("Executing: %s", bootstrap_script)
        log.info("Env: REPO=%s, BRANCH=%s", git.fork_repo, git.ci_branch)

        sys.stdout.flush()
        sys.stderr.flush()

        try:
            subprocess.run(
                ["/bin/bash", str(bootstrap_script)],
                cwd=git.work_dir,
                env=env,
                stdout=sys.stdout,
                stderr=sys.stderr,
                text=True,
                check=True,
                timeout=PROVISION_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"bootstrap-central-account.sh timed out after {PROVISION_TIMEOUT}s"
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"bootstrap-central-account.sh failed with exit code {e.returncode}. "
                "Check the logs above for the specific shell error."
            )
        log.info("Pipeline provisioner bootstrapped with branch: %s", git.ci_branch)

    def _wait_for_provision(self):
        """Wait for provisioning pipelines to complete."""
        log.info("")
        log.info("==========================================")
        log.info("Provision: Waiting for Pipelines")
        log.info("==========================================")

        # Wait for pipeline-provisioner (newly created, so any execution is ours)
        provisioner_exec_id = self.monitor.wait_for_any_execution(self.provisioner_name)
        self.monitor.wait_for_completion(self.provisioner_name, provisioner_exec_id)

        # Discover RC/MC pipelines by CI prefix, excluding the provisioner itself
        all_pipelines = [
            (name, exec_id)
            for name, exec_id in self.monitor.discover_pipelines(self.pipeline_prefix)
            if name != self.provisioner_name
        ]
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
            self.collect_codebuild_logs()
            raise RuntimeError(f"{failed} pipeline(s) failed during provisioning.")

        log.info("All pipelines completed successfully.")

    def _run_teardown(self, git: GitManager):
        """Tear down infrastructure via GitOps and destroy the pipeline-provisioner."""

        # Phase 1: Infrastructure teardown
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Infrastructure Destroy")
        log.info("==========================================")

        # Snapshot known executions before pushing delete flags
        provisioner_known = self.monitor.get_execution_ids(self.provisioner_name)
        pipeline_known = self.monitor.snapshot_pipeline_executions(self.pipeline_prefix)

        def set_delete_flag(config):
            environments = config.get("environments", {})
            if TARGET_ENVIRONMENT not in environments:
                raise RuntimeError(
                    f"Environment '{TARGET_ENVIRONMENT}' not found in config.yaml "
                    f"(available: {list(environments.keys())})"
                )
            ci_env = environments[TARGET_ENVIRONMENT]
            for rd_name, rd_config in ci_env.get("region_deployments", {}).items():
                if rd_config is None:
                    ci_env["region_deployments"][rd_name] = rd_config = {}
                rd_config["delete"] = True
                for mc_name, mc_config in rd_config.get("management_clusters", {}).items():
                    if mc_config is None:
                        rd_config["management_clusters"][mc_name] = mc_config = {}
                    mc_config["delete"] = True

        git.modify_config(set_delete_flag)

        # Wait for pipeline-provisioner to pick up the change
        provisioner_exec_id = self.monitor.wait_for_new_execution(
            self.provisioner_name, provisioner_known
        )
        self.monitor.wait_for_completion(self.provisioner_name, provisioner_exec_id)

        # Discover and wait for RC/MC pipeline executions (infra destroy)
        teardown_pipelines = [
            (name, exec_id)
            for name, exec_id in self.monitor.discover_pipelines(self.pipeline_prefix, pipeline_known)
            if name != self.provisioner_name
        ]

        for name, exec_id in teardown_pipelines:
            self.monitor.wait_for_completion(name, exec_id)

        # Phase 2: Pipeline teardown
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Pipeline Destroy")
        log.info("==========================================")

        # Snapshot again before pushing delete_pipeline flags
        provisioner_known = self.monitor.get_execution_ids(self.provisioner_name)

        def set_delete_pipeline_flag(config):
            environments = config.get("environments", {})
            if TARGET_ENVIRONMENT not in environments:
                raise RuntimeError(
                    f"Environment '{TARGET_ENVIRONMENT}' not found in config.yaml "
                    f"(available: {list(environments.keys())})"
                )
            ci_env = environments[TARGET_ENVIRONMENT]
            for rd_name, rd_config in ci_env.get("region_deployments", {}).items():
                if rd_config is None:
                    ci_env["region_deployments"][rd_name] = rd_config = {}
                rd_config["delete_pipeline"] = True
                for mc_name, mc_config in rd_config.get("management_clusters", {}).items():
                    if mc_config is None:
                        rd_config["management_clusters"][mc_name] = mc_config = {}
                    mc_config["delete_pipeline"] = True

        git.modify_config(set_delete_pipeline_flag)

        # Wait for pipeline-provisioner to destroy the pipelines
        provisioner_exec_id = self.monitor.wait_for_new_execution(
            self.provisioner_name, provisioner_known
        )
        self.monitor.wait_for_completion(self.provisioner_name, provisioner_exec_id)

        # Phase 3: Destroy pipeline-provisioner via terraform destroy
        log.info("")
        log.info("==========================================")
        log.info("Teardown: Pipeline Provisioner Destroy")
        log.info("==========================================")
        self._destroy_pipeline_provisioner(git)

        log.info("Teardown complete.")

    def _destroy_pipeline_provisioner(self, git: GitManager):
        """Destroy the pipeline-provisioner via terraform destroy."""
        bootstrap_dir = git.work_dir / "terraform" / "config" / "central-account-bootstrap"

        account_id = self.aws.session.client("sts").get_caller_identity()["Account"]
        state_bucket = f"terraform-state-{account_id}"
        state_key = f"{git.ci_prefix}-central-account-bootstrap/terraform.tfstate"

        env = os.environ.copy()
        env.update(self.aws.subprocess_env)

        try:
            subprocess.run(
                [
                    "terraform",
                    "init",
                    "-reconfigure",
                    f"-backend-config=bucket={state_bucket}",
                    f"-backend-config=key={state_key}",
                    f"-backend-config=region={self.region}",
                    "-backend-config=use_lockfile=true",
                ],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )

            # Destroy only the modules we own — the shared CodeStar
            # connection stays in state (harmless, per-CI-run state)
            # and is imported fresh on each apply.
            subprocess.run(
                ["terraform", "destroy", "-auto-approve",
                 "-target=module.pipeline_provisioner",
                 "-target=module.platform_image",
                 f"-var=github_repository={git.fork_repo}"],
                cwd=bootstrap_dir,
                env=env,
                check=True,
                timeout=TEARDOWN_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"Terraform teardown timed out after {TEARDOWN_TIMEOUT}s"
            )
        log.info("Pipeline-provisioner destroyed.")


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


# Patterns that match AWS secrets we don't want in Prow artifacts
_SENSITIVE_PATTERNS = [
    (re.compile(r"(?:AKIA|ASIA)[A-Z0-9]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"(?i)(aws_secret_access_key|secret_key)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(aws_session_token|security_token)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
]


def _redact_sensitive(text: str) -> str:
    for pattern, replacement in _SENSITIVE_PATTERNS:
        text = pattern.sub(replacement, text)
    return text
