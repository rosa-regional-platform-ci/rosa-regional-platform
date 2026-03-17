# Break-glass Access SOPs

The break glass SOPs are the last resort of troubleshooting. It requires a JIRA ticket and/or incident to be declared (process TBD).

The general process is

1. Requirement: Bastion is enabled in the RC or MC.
1. Access the AWS account of the RC or MC (`export AWS_PROFILE=...`).
1. Init the remote terraform backend for the environment
   ```bash
   scripts/dev/init-remote-backend.sh <regional | management> <environment>
   ```
1. Follow the SOP.

## Cleanup

After you are done, stop the bastion ECS task to avoid ongoing costs:

```bash
scripts/dev/bastion-tasks-cleanup.sh <regional | management>
```
