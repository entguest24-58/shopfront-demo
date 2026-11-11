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

EMAIL="cv6036_u10_${SUFFIX}@example.com"
ORIG_NAME="CV6036 Owner ${SUFFIX}"
ANON_NEW_NAME="CV6036 AnonChanged ${SUFFIX}"
PASSWORD="Passw0rd!${SUFFIX: -6}"

# Given
cv_step Given "an existing customer account and a signed-out caller with no token" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$ORIG_NAME" --arg e "$EMAIL" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user id got '$USER_ID'" $LINENO
CREATED_USER_IDS+=("$USER_ID")
cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
OWNER_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$OWNER_TOKEN" ] || cv_fail "expected owner session token got none" $LINENO

# When
cv_step When "a signed-out caller attempts GET /auth/me and PATCH /auth/me without credentials" $LINENO
cv_http GET /auth/me
GET_ANON_STATUS="$CV_HTTP_STATUS"
GET_ANON_BODY="$CV_HTTP_BODY"

cv_http PATCH /auth/me "$(jq -nc --arg n "$ANON_NEW_NAME" '{name:$n}')"
PATCH_ANON_STATUS="$CV_HTTP_STATUS"
PATCH_ANON_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "both unauthenticated calls are refused, no profile data is returned, and the customer's name is unchanged" $LINENO
[ "$GET_ANON_STATUS" != "200" ] || cv_fail "security finding: signed-out GET /auth/me succeeded with 200: $GET_ANON_BODY" $LINENO
case "$GET_ANON_STATUS" in
  401|403) ;;
  *) cv_fail "expected 401 or 403 for signed-out GET /auth/me got $GET_ANON_STATUS: $GET_ANON_BODY" $LINENO ;;
esac
if printf '%s' "$GET_ANON_BODY" | grep -qF -- "$EMAIL" || printf '%s' "$GET_ANON_BODY" | grep -qF -- "$ORIG_NAME"; then
  cv_fail "security finding: signed-out GET /auth/me exposed profile data: $GET_ANON_BODY" $LINENO
fi

[ "$PATCH_ANON_STATUS" != "200" ] || cv_fail "security finding: signed-out PATCH /auth/me succeeded with 200: $PATCH_ANON_BODY" $LINENO
case "$PATCH_ANON_STATUS" in
  401|403) ;;
  *) cv_fail "expected 401 or 403 for signed-out PATCH /auth/me got $PATCH_ANON_STATUS: $PATCH_ANON_BODY" $LINENO ;;
esac
if printf '%s' "$PATCH_ANON_BODY" | grep -qF -- "$EMAIL" || printf '%s' "$PATCH_ANON_BODY" | grep -qF -- "$ORIG_NAME"; then
  cv_fail "security finding: signed-out PATCH /auth/me exposed profile data: $PATCH_ANON_BODY" $LINENO
fi

cv_http GET /auth/me "" 200 -H "Authorization: Bearer $OWNER_TOKEN"
owner_name=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.name // empty')
[ "$owner_name" = "$ORIG_NAME" ] || cv_fail "security finding: customer name changed from '$ORIG_NAME' to '$owner_name' after signed-out PATCH /auth/me" $LINENO

changed_count=$(sql "SELECT count(*) FROM users WHERE name = '$ANON_NEW_NAME';")
[ "$changed_count" = "0" ] || cv_fail "security finding: signed-out PATCH /auth/me altered $changed_count user row(s)" $LINENO

# Cleanup
cv_step Cleanup "delete the created customer account" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_10"
