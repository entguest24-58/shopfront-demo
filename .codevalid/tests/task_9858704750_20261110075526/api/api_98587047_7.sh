#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
EMAIL="cv_victim_${SUFFIX}@example.com"
CASED_EMAIL="CV_VICTIM_${SUFFIX}@EXAMPLE.com"
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
cv_step Given "a victim customer registered with a lowercase email, and the generic refusal message" $LINENO
cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Victim\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $EMAIL got $CV_HTTP_STATUS" $LINENO
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
cv_prereq "capture the generic refusal message using an unregistered email" $LINENO
cv_http POST /auth/login "{\"email\":\"$UNKNOWN_EMAIL\",\"password\":\"$PASSWORD\"}"
REF_ERR=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
[ -n "$REF_ERR" ] || cv_fail "expected a generic refusal message got none" $LINENO

# When
cv_step When "the attacker signs in with a case-altered email and a wrong password" $LINENO
cv_http POST /auth/login "{\"email\":\"$CASED_EMAIL\",\"password\":\"WrongPass-${SUFFIX}\"}"

# Then
cv_step Then "sign-in is refused with the generic message and no session is issued" $LINENO
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty' 2>/dev/null || true)
[ -z "$TOKEN" ] || cv_fail "expected no session token for victim account got one (status $CV_HTTP_STATUS)" $LINENO
[ "$CV_HTTP_STATUS" != "200" ] || cv_fail "expected sign-in to be refused got 200" $LINENO
ERR=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty')
[ "$ERR" = "$REF_ERR" ] || cv_fail "expected generic refusal message '$REF_ERR' got '$ERR'" $LINENO

# Cleanup
cv_step Cleanup "delete the test user" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_98587047_7"
