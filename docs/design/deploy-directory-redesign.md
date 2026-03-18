# Deploy Directory Redesign

## Principles

1. Every file is named after the **pipeline and step** that consumes it
2. Every file lives under the directory of the **pipeline that consumes it**
3. File changes trigger **only the pipeline that needs to act** on them
4. No file is consumed by multiple pipelines (except `argocd-values-*.yaml` which ArgoCD syncs directly)

## Structure

```
deploy/<env>/
├── region-definitions.json                       # { region_definitions } - env metadata for external processes
│
└── <region>/
    ├── pipeline-provisioner-inputs/
    │   ├── regional-cluster.json                 # { region, account_id, regional_id, delete_pipeline }
    │   └── management-cluster-<mc>.json          # { region, account_id, management_id, delete_pipeline }
    │
    ├── pipeline-regional-cluster-inputs/
    │   └── terraform.json                        # { app_code, service_phase, cost_center, environment,
    │                                             #   region, account_id, alias, enable_bastion,
    │                                             #   regional_id, sector, management_cluster_account_ids,
    │                                             #   delete }
    │
    ├── pipeline-management-cluster-<mc>-inputs/
    │   └── terraform.json                        # { app_code, service_phase, cost_center, environment,
    │                                             #   region, account_id, alias, sector,
    │                                             #   management_id, regional_aws_account_id,
    │                                             #   delete }
    │
    ├── argocd-values-regional-cluster.yaml       # Helm values consumed by ArgoCD ApplicationSet
    ├── argocd-values-management-cluster.yaml     # Helm values consumed by ArgoCD ApplicationSet
    │
    ├── argocd-bootstrap-regional-cluster/        # Directory consumed by bootstrap-argocd.sh ECS task
    │   └── applicationset.yaml
    └── argocd-bootstrap-management-cluster/      # Directory consumed by bootstrap-argocd.sh ECS task
        └── applicationset.yaml
```

## Trigger Map

| Change | Triggers |
| --- | --- |
| `<env>/region-definitions.json` | External processes (not a pipeline trigger) |
| `<region>/pipeline-provisioner-inputs/*.json` | Pipeline provisioner |
| `<region>/pipeline-regional-cluster-inputs/terraform.json` | RC pipeline |
| `<region>/pipeline-management-cluster-<mc>-inputs/terraform.json` | MC pipeline |
| `<region>/argocd-values-*.yaml` | ArgoCD auto-sync |
| `<region>/argocd-bootstrap-*/applicationset.yaml` | No trigger (applied at bootstrap time) |

## Delete Flags

Two distinct delete flags, each in the file consumed by the correct pipeline:

| Flag | Location | Triggers | Effect |
| --- | --- | --- | --- |
| `delete` | `pipeline-regional-cluster-inputs/terraform.json` | RC pipeline | Destroys infrastructure (EKS, VPC, etc.) |
| `delete_pipeline` | `pipeline-provisioner-inputs/regional-cluster.json` | Pipeline provisioner | Destroys the CodePipeline itself |

Same pattern applies for management clusters.

Teardown order: set `delete: true` first (destroy infra), then `delete_pipeline: true` (remove pipeline).

## Migration from Current Structure

| Current Path | New Path |
| --- | --- |
| `<env>/environment.json` | `<env>/region-definitions.json` (region map) + `<region>/pipeline-provisioner-inputs/terraform.json` (domain) |
| `<region>/terraform/regional.json` | Split into: `<region>/pipeline-provisioner-inputs/regional-cluster.json` + `<region>/pipeline-regional-cluster-inputs/terraform.json` |
| `<region>/terraform/management/<mc>.json` | Split into: `<region>/pipeline-provisioner-inputs/management-cluster-<mc>.json` + `<region>/pipeline-management-cluster-<mc>-inputs/terraform.json` |
| `<region>/argocd/regional-cluster-values.yaml` | `<region>/argocd-values-regional-cluster.yaml` |
| `<region>/argocd/management-cluster-values.yaml` | `<region>/argocd-values-management-cluster.yaml` |
| `<region>/argocd/regional-cluster-manifests/` | `<region>/argocd-bootstrap-regional-cluster/` |
| `<region>/argocd/management-cluster-manifests/` | `<region>/argocd-bootstrap-management-cluster/` |

## Config Directory Redesign

### Structure

