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

EMAIL="cv6036_u3_${SUFFIX}@example.com"
NAME="CV6036 NoPassword ${SUFFIX}"
PASSWORD="Secr3tPwd!${SUFFIX}"

# Given
cv_step Given "a signed-in customer account whose plaintext password and stored password hash are known" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
STORED_HASH=$(sql "SELECT password_hash FROM users WHERE id = $USER_ID;")
[ -n "$STORED_HASH" ] || cv_fail "expected non-empty password_hash in users table for id $USER_ID" $LINENO
cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN" ] || cv_fail "expected session token on login got none" $LINENO

# When
cv_step When "the signed-in customer views their own profile via GET /auth/me" $LINENO
cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
ME_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the profile response returns name, email and role and contains no password or password hash in any form" $LINENO
me_name=$(printf '%s' "$ME_BODY" | jq -r '.name // empty')
me_email=$(printf '%s' "$ME_BODY" | jq -r '.email // empty')
me_role=$(printf '%s' "$ME_BODY" | jq -r '.role // empty')
[ "$me_name" = "$NAME" ] || cv_fail "expected GET /auth/me name '$NAME' got '$me_name'" $LINENO
[ "$me_email" = "$EMAIL" ] || cv_fail "expected GET /auth/me email '$EMAIL' got '$me_email'" $LINENO
[ "$me_role" = "customer" ] || cv_fail "expected GET /auth/me role 'customer' got '$me_role'" $LINENO

pwd_keys=$(printf '%s' "$ME_BODY" | jq -r '[.. | objects | keys_unsorted[] | select(test("pass|hash"; "i"))] | join(",")')
if [ -n "$pwd_keys" ]; then
  cv_fail "security finding: GET /auth/me exposed password-related field(s) '$pwd_keys': $ME_BODY" $LINENO
fi

if printf '%s' "$ME_BODY" | grep -qF -- "$PASSWORD"; then
  cv_fail "security finding: GET /auth/me exposed plaintext password in response: $ME_BODY" $LINENO
fi

if printf '%s' "$ME_BODY" | grep -qF -- "$STORED_HASH"; then
  cv_fail "security finding: GET /auth/me exposed stored password hash in response: $ME_BODY" $LINENO
fi

if printf '%s' "$ME_BODY" | grep -qE '\$2[aby]\$[0-9]{2}\$'; then
  cv_fail "security finding: GET /auth/me exposed bcrypt hash pattern in response: $ME_BODY" $LINENO
fi

# Cleanup
cv_step Cleanup "delete the created customer account" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_3"
