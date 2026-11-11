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

EMAIL="cv6036_u4_${SUFFIX}@example.com"
ORIG_NAME="CV6036 SecretOrig ${SUFFIX}"
NEW_NAME="CV6036 SecretUpdated ${SUFFIX}"
PASSWORD="S3cretPw!${SUFFIX: -6}"

assert_no_password() {
  local label="$1" body="$2" hash="$3"
  if printf '%s' "$body" | grep -qF -- "$PASSWORD"; then
    cv_fail "expected $label to omit plaintext password got it in body" $LINENO
  fi
  if [ -n "$hash" ] && printf '%s' "$body" | grep -qF -- "$hash"; then
    cv_fail "expected $label to omit password hash got it in body" $LINENO
  fi
  local keys
  keys=$(printf '%s' "$body" | jq -r '[paths | .[-1] | strings | select(test("pass|pwd|hash"; "i"))] | unique | join(",")')
  [ -z "$keys" ] || cv_fail "expected $label to contain no password fields got keys: $keys" $LINENO
}

# Given
cv_step Given "a registered and signed-in customer account with a known password" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$ORIG_NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
HASH=$(sql "SELECT password_hash FROM users WHERE id = $USER_ID;")
[ -n "$HASH" ] || cv_fail "expected stored password_hash for user $USER_ID got empty" $LINENO
cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN" ] || cv_fail "expected session token on login got none" $LINENO

# When
cv_step When "the signed-in customer updates their name via PATCH /auth/me" $LINENO
cv_http PATCH /auth/me "$(jq -nc --arg n "$NEW_NAME" '{name:$n}')" 200 -H "Authorization: Bearer $TOKEN"
PATCH_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the returned profile data contains the updated name and no password or password hash in any form" $LINENO
got_name=$(printf '%s' "$PATCH_BODY" | jq -r '.name // empty')
[ "$got_name" = "$NEW_NAME" ] || cv_fail "expected updated name '$NEW_NAME' in PATCH /auth/me response got '$got_name'" $LINENO
assert_no_password "PATCH /auth/me response" "$PATCH_BODY" "$HASH"

cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
assert_no_password "GET /auth/me response after update" "$CV_HTTP_BODY" "$HASH"

# Cleanup
cv_step Cleanup "delete the created customer account" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_4"