```
config/
├── defaults.yaml                          # global defaults
│
├── templates/                             # 1-1 with deploy/ output files (Jinja2)
│   ├── pipeline-provisioner-inputs/
│   │   └── terraform.json.j2
│   ├── pipeline-provisioner-inputs-region/
│   │   ├── regional-cluster.json.j2
│   │   └── management-cluster.json.j2
│   ├── pipeline-regional-cluster-inputs/
│   │   └── terraform.json.j2
│   ├── pipeline-management-cluster-inputs/
│   │   └── terraform.json.j2
│   ├── argocd-values-regional-cluster.yaml.j2
│   ├── argocd-values-management-cluster.yaml.j2
│   └── argocd-bootstrap/
│       └── applicationset.yaml.j2
│
├── integration/
│   ├── defaults.yaml                      # environment/sector defaults
│   ├── us-east-1.yaml                     # region deployment values
│   └── us-west-2.yaml
│
├── ci/
│   ├── defaults.yaml
│   └── us-east-1.yaml
│
├── brian/
│   ├── defaults.yaml
│   └── us-east-1.yaml
│
└── cdoan-central/
    ├── defaults.yaml
    └── us-east-2.yaml
```

### Inheritance Chain

```
config/defaults.yaml  →  config/<env>/defaults.yaml  →  config/<env>/<region>.yaml
```

Deep merge at each level, most-specific wins.

### Values Files

**`config/defaults.yaml`** — global defaults inherited by all environments:

```yaml
revision: main
account_id: "ssm:///infra/{{ environment }}/{{ aws_region }}/account_id"
management_cluster_account_id: "ssm:///infra/{{ environment }}/{{ aws_region }}/{{ cluster_prefix }}/account_id"

terraform:
  app_code: infra
  service_phase: dev
  cost_center: "000"
  enable_bastion: false

argocd:
  regional-cluster:
    maestro:
      mqttEndpoint: "xxx.iot.{{ aws_region }}.amazonaws.com"
  management-cluster:
    hypershift:
      oidcStorageS3Bucket:
        name: "hypershift-mc-{{ aws_region }}"
        region: "{{ aws_region }}"
```

**`config/integration/defaults.yaml`** — environment defaults:

```yaml
domain: int0.rosa.devshift.net

terraform:
  enable_bastion: true
```

**`config/integration/us-east-1.yaml`** — region deployment values:

```yaml
management_clusters:
  mc01: {}
```

**`config/cdoan-central/us-east-2.yaml`** — region with explicit overrides:

```yaml
account_id: "754250776154"
management_clusters:
  mc01:
    account_id: "910485845704"
```

### Templates (Jinja2)

Templates map 1-1 to output files. Each template receives the fully-merged values
as its Jinja2 context. Identity variables (`environment`, `aws_region`, `sector`,
`regional_id`) are injected automatically by the render script based on hierarchy
position.

**Example: `templates/pipeline-regional-cluster-inputs/terraform.json.j2`**

```json
{
  "_generated": "DO NOT EDIT - Generated by render.py",
  "app_code": "{{ terraform.app_code }}",
  "service_phase": "{{ terraform.service_phase }}",
  "cost_center": "{{ terraform.cost_center }}",
  "environment": "{{ environment }}",
  "account_id": "{{ account_id }}",
  "region": "{{ aws_region }}",
  "alias": "regional-{{ aws_region }}",
  "enable_bastion": {{ terraform.enable_bastion | tojson }},
  "regional_id": "{{ regional_id }}",
  "sector": "{{ sector }}"{% if management_cluster_account_ids %},
  "management_cluster_account_ids": {{ management_cluster_account_ids | tojson }}{% endif %}{% if delete %},
  "delete": true{% endif %}
}
```

**Example: `templates/pipeline-provisioner-inputs-region/regional-cluster.json.j2`**

```json
{
  "_generated": "DO NOT EDIT - Generated by render.py",
  "region": "{{ aws_region }}",
  "account_id": "{{ account_id }}",
  "regional_id": "{{ regional_id }}"{% if delete_pipeline %},
  "delete_pipeline": true{% endif %}
}
```

### Render Script

The render script becomes a generic template renderer:

1. Load `config/defaults.yaml`
2. Discover environments by scanning `config/*/defaults.yaml`
3. For each environment, discover regions by scanning `config/<env>/<region>.yaml`
4. At each level, deep-merge values: `defaults → env/defaults → region`
5. Inject identity variables (`environment`, `aws_region`, `sector`, `regional_id`)
6. Resolve Jinja2 in values (e.g., `account_id` references `{{ environment }}`)
7. For each template, render with merged context and write to corresponding `deploy/` path

No more per-output-file functions — the template directory structure drives output.
