#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
EMAIL="cv_enum_${SUFFIX}@example.com"
UNKNOWN_EMAIL="cv_enum_none_${SUFFIX}@example.com"
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
cv_step Given "a registered customer and an unregistered email address" $LINENO
cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Enum\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $EMAIL got $CV_HTTP_STATUS" $LINENO
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
N=$(sql "SELECT count(*) FROM users WHERE lower(email) = lower('$UNKNOWN_EMAIL');")
[ "$N" = "0" ] || cv_fail "expected $UNKNOWN_EMAIL to be unregistered got $N rows" $LINENO

# When
cv_step When "the attacker tries the registered email with a wrong password, then the unregistered email" $LINENO
ATTEMPT_PW="Guess-${SUFFIX}"
cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$ATTEMPT_PW\"}"
A_STATUS=$CV_HTTP_STATUS
A_BODY=$CV_HTTP_BODY
cv_http POST /auth/login "{\"email\":\"$UNKNOWN_EMAIL\",\"password\":\"$ATTEMPT_PW\"}"
B_STATUS=$CV_HTTP_STATUS
B_BODY=$CV_HTTP_BODY

# Then
cv_step Then "both refusals are indistinguishable (status and body) and issue no token" $LINENO
[ "$A_STATUS" != "200" ] || cv_fail "expected registered email with wrong password to be refused got 200" $LINENO
[ "$B_STATUS" != "200" ] || cv_fail "expected unregistered email to be refused got 200" $LINENO
[ "$A_STATUS" = "$B_STATUS" ] || cv_fail "expected identical refusal status, got $A_STATUS (registered) vs $B_STATUS (unregistered)" $LINENO
A_NORM=$(printf '%s' "$A_BODY" | jq -cS . 2>/dev/null || printf '%s' "$A_BODY")
B_NORM=$(printf '%s' "$B_BODY" | jq -cS . 2>/dev/null || printf '%s' "$B_BODY")
[ "$A_NORM" = "$B_NORM" ] || cv_fail "expected identical refusal bodies, got '$A_NORM' (registered) vs '$B_NORM' (unregistered)" $LINENO
for b in "$A_BODY" "$B_BODY"; do
  t=$(printf '%s' "$b" | jq -r '.token // empty' 2>/dev/null || true)
  [ -z "$t" ] || cv_fail "expected no token in a refusal got one" $LINENO
done

# Cleanup
cv_step Cleanup "delete the test user" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_98587047_6"
