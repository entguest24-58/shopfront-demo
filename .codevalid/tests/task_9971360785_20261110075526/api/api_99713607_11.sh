#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
cleanup_users() { sql "DELETE FROM users WHERE email = 'cv9971_pw11_${SUFFIX}@example.com';" >/dev/null || true; }
trap cleanup_users EXIT

EMAIL="cv9971_pw11_${SUFFIX}@example.com"
NAME="CV9971 Secret ${SUFFIX}"
PASSWORD="S3cretPw${SUFFIX: -6}"

# assert_no_password <label> <json-body> <hash>
assert_no_password() {
  local label="$1" body="$2" hash="$3"
  if printf '%s' "$body" | grep -qF -- "$PASSWORD"; then
    cv_fail "expected $label to omit the plaintext password got it in the body" $LINENO
  fi
  if [ -n "$hash" ] && printf '%s' "$body" | grep -qF -- "$hash"; then
    cv_fail "expected $label to omit the password hash got it in the body" $LINENO
  fi
  local keys
  keys=$(printf '%s' "$body" | jq -r '[paths | .[-1] | strings | select(test("pass|pwd|hash"; "i"))] | unique | join(",")')
  [ -z "$keys" ] || cv_fail "expected $label to have no password fields got keys: $keys" $LINENO
}

# Given
cv_step Given "a visitor with an unused email and a unique password" $LINENO
n=$(sql "SELECT count(*) FROM users WHERE lower(email) = lower('$EMAIL');")
[ "$n" = "0" ] || cv_fail "expected no account for $EMAIL before registering got $n" $LINENO

# When
cv_step When "the visitor registers" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
REG_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "registration, login and account views never contain the password or its hash" $LINENO
HASH=$(sql "SELECT password_hash FROM users WHERE email = '$EMAIL';")
[ -n "$HASH" ] || cv_fail "expected a stored account for $EMAIL got none" $LINENO
assert_no_password "registration response" "$REG_BODY" "$HASH"
cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 200
assert_no_password "login response" "$CV_HTTP_BODY" "$HASH"
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
assert_no_password "account view (/auth/me)" "$CV_HTTP_BODY" "$HASH"

# Cleanup
cv_step Cleanup "delete the created account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_11"
