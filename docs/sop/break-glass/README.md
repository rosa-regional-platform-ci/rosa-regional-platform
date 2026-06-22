# Break-glass Access SOPs

The break glass SOPs are the last resort of troubleshooting. It requires a JIRA ticket and/or incident to be declared (process TBD).

The general process is

1. Requirement: Bastion is enabled in the RC or MC.
1. Connect to the bastion via the appropriate Make target:
   ```bash
   make int-bastion-rc    # or: make int-bastion-mc
   ```
1. Follow the SOP.

## Cleanup

Bastion ECS tasks have a configured stop timeout and will terminate automatically.
To stop them manually, use the AWS Console or CLI to stop the ECS task in the bastion service.
