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

EMAIL_A="cv6036_u8_a_${SUFFIX}@example.com"
NAME_A="CV6036 ViewerA ${SUFFIX}"
EMAIL_B="cv6036_u8_b_${SUFFIX}@example.com"
NAME_B="CV6036 TargetB ${SUFFIX}"
PASSWORD="Passw0rd!${SUFFIX: -6}"

# Given
cv_step Given "customer A and customer B registered with distinct profiles, with customer A signed in" $LINENO
cv_http POST /auth/register "$(jq -nc --arg n "$NAME_A" --arg e "$EMAIL_A" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p}')" 201
USER_A_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_A_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user A id got '$USER_A_ID'" $LINENO
CREATED_USER_IDS+=("$USER_A_ID")

cv_http POST /auth/register "$(jq -nc --arg n "$NAME_B" --arg e "$EMAIL_B" --arg p "$PASSWORD" '{name:$n,email:$e,password:$p,role:"vip_customer"}')" 201
USER_B_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
[[ "$USER_B_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric user B id got '$USER_B_ID'" $LINENO
CREATED_USER_IDS+=("$USER_B_ID")
ROLE_B="vip_customer"

cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL_A" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN_A=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN_A" ] || cv_fail "expected session token for customer A got none" $LINENO

cv_http POST /auth/login "$(jq -nc --arg e "$EMAIL_B" --arg p "$PASSWORD" '{email:$e,password:$p}')" 200
TOKEN_B=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
[ -n "$TOKEN_B" ] || cv_fail "expected session token for customer B got none" $LINENO

# When
cv_step When "customer A requests GET /auth/me targeting customer B's id and email" $LINENO
cv_http GET "/auth/me?id=${USER_B_ID}&user_id=${USER_B_ID}&email=${EMAIL_B}" "" -H "Authorization: Bearer $TOKEN_A"
RESP_STATUS="$CV_HTTP_STATUS"
RESP_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "none of customer B's name, email address or role is returned to customer A, and customer B's profile is intact" $LINENO
if printf '%s' "$RESP_BODY" | grep -qF -- "$NAME_B"; then
  cv_fail "security finding: customer B's name '$NAME_B' was returned to customer A: $RESP_BODY" $LINENO
fi
if printf '%s' "$RESP_BODY" | grep -qF -- "$EMAIL_B"; then
  cv_fail "security finding: customer B's email '$EMAIL_B' was returned to customer A: $RESP_BODY" $LINENO
fi
if printf '%s' "$RESP_BODY" | grep -qF -- "$ROLE_B"; then
  cv_fail "security finding: customer B's role '$ROLE_B' was returned to customer A: $RESP_BODY" $LINENO
fi

if [[ "$RESP_STATUS" =~ ^2 ]]; then
  resp_id=$(printf '%s' "$RESP_BODY" | jq -r '.id // empty')
  [ "$resp_id" != "$USER_B_ID" ] || cv_fail "security finding: customer B's id '$USER_B_ID' was returned to customer A: $RESP_BODY" $LINENO
  [ "$resp_id" = "$USER_A_ID" ] || cv_fail "expected customer A's own id '$USER_A_ID' got '$resp_id'" $LINENO
fi

cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN_B"
b_name=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.name // empty')
b_email=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.email // empty')
b_role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.role // empty')
[ "$b_name" = "$NAME_B" ] || cv_fail "expected customer B's own name '$NAME_B' got '$b_name'" $LINENO
[ "$b_email" = "$EMAIL_B" ] || cv_fail "expected customer B's own email '$EMAIL_B' got '$b_email'" $LINENO
[ "$b_role" = "$ROLE_B" ] || cv_fail "expected customer B's own role '$ROLE_B' got '$b_role'" $LINENO

# Cleanup
cv_step Cleanup "delete both created customer accounts" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_60364019_8"
