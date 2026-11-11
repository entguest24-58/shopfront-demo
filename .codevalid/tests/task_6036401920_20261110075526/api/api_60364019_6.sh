#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
CREATED_USER_IDS=()
cleanup_all() {
  local u
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM users WHERE id = $u;" >/dev/null || true
  done
}
trap cleanup_all EXIT

EMAIL="cv6036_u6_${SUFFIX}@example.com"
NAME="CV6036 RoleLock ${SUFFIX}"
PASSWORD="Passw0rd!${SUFFIX: -6}"

# Given
cv_step Given "a signed-in customer account with the customer role" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
init_role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.role // empty')
[ "$init_role" = "customer" ] || cv_fail "expected initial role 'customer' got '$init_role'" $LINENO
cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN" ] || cv_fail "expected session token on login got none" $LINENO

# When
cv_step When "the customer submits PATCH /auth/me setting role to admin" $LINENO
cv_http PATCH /auth/me '{"role":"admin"}' -H "Authorization: Bearer $TOKEN"
PATCH_STATUS="$CV_HTTP_STATUS"
PATCH_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the customer's stored role remains customer and they gain no admin permissions" $LINENO
if [ "$PATCH_STATUS" = "200" ]; then
  resp_role=$(printf '%s' "$PATCH_BODY" | jq -r '.role // empty')
  [ "$resp_role" = "customer" ] || cv_fail "security finding: PATCH /auth/me escalated role from 'customer' to '$resp_role'" $LINENO
fi

cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
me_role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.role // empty')
[ "$me_role" = "customer" ] || cv_fail "security finding: GET /auth/me returned escalated role '$me_role' instead of 'customer'" $LINENO

db_role=$(sql "SELECT role FROM users WHERE id = $USER_ID;")
[ "$db_role" = "customer" ] || cv_fail "security finding: stored role in users table changed to '$db_role' instead of 'customer'" $LINENO

# Also verify re-login does not issue an admin token allowing admin endpoint access
cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
FRESH_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
cv_http GET /admin/inventory/low-stock "" -H "Authorization: Bearer $FRESH_TOKEN"
[ "$CV_HTTP_STATUS" != "200" ] || cv_fail "security finding: customer gained admin access to /admin/inventory/low-stock after PATCH /auth/me" $LINENO

# Cleanup
cv_step Cleanup "delete the created customer account" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_6"
