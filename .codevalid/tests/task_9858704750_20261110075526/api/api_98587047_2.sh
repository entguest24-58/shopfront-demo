#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
EMAIL="cv_case_${SUFFIX}@example.com"
MIXED_EMAIL="CV_Case_${SUFFIX}@Example.COM"
CREATED_USER_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
cleanup_all() {
  local u
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM users WHERE id = $u;" >/dev/null || true
  done
}
trap cleanup_all EXIT

# Given
cv_step Given "a customer registered with an all-lowercase email" $LINENO
cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Case\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $EMAIL got $CV_HTTP_STATUS" $LINENO
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")

# When
cv_step When "the customer signs in with a mixed-case version of the email and the correct password" $LINENO
cv_http POST /auth/login "{\"email\":\"$MIXED_EMAIL\",\"password\":\"$PASSWORD\"}"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 signing in with $MIXED_EMAIL got $CV_HTTP_STATUS" $LINENO
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN" ] || cv_fail "expected a session token got none" $LINENO

# Then
cv_step Then "the token authenticates the same account" $LINENO
cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
ME_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[ "$ME_ID" = "$USER_ID" ] || cv_fail "expected /auth/me id $USER_ID got $ME_ID" $LINENO
N=$(sql "SELECT count(*) FROM users WHERE lower(email) = lower('$EMAIL');")
[ "$N" = "1" ] || cv_fail "expected exactly 1 account for the email got $N" $LINENO

# Cleanup
cv_step Cleanup "delete the test user" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_98587047_2"
