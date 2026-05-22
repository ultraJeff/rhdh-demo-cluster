# Azure Pipelines Agent

Self-hosted Azure Pipelines agent running on OpenShift, enabling Azure DevOps pipelines to execute builds against the cluster.

## Architecture

```
Azure DevOps (dev.azure.com/jefrfranklin)
  └── a-project
        └── "OpenShift Pool" (self-hosted agent pool)
              └── azure-pipelines-agent pod (azure-pipelines namespace)
```

## Prerequisites

- OpenShift cluster with `oc` CLI logged in as cluster-admin
- Azure DevOps organization with a self-hosted agent pool created
- Personal Access Token (PAT) with **Agent Pools (Read & manage)** scope

## Setup

### 1. Create the secret

```bash
cp secrets/agent-secrets.yaml.example secrets/agent-secrets.yaml
# Edit secrets/agent-secrets.yaml with your values:
#   VSTS_ACCOUNT: your ADO org name
#   VSTS_TOKEN: your PAT
#   VSTS_POOL: your agent pool name
```

### 2. Grant the anyuid SCC

The agent container needs to write to `/vsts/.token` at startup, which requires running as a non-arbitrary UID:

```bash
oc apply -f secrets/agent-secrets.yaml
oc apply -k .
oc adm policy add-scc-to-user anyuid -z azure-pipelines-agent -n azure-pipelines
oc rollout restart deployment/azure-pipelines-agent -n azure-pipelines
```

### 3. Verify

```bash
# Pod should be Running
oc get pods -n azure-pipelines

# Check agent logs for "Listening for Jobs"
oc logs -l app=azure-pipelines-agent -n azure-pipelines

# Verify agent appears online in ADO
az pipelines agent list --pool-id <pool-id> --organization https://dev.azure.com/<org> -o table
```

## Scaling

```bash
oc scale deployment/azure-pipelines-agent -n azure-pipelines --replicas=3
```

## Cleanup

```bash
oc delete -k .
oc delete -f secrets/agent-secrets.yaml
```

## RHDH Integration

### ADO credentials for RHDH

The `ado-credentials` secret in the `rhdh` namespace provides the PAT to the RHDH backend plugins and proxy:

```bash
cp secrets/ado-rhdh-secrets.yaml.example secrets/ado-rhdh-secrets.yaml
# Edit with your PAT values, then:
oc apply -f secrets/ado-rhdh-secrets.yaml
```

### Deploy namespace setup

The pipeline deploys apps to namespaces on OpenShift. The agent service account needs permissions:

```bash
oc create namespace <target-namespace>
oc adm policy add-role-to-user admin system:serviceaccount:azure-pipelines:azure-pipelines-agent -n <target-namespace>
```

### Software templates

Templates live on the cluster's GitLab at `rhdh/backstage-templates`:
- **azure-devops-nodejs-app** — Scaffolds a Node.js app, creates an ADO repo + pipeline, triggers the first build, and registers in RHDH catalog
- **trigger-azure-pipeline** — Triggers a pipeline run for an existing component (hosted on GitHub at `ultraJeff/rhdh-ado-bootstrap`)

The template contains cluster-specific values (Dev Spaces URL). Use `template.yaml.example` as a starting point — copy to `template.yaml` and fill in the cluster subdomain.

### Dev Spaces + Azure DevOps

**Important:** ADO repos don't support the `.git` URL suffix. The skeleton's `devfile.yaml` must include an explicit `projects` section with the repo URL (no `.git`), otherwise Dev Spaces will fail to clone with `TF401019`.

**Option A: OAuth (preferred, cluster-level)**

Requires an Entra ID app registration with a redirect URI pointing to Dev Spaces:

```bash
cp secrets/devspaces-oauth-config.yaml.example secrets/devspaces-oauth-config.yaml
# Edit with Entra ID credentials, then:
oc apply -f secrets/devspaces-oauth-config.yaml -n openshift-devspaces
```

The Entra ID app needs:
- Redirect URI: `https://devspaces.<cluster-subdomain>/api/oauth/callback`
- API permission: `vso.code_write`

**Option B: PAT secret (per-user)**

The Dev Spaces operator manages PAT secrets — they must include the `che.eclipse.org/che-userid` annotation or they get cleaned up. Get the user ID from the `user-profile` secret in their namespace:

```bash
oc get secret user-profile -n <username>-devspaces -o jsonpath='{.data.id}' | base64 -d

cp secrets/devspaces-ado-pat.yaml.example secrets/devspaces-ado-pat.yaml
# Edit with PAT and che-userid, then:
oc apply -f secrets/devspaces-ado-pat.yaml -n <username>-devspaces
```

To apply to all existing users:
```bash
for NS in $(oc get ns --no-headers | grep '\-devspaces' | grep -v openshift | awk '{print $1}'); do
  oc apply -f secrets/devspaces-ado-pat.yaml -n $NS
done
```

## Agent Image

Uses [`consultent/azure-pipelines-vsts-agent:ubuntu-22.04`](https://hub.docker.com/r/consultent/azure-pipelines-vsts-agent), a drop-in replacement for Microsoft's agent image with Ubuntu 22.04 and built-in Azure CLI.
