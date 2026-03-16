# Config Directory

Configuration for all environments and region deployments. The render script
(`scripts/render.py`) reads these files and generates the deploy/ directory.

## File Layout

```
config/
  defaults.config.yaml            # Base config inherited by all environments
  environments/
    <env-name>.config.yaml        # Per-environment overrides (e.g., integration, ci)
```

## Inheritance

All fields are deep-merged through the hierarchy, most-specific wins:

```
defaults  ->  environment  ->  sector  ->  region_deployment
```

Only **structural keys** are excluded from inheritance (they define the
hierarchy itself, not configuration):

- `region_deployments`
- `management_clusters`
- `sectors`

Everything else -- `terraform_vars`, `values`, `environment`, `account_id`,
`revision`, or any new field you add -- inherits automatically. No changes to
`render.py` are needed when adding new inheritable fields.

## Jinja2 Templates

All string values are Jinja2-processed **after** the full merge chain resolves.

| Variable               | Source                      | Example              |
| ---------------------- | --------------------------- | -------------------- |
| `{{ environment }}`    | environment dict key        | `"integration"`      |
| `{{ aws_region }}`     | region_deployment dict key  | `"us-east-1"`        |
| `{{ account_id }}`     | resolved account_id         | `"ssm:///infra/..."` |
| `{{ cluster_prefix }}` | management_cluster dict key | `"mc01"`             |

`account_id` is resolved (including its own Jinja2) **before** `terraform_vars`
and `values`, so `{{ account_id }}` in those sections gets the final value.

`cluster_prefix` is only available inside management_cluster entries.

## Output

Running `scripts/render.py` generates:

- **`deploy/<env>/environment.json`** -- from `environment`
  - Consumer: `provision-pipelines.sh`
  - Environment-level metadata (e.g. `domain` for DNS hosted zone
    creation). Also contains auto-generated `region_definitions` map.
- **`deploy/<env>/<region>/terraform/regional.json`** -- from `terraform_vars`
  - Consumer: Terraform (via CodePipeline)
  - Input variables for regional cluster infrastructure provisioning.
- **`deploy/<env>/<region>/terraform/management/<mc>.json`** -- from `management_clusters`
  - Consumer: Terraform (via CodePipeline)
  - Input variables for management cluster provisioning. Inherits
    `terraform_vars` as base, with MC-specific overrides.
- **`deploy/<env>/<region>/argocd/regional-cluster-values.yaml`** -- from `values.regional-cluster`
  - Consumer: ArgoCD ApplicationSet
  - Helm values overrides for regional cluster applications.
- **`deploy/<env>/<region>/argocd/management-cluster-values.yaml`** -- from `values.management-cluster`
  - Consumer: ArgoCD ApplicationSet
  - Helm values overrides for management cluster applications.
- **`deploy/<env>/<region>/argocd/<cluster-type>-manifests/applicationset.yaml`** -- from `revision`
  - Consumer: ArgoCD
  - ApplicationSet manifest; pins git revision when `revision` is a commit hash.

## Examples

### defaults.config.yaml

Defines base values inherited by every environment:

```yaml
revision: main
account_id: "ssm:///infra/{{ environment }}/{{ aws_region }}/account_id"
management_cluster_account_id: "ssm:///infra/{{ environment }}/{{ aws_region }}/{{ cluster_prefix }}/account_id"
terraform_vars:
  app_code: "infra"
  environment: "{{ environment }}"
  account_id: "{{ account_id }}"
  region: "{{ aws_region }}"
values:
  regional-cluster:
    maestro:
      mqttEndpoint: "xxx.iot.{{ aws_region }}.amazonaws.com"
```

### environments/integration.config.yaml

Minimal -- inherits almost everything from defaults:

```yaml
environment:
  domain: int0.rosa.devshift.net

region_deployments:
  us-east-1:
    management_clusters:
      mc01: {}
```

### environments/dev.config.yaml (with overrides)

Override terraform_vars at the environment level, explicit account IDs at the
region deployment level:

```yaml
terraform_vars:
  enable_bastion: true

region_deployments:
  us-east-2:
    account_id: "754250776154"
    management_clusters:
      mc01:
        account_id: "910485845704"
```

### Sectors (multi-sector environments)

For environments with multiple sectors, nest region_deployments under `sectors:`:

```yaml
sectors:
  sector-a:
    terraform_vars:
      service_phase: "prod"
    region_deployments:
      us-east-1:
        management_clusters:
          mc01: {}
  sector-b:
    region_deployments:
      us-west-2:
        management_clusters:
          mc01: {}
```
