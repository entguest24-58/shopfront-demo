#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
cleanup_users() { sql "DELETE FROM users WHERE email = 'cv9971_role9_${SUFFIX}@example.com';" >/dev/null || true; }
trap cleanup_users EXIT

EMAIL="cv9971_role9_${SUFFIX}@example.com"
NAME="CV9971 Role ${SUFFIX}"
PASSWORD='Passw0rd99'

# Given
cv_step Given "an unused email and a registration body that also asks for the admin role" $LINENO
n=$(sql "SELECT count(*) FROM users WHERE lower(email) = lower('$EMAIL');")
[ "$n" = "0" ] || cv_fail "expected no account for $EMAIL before registering got $n" $LINENO
BODY=$(jq -nc --arg n "$NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p,role:"admin"}')

# When
cv_step When "the visitor registers with role=admin in the body" $LINENO
cv_http POST /auth/register "$BODY"
REG_STATUS="$CV_HTTP_STATUS"
REG_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the account is a customer account or the registration was refused; never admin" $LINENO
if [ "$REG_STATUS" = "201" ]; then
  resp_role=$(printf '%s' "$REG_BODY" | jq -r '.role // empty')
  [ "$resp_role" != "admin" ] || cv_fail "expected registration not to grant the requested admin role got response role=admin" $LINENO
  db_role=$(sql "SELECT role FROM users WHERE email = '$EMAIL';")
  [ "$db_role" = "customer" ] || cv_fail "expected the new account's stored role to be customer got '$db_role' (visitor self-assigned role)" $LINENO
  cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 200
  login_role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.user.role // empty')
  [ "$login_role" = "customer" ] || cv_fail "expected logged-in user role customer got '$login_role'" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  cv_http GET /admin/inventory/low-stock "" -H "Authorization: Bearer $TOKEN"
  [ "$CV_HTTP_STATUS" != "200" ] || cv_fail "expected self-registered account to be refused admin endpoint got 200" $LINENO
else
  case "$REG_STATUS" in 4??) ;; *) cv_fail "expected 201 (customer) or a 4xx refusal got $REG_STATUS: $REG_BODY" $LINENO ;; esac
  n=$(sql "SELECT count(*) FROM users WHERE email = '$EMAIL' AND role <> 'customer';")
  [ "$n" = "0" ] || cv_fail "expected no non-customer account created after refusal got $n" $LINENO
fi

# Cleanup
cv_step Cleanup "delete the created account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_9"
