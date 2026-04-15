#!/bin/bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:9080}"
REALM="fabletics-demo"
CLIENT_ID="agw-client"
CLIENT_SECRET="agw-client-secret"

echo "=== Waiting for Keycloak to be ready ==="
until curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; do
  echo "  Waiting..."
  sleep 5
done
echo "Keycloak is ready!"

echo ""
echo "=== Getting admin token ==="
ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=admin" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "$ADMIN_TOKEN" = "null" ] || [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: Failed to get admin token"
  exit 1
fi
echo "Got admin token"

echo ""
echo "=== Creating realm: ${REALM} ==="
curl -s -X POST "${KEYCLOAK_URL}/admin/realms" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"realm\": \"${REALM}\",
    \"enabled\": true,
    \"accessTokenLifespan\": 86400
  }" || echo "(realm may already exist)"

echo ""
echo "=== Creating client: ${CLIENT_ID} ==="
curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"secret\": \"${CLIENT_SECRET}\",
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": true,
    \"publicClient\": false
  }" || echo "(client may already exist)"

# Get client UUID
CLIENT_UUID=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.clientId==\"${CLIENT_ID}\") | .id")
echo "Client UUID: ${CLIENT_UUID}"

echo ""
echo "=== Adding custom attributes to User Profile (required for Keycloak 26+) ==="
PROFILE=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/users/profile" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")
UPDATED_PROFILE=$(echo "$PROFILE" | jq '.attributes += [
  {"name":"org","displayName":"Organization","permissions":{"view":["admin","user"],"edit":["admin"]},"validations":{}},
  {"name":"team","displayName":"Team","permissions":{"view":["admin","user"],"edit":["admin"]},"validations":{}},
  {"name":"tier","displayName":"Tier","permissions":{"view":["admin","user"],"edit":["admin"]},"validations":{}},
  {"name":"role","displayName":"Role","permissions":{"view":["admin","user"],"edit":["admin"]},"validations":{}}
]')
curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/profile" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$UPDATED_PROFILE" > /dev/null
echo "User Profile updated"

echo ""
echo "=== Adding protocol mappers for custom claims ==="
for CLAIM in org team tier role; do
  curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${CLAIM}-mapper\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-usermodel-attribute-mapper\",
      \"config\": {
        \"user.attribute\": \"${CLAIM}\",
        \"claim.name\": \"${CLAIM}\",
        \"jsonType.label\": \"String\",
        \"access.token.claim\": \"true\",
        \"id.token.claim\": \"true\",
        \"userinfo.token.claim\": \"true\"
      }
    }" 2>/dev/null || true
done
echo "Protocol mappers created"

echo ""
echo "=== Creating demo users ==="

create_user() {
  local USERNAME=$1
  local PASSWORD=$2
  local FIRSTNAME=$3
  local ROLE=$4
  local TIER=$5
  local TEAM=$6

  echo "  Creating user: ${USERNAME} (role=${ROLE}, tier=${TIER})"

  curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${USERNAME}\",
      \"email\": \"${USERNAME}@fabletics.com\",
      \"emailVerified\": true,
      \"firstName\": \"${FIRSTNAME}\",
      \"lastName\": \"Demo\",
      \"enabled\": true,
      \"attributes\": {
        \"org\": [\"fabletics\"],
        \"team\": [\"${TEAM}\"],
        \"tier\": [\"${TIER}\"],
        \"role\": [\"${ROLE}\"]
      },
      \"credentials\": [{\"type\": \"password\", \"value\": \"${PASSWORD}\", \"temporary\": false}]
    }" 2>/dev/null || echo "    (user may already exist)"
}

# sarah — platform admin, full access
create_user "sarah"  "sarah"  "Sarah"  "admin"     "premium"  "platform"
# devon — engineer, standard access
create_user "devon"  "devon"  "Devon"  "developer" "standard" "engineering"
# alex — analytics viewer, limited access
create_user "alex"   "alex"   "Alex"   "viewer"    "free"     "analytics"

echo ""
echo "=== Setting realm frontend URL (required for issuer claim to match gateway policy) ==="
curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"realm\":\"${REALM}\",\"attributes\":{\"frontendUrl\":\"http://keycloak.keycloak.svc.cluster.local:8080\"}}" > /dev/null
echo "Frontend URL set"

echo ""
echo "=========================================="
echo "  Keycloak Setup Complete!"
echo "=========================================="
echo ""
echo "Realm:  ${REALM}"
echo "Client: ${CLIENT_ID} / ${CLIENT_SECRET}"
echo ""
echo "Users:"
echo "  sarah / sarah  (admin, premium, platform)"
echo "  devon / devon  (developer, standard, engineering)"
echo "  alex  / alex   (viewer, free, analytics)"
echo ""
echo "=== Test: Get JWT for sarah ==="
echo ""
echo "curl -s -X POST '${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token' \\"
echo "  -H 'Content-Type: application/x-www-form-urlencoded' \\"
echo "  -d 'username=sarah&password=sarah&grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}' | jq -r '.access_token'"
echo ""

# Actually get and display a token
echo "=== Sample token for sarah ==="
SARAH_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=sarah&password=sarah&grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" | jq -r '.access_token')

if [ "$SARAH_TOKEN" != "null" ] && [ -n "$SARAH_TOKEN" ]; then
  echo "Token (first 50 chars): ${SARAH_TOKEN:0:50}..."
  echo ""
  echo "Decoded payload:"
  echo "$SARAH_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq . 2>/dev/null || echo "(decode failed — token may need padding)"
fi
