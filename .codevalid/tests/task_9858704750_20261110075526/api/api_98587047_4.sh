#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
EMAIL="cv_wrongpw_${SUFFIX}@example.com"
UNKNOWN_EMAIL="cv_nobody_${SUFFIX}@example.com"
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
cv_step Given "a registered customer and the refusal message for an unregistered email" $LINENO
cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV WrongPw\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $EMAIL got $CV_HTTP_STATUS" $LINENO
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
cv_prereq "capture the refusal message for an unregistered email" $LINENO
cv_http POST /auth/login "{\"email\":\"$UNKNOWN_EMAIL\",\"password\":\"$PASSWORD\"}"
REF_STATUS=$CV_HTTP_STATUS
REF_ERR=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
[ "$REF_STATUS" = "401" ] || cv_fail "expected unknown-email refusal 401 got $REF_STATUS" $LINENO
[ -n "$REF_ERR" ] || cv_fail "expected a refusal message for unknown email got none" $LINENO

# When
cv_step When "the customer signs in with their email and an incorrect password" $LINENO
cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"WrongPass-${SUFFIX}\"}"

# Then
cv_step Then "sign-in is refused, no token issued, and the message equals the unknown-email message" $LINENO
[ "$CV_HTTP_STATUS" = "401" ] || cv_fail "expected 401 for wrong password got $CV_HTTP_STATUS" $LINENO
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty' 2>/dev/null || true)
[ -z "$TOKEN" ] || cv_fail "expected no session token for wrong password got one" $LINENO
ERR=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
[ "$ERR" = "$REF_ERR" ] || cv_fail "expected wrong-password message '$REF_ERR' got '$ERR'" $LINENO

# Cleanup
cv_step Cleanup "delete the test user" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_98587047_4"
