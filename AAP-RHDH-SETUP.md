# AAP Plugins for RHDH — Setup Notes

How to get the Ansible Automation Platform plugins working in Red Hat Developer Hub so software templates can trigger AAP job templates.

## Architecture

```
Developer → RHDH Template → rhaap:launch-job-template action
    → PAT from scaffolder env secrets → AAP Controller API
    → Ansible playbook runs → OpenShift resources created
```

## Prerequisites

- AAP 2.5+ with Controller running (we use AAP 2.7 on Wing at `aap.ultra.lab`)
- RHDH 1.9+ deployed via Operator on OpenShift (we use RHDH 1.10)
- A Personal Access Token (PAT) from AAP with write scope
- Job templates created in AAP with `ask_variables_on_launch: true`

## Dynamic Plugins (4 required, 1 disabled)

Add these to your dynamic plugins ConfigMap. All from `automation-portal:2.2`:

```yaml
# 1. Frontend — Ansible page and sidebar
- package: 'oci://registry.redhat.io/ansible-automation-platform/automation-portal:2.2!ansible-plugin-backstage-rhaap'
  disabled: false
  pluginConfig:
    dynamicPlugins:
      frontend:
        ansible.plugin-backstage-rhaap:
          appIcons:
            - importName: AnsibleLogo
              name: AnsibleLogo
          dynamicRoutes:
            - importName: AnsiblePage
              menuItem:
                icon: AnsibleLogo
                text: Ansible
              path: /ansible

# 2. Self-service UI — AAPTokenFieldExtension (optional, for OAuth2 flow)
- package: 'oci://registry.redhat.io/ansible-automation-platform/automation-portal:2.2!ansible-plugin-backstage-self-service'
  disabled: false
  pluginConfig:
    dynamicPlugins:
      frontend:
        ansible.plugin-backstage-self-service:
          scaffolderFieldExtensions:
            - importName: AAPTokenFieldExtension
            - importName: AAPResourcePickerExtension

# 3. Catalog backend — syncs AAP job templates as catalog entities
- package: 'oci://registry.redhat.io/ansible-automation-platform/automation-portal:2.2!ansible-backstage-plugin-catalog-backend-module-rhaap'
  disabled: false
  pluginConfig: {}

# 4. Scaffolder backend — provides rhaap:launch-job-template action
- package: 'oci://registry.redhat.io/ansible-automation-platform/automation-portal:2.2!ansible-plugin-scaffolder-backend-module-backstage-rhaap'
  disabled: false
  pluginConfig:
    dynamicPlugins:
      backend:
        ansible.plugin-scaffolder-backend-module-backstage-rhaap:

# 5. Auth backend — DISABLED (see Known Issues below)
- package: 'oci://registry.redhat.io/ansible-automation-platform/automation-portal:2.2!ansible-backstage-plugin-auth-backend-module-rhaap-provider'
  disabled: true
```

## App-Config

```yaml
ansible:
  creatorService:
    baseUrl: 127.0.0.1
    port: '8000'
  rhaap:
    baseUrl: ${AAP_BASE_URL}     # e.g. https://aap.ultra.lab
    token: ${AAP_TOKEN}           # PAT with write scope
    checkSSL: false

scaffolder:
  defaultEnvironment:
    secrets:
      aapToken: ${AAP_TOKEN}      # Available as ${{ environment.secrets.aapToken }}
```

The `AAP_BASE_URL` and `AAP_TOKEN` env vars come from a Kubernetes Secret
mounted via `extraEnvs.secrets` in the Backstage CR.

## Software Template Token Syntax

**RHDH 1.10+ uses `${{ environment.secrets.* }}` — NOT `${{ secrets.* }}`**

```yaml
steps:
  - id: launch-job
    action: rhaap:launch-job-template
    input:
      token: ${{ environment.secrets.aapToken }}
      values:
        template: My Job Template
        extraVariables:
          key: ${{ parameters.someValue }}
```

## Known Issues

### Auth backend module race condition

The `ansible-backstage-plugin-auth-backend-module-rhaap-provider` plugin
registers the `rhaap` auth provider for OAuth2 login. However, RHDH's
built-in `auth-providers` module evaluates `auth.providers.*` config
BEFORE dynamic plugins load. If `auth.providers.rhaap` is in app-config,
RHDH crashes with "No auth provider found for rhaap".

`ENABLE_AUTH_PROVIDER_MODULE_OVERRIDE=true` fixes the race condition but
disables ALL built-in auth providers (including `oidc` for Keycloak).

**Workaround:** Disable the auth backend module and use a PAT via
`scaffolder.defaultEnvironment.secrets` instead of OAuth2. This is simpler
and avoids the auth provider conflict entirely.

### OCI plugin name mismatch

The auth backend module's correct OCI artifact name is:
`ansible-backstage-plugin-auth-backend-module-rhaap-provider`

NOT `ansible-plugin-auth-backend-module-backstage-rhaap` (which creates
an empty directory that passes hash checks but contains no code).

### Pod lockfile after force delete

Force-deleting RHDH pods (`--force --grace-period=0`) leaves a stale
lockfile at `/dynamic-plugins-root/install-dynamic-plugins.lock`. New
pods get stuck on "Waiting for lock release". Fix by exec'ing into the
init container and removing the file, or gracefully deleting pods instead.

### PostgreSQL connection exhaustion

Multiple RHDH pods starting simultaneously exhaust the embedded
PostgreSQL `max_connections`. Always scale to 0, wait for pods to
terminate, then scale back to 1. Restart PostgreSQL if connections
are stuck.
