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

EMAIL_A="cv6036_u9_a_${SUFFIX}@example.com"
NAME_A="CV6036 CustomerA ${SUFFIX}"
EMAIL_B="cv6036_u9_b_${SUFFIX}@example.com"
NAME_B="CV6036 CustomerB ${SUFFIX}"
ATTACK_NAME="CV6036 OverwrittenByA ${SUFFIX}"
PASSWORD="Passw0rd!${SUFFIX: -6}"

# Given
cv_step Given "two registered customers A and B, with customer A signed in" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME_A" --arg e "$EMAIL_A" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_A_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_A_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user A id got '$USER_A_ID'" $LINENO
CREATED_USER_IDS+=("$USER_A_ID")

cv_http POST /auth/register "$(jq -nc --arg n "$NAME_B" --arg e "$EMAIL_B" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_B_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_B_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user B id got '$USER_B_ID'" $LINENO
CREATED_USER_IDS+=("$USER_B_ID")

cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL_A" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN_A=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN_A" ] || cv_fail "expected session token for customer A got none" $LINENO

cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL_B" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN_B=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN_B" ] || cv_fail "expected session token for customer B got none" $LINENO

# When
cv_step When "customer A attempts to overwrite customer B's name by passing customer B's id to PATCH /auth/me" $LINENO
ATTACK_BODY=$(jq -nc --argjson id "$USER_B_ID" --arg n "$ATTACK_NAME" '{id:$id,name:$n}')
cv_http PATCH /auth/me "$ATTACK_BODY" -H "Authorization: Bearer $TOKEN_A"

# Then
cv_step Then "customer B's name remains unchanged when read back by customer B and in storage" $LINENO
cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN_B"
b_name=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.name // empty')
b_email=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.email // empty')
[ "$b_name" = "$NAME_B" ] || cv_fail "security finding: customer B's name was changed from '$NAME_B' to '$b_name' by customer A" $LINENO
[ "$b_email" = "$EMAIL_B" ] || cv_fail "expected customer B email '$EMAIL_B' got '$b_email'" $LINENO

db_b_name=$(sql "SELECT name FROM users WHERE id = $USER_B_ID;")
[ "$db_b_name" = "$NAME_B" ] || cv_fail "security finding: customer B's stored name in DB changed from '$NAME_B' to '$db_b_name'" $LINENO

# Cleanup
cv_step Cleanup "delete both created customer accounts" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_9"
