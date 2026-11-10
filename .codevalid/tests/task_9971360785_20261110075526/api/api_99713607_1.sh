#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
# count_users_email <email> -> number of accounts whose email matches case-insensitively
count_users_email() { sql "SELECT count(*) FROM users WHERE lower(email) = lower('$1');"; }
cleanup_users() { sql "DELETE FROM users WHERE email LIKE '%cv9971_%_${SUFFIX}@example.com' OR name LIKE 'CV9971 % ${SUFFIX}';" >/dev/null || true; }
trap cleanup_users EXIT

EMAIL="cv9971_new_${SUFFIX}@example.com"
NAME="CV9971 Visitor ${SUFFIX}"
PASSWORD="Secret${SUFFIX: -4}x"

# Given
cv_step Given "an unused email address and valid registration details" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "0" ] || cv_fail "expected no account for $EMAIL before registering got $n" $LINENO

# When
cv_step When "the visitor registers with name, email and password" $LINENO
cv_http POST /auth/register "{\"name\":\"$NAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO

# Then
cv_step Then "the account exists with that name and email and the customer role" $LINENO
role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.role')
[ "$role" = "customer" ] || cv_fail "expected role customer in register response got $role" $LINENO
printf '%s' "$CV_HTTP_BODY" | jq -e 'has("password") or has("password_hash") | not' >/dev/null || cv_fail "expected no password in response got $CV_HTTP_BODY" $LINENO
cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 200
TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
cv_http GET /auth/me "" 200 -H "Authorization: Bearer $TOKEN"
got_name=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.name')
got_email=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.email')
got_role=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.role')
[ "$got_name" = "$NAME" ] || cv_fail "expected name '$NAME' got '$got_name'" $LINENO
[ "$got_email" = "$EMAIL" ] || cv_fail "expected email '$EMAIL' got '$got_email'" $LINENO
[ "$got_role" = "customer" ] || cv_fail "expected role customer got '$got_role'" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "1" ] || cv_fail "expected exactly 1 account for $EMAIL got $n" $LINENO

# Cleanup
cv_step Cleanup "delete the created account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_1"
