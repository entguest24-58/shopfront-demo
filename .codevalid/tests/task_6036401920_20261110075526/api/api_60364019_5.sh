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
  sql "DELETE FROM users WHERE lower(email) IN (lower('$ORIG_EMAIL'), lower('$NEW_EMAIL'));" >/dev/null || true
}

ORIG_EMAIL="cv6036_u5_orig_${SUFFIX}@example.com"
NEW_EMAIL="cv6036_u5_new_${SUFFIX}@example.com"
NAME="CV6036 EmailLock ${SUFFIX}"
PASSWORD="Passw0rd!${SUFFIX: -6}"
trap cleanup_all EXIT

# Given
cv_step Given "a signed-in customer account with an established email address" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME" --arg e "$ORIG_EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
cv_http POST /auth/login "$(jq -nc --arg e "$ORIG_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN" ] || cv_fail "expected session token on login got none" $LINENO

# When
cv_step When "the customer submits a PATCH /auth/me update attempting to change their email address" $LINENO
cv_http PATCH /auth/me "$(jq -nc --arg e "$NEW_EMAIL" '{email:$e}')" -H "Authorization: Bearer $TOKEN"
PATCH_STATUS="$CV_HTTP_STATUS"
PATCH_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the customer's stored email address remains unchanged when viewing their profile afterwards" $LINENO
if [ "$PATCH_STATUS" = "200" ]; then
  resp_email=$(printf '%s' "$PATCH_BODY" | jq -r '.email // empty')
  [ "$resp_email" = "$ORIG_EMAIL" ] || cv_fail "security finding: PATCH /auth/me changed customer email from '$ORIG_EMAIL' to '$resp_email'" $LINENO
fi

cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
me_email=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.email // empty')
[ "$me_email" = "$ORIG_EMAIL" ] || cv_fail "security finding: GET /auth/me shows email changed from '$ORIG_EMAIL' to '$me_email'" $LINENO

db_email=$(sql "SELECT email FROM users WHERE id = $USER_ID;")
[ "$db_email" = "$ORIG_EMAIL" ] || cv_fail "security finding: stored email in users table changed from '$ORIG_EMAIL' to '$db_email'" $LINENO

# Cleanup
cv_step Cleanup "delete the created customer account" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_5"
