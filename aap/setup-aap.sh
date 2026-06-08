#!/usr/bin/env bash
# AAP setup script for RHDH demo cluster
# Prerequisites: oc logged in, AAP operator installed and controller running
set -euo pipefail

AAP_NS="aap"
RHDH_NS="rhdh"

# Get cluster-specific values
AAP_URL="https://$(oc get route aap -n ${AAP_NS} -o jsonpath='{.spec.host}')"
AAP_PASS=$(oc get secret aap-admin-password -n ${AAP_NS} -o jsonpath='{.data.password}' | base64 -d)
OCP_HOST=$(oc whoami --show-server)
OCP_TOKEN=$(oc whoami -t)
GITLAB_HOST=$(oc get route gitlab -n gitlab -o jsonpath='{.spec.host}')
GITLAB_TOKEN=$(oc get secret gitlab-token -n ${RHDH_NS} -o jsonpath='{.data.GITLAB_TOKEN}' | base64 -d)
RHDH_HOST=$(oc get route backstage-developer-hub -n ${RHDH_NS} -o jsonpath='{.spec.host}')

echo "=== AAP URL: ${AAP_URL}"
echo "=== RHDH Host: ${RHDH_HOST}"

# 1. Create personal token for RHDH
echo "--- Creating AAP token for RHDH..."
AAP_TOKEN=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/users/1/personal_tokens/" \
  -H "Content-Type: application/json" \
  -d '{"description":"RHDH integration token","scope":"write"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
echo "    Token: ${AAP_TOKEN:0:5}..."

# 2. Update aap-credentials secret in RHDH namespace
echo "--- Updating aap-credentials secret..."
oc patch secret aap-credentials -n ${RHDH_NS} --type merge \
  -p "{\"stringData\":{\"AAP_TOKEN\":\"${AAP_TOKEN}\",\"AAP_BASE_URL\":\"${AAP_URL}\"}}"

# 3. Create OpenShift credential
echo "--- Creating OpenShift credential..."
OCP_CRED_ID=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/credentials/" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"OpenShift Credential\",
    \"credential_type\": 17,
    \"organization\": 1,
    \"inputs\": {
      \"host\": \"${OCP_HOST}\",
      \"bearer_token\": \"${OCP_TOKEN}\",
      \"verify_ssl\": false
    }
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Credential ID: ${OCP_CRED_ID}"

# 4. Create GitLab SCM credential
echo "--- Creating GitLab SCM credential..."
SCM_CRED_ID=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/credentials/" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"GitLab SCM Credential\",
    \"credential_type\": 2,
    \"organization\": 1,
    \"inputs\": {
      \"username\": \"root\",
      \"password\": \"${GITLAB_TOKEN}\"
    }
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Credential ID: ${SCM_CRED_ID}"

# 5. Create pe1/ansible-demo-playbooks repo on GitLab (if needed)
echo "--- Setting up GitLab playbook repo..."
REPO_EXISTS=$(curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects?search=ansible-demo-playbooks" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

if [ -z "${REPO_EXISTS}" ]; then
  PE1_ID=$(curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://${GITLAB_HOST}/api/v4/users?search=pe1" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

  REPO_ID=$(curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X POST \
    "https://${GITLAB_HOST}/api/v4/projects" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"ansible-demo-playbooks\",\"namespace_id\":${PE1_ID},\"visibility\":\"internal\",\"initialize_with_readme\":true}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  # Unprotect main branch to allow push
  curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X DELETE \
    "https://${GITLAB_HOST}/api/v4/projects/${REPO_ID}/protected_branches/main"

  # Push playbook
  CONTENT_B64=$(base64 < "$(dirname "$0")/playbooks/provision-team-environment.yaml")
  curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X POST \
    "https://${GITLAB_HOST}/api/v4/projects/${REPO_ID}/repository/files/provision-team-environment.yaml" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"main\",\"encoding\":\"base64\",\"content\":\"${CONTENT_B64}\",\"commit_message\":\"Add provision team environment playbook\"}"

  echo "    Created repo pe1/ansible-demo-playbooks (ID: ${REPO_ID})"
else
  REPO_ID=${REPO_EXISTS}
  echo "    Repo already exists (ID: ${REPO_ID})"
fi

# 6. Create AAP project
echo "--- Creating AAP project..."
PROJECT_ID=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/projects/" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Ansible Demo Playbooks\",
    \"organization\": 1,
    \"scm_type\": \"git\",
    \"scm_url\": \"https://${GITLAB_HOST}/pe1/ansible-demo-playbooks.git\",
    \"credential\": ${SCM_CRED_ID},
    \"scm_update_on_launch\": true
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Project ID: ${PROJECT_ID}"

# Wait for project sync
echo "--- Waiting for project sync..."
for i in {1..12}; do
  STATUS=$(curl -sk -u "admin:${AAP_PASS}" "${AAP_URL}/api/controller/v2/projects/${PROJECT_ID}/" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
  [ "${STATUS}" = "successful" ] && break
  sleep 5
done
echo "    Sync status: ${STATUS}"

# 7. Create job template
echo "--- Creating job template..."
JT_ID=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/job_templates/" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Provision Team Environment\",
    \"organization\": 1,
    \"project\": ${PROJECT_ID},
    \"playbook\": \"provision-team-environment.yaml\",
    \"inventory\": 1,
    \"ask_variables_on_launch\": true,
    \"extra_vars\": \"team_name: demo-team\nenvironment_tier: dev\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Job Template ID: ${JT_ID}"

# 8. Create OAuth2 application for RHDH
echo "--- Creating OAuth2 application..."
OAUTH_RESULT=$(curl -sk -u "admin:${AAP_PASS}" -X POST "${AAP_URL}/api/controller/v2/applications/" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"RHDH Integration\",
    \"organization\": 1,
    \"client_type\": \"confidential\",
    \"authorization_grant_type\": \"authorization-code\",
    \"redirect_uris\": \"https://${RHDH_HOST}/api/auth/rhaap/handler/frame\"
  }")
OAUTH_CLIENT_ID=$(echo "${OAUTH_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
OAUTH_CLIENT_SECRET=$(echo "${OAUTH_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_secret'])")
echo "    Client ID: ${OAUTH_CLIENT_ID}"
echo "    Client Secret: ${OAUTH_CLIENT_SECRET:0:10}..."

echo ""
echo "=== AAP setup complete ==="
echo ""
echo "Remaining manual steps:"
echo "  1. Upload your SSH key to AAP if needed for Machine credentials"
echo "  2. Add the OAuth client ID/secret to RHDH app-config if not already configured"
echo "  3. Verify the 'Provision Team Environment' template works in RHDH"
