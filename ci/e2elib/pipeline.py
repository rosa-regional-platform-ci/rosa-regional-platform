import logging
import time
from datetime import datetime, timezone

import boto3

from . import POLL_INTERVAL, PIPELINE_TRIGGER_TIMEOUT, PIPELINE_COMPLETION_TIMEOUT, PIPELINE_DISCOVERY_TIMEOUT

log = logging.getLogger(__name__)


class PipelineMonitor:
    """Monitors AWS CodePipeline executions via boto3.

    No manual pipeline starts — everything is triggered via git push (GitOps).
    """

    def __init__(self, session: boto3.Session):
        self.client = session.client("codepipeline")

    def wait_for_auto_trigger(
        self,
        pipeline_name: str,
        after_timestamp: datetime,
        timeout: int = PIPELINE_TRIGGER_TIMEOUT,
    ) -> str:
        """Poll for a new pipeline execution that started after the given timestamp.

        Returns the execution ID once found.
        """
        log.info("Waiting for auto-trigger on pipeline '%s'...", pipeline_name)
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=5,
                )
                for execution in response.get("pipelineExecutionSummaries", []):
                    start_time = execution.get("startTime")
                    if start_time and start_time.replace(tzinfo=timezone.utc) > after_timestamp:
                        exec_id = execution["pipelineExecutionId"]
                        log.info("Pipeline '%s' auto-triggered: %s", pipeline_name, exec_id)
                        return exec_id
            except self.client.exceptions.PipelineNotFoundException:
                pass

            log.info("No new execution on '%s' yet — waiting %ds...", pipeline_name, POLL_INTERVAL)
            time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"Pipeline '{pipeline_name}' did not auto-trigger within {timeout}s")

    def wait_for_completion(
        self,
        pipeline_name: str,
        execution_id: str,
        timeout: int = PIPELINE_COMPLETION_TIMEOUT,
    ):
        """Poll a pipeline execution until it reaches a terminal state."""
        log.info("Watching pipeline '%s' execution '%s'...", pipeline_name, execution_id)
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                response = self.client.get_pipeline_execution(
                    pipelineName=pipeline_name,
                    pipelineExecutionId=execution_id,
                )
                status = response["pipelineExecution"]["status"]
            except Exception:
                log.info("Pipeline '%s' not yet visible — waiting %ds...", pipeline_name, POLL_INTERVAL)
                time.sleep(POLL_INTERVAL)
                continue

            if status == "Succeeded":
                log.info("Pipeline '%s' succeeded.", pipeline_name)
                return
            elif status in ("Failed", "Stopped", "Cancelled"):
                raise RuntimeError(f"Pipeline '{pipeline_name}' finished with status: {status}")
            else:
                log.info("Pipeline '%s' status: %s — waiting %ds...", pipeline_name, status, POLL_INTERVAL)
                time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"Pipeline '{pipeline_name}' did not complete within {timeout}s")

    def discover_pipelines(
        self,
        prefix: str,
        after_timestamp: datetime,
        timeout: int = PIPELINE_DISCOVERY_TIMEOUT,
    ) -> list[tuple[str, str]]:
        """Find pipelines matching prefix with executions after the given timestamp.

        Returns list of (pipeline_name, execution_id) tuples.
        """
        log.info("Discovering pipelines with prefix '%s'...", prefix)
        deadline = time.time() + timeout

        while time.time() < deadline:
            results = []
            response = self.client.list_pipelines()
            for pipeline in response.get("pipelines", []):
                name = pipeline["name"]
                if not name.startswith(prefix):
                    continue

                execs = self.client.list_pipeline_executions(
                    pipelineName=name,
                    maxResults=1,
                )
                for execution in execs.get("pipelineExecutionSummaries", []):
                    start_time = execution.get("startTime")
                    if start_time and start_time.replace(tzinfo=timezone.utc) > after_timestamp:
                        results.append((name, execution["pipelineExecutionId"]))

            if results:
                for name, exec_id in results:
                    log.info("  Found: %s (%s)", name, exec_id)
                return results

            log.info("No pipelines with prefix '%s' found yet — waiting %ds...", prefix, POLL_INTERVAL)
            time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"No pipelines with prefix '{prefix}' found within {timeout}s")
