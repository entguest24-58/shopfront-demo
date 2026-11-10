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

EMAIL="cv9971_pw6_${SUFFIX}@example.com"
NAME="CV9971 Pw ${SUFFIX}"
PASSWORD='abcdefghijk'

# Given
cv_step Given "an unused email and a password that is 11 characters long with no digit" $LINENO
[ ${#PASSWORD} -eq 11 ] || cv_fail "expected test password of length 11 got ${#PASSWORD}" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "0" ] || cv_fail "expected no account for $EMAIL before registering got $n" $LINENO

# When
cv_step When "the visitor registers with that password" $LINENO
cv_http POST /auth/register "{\"name\":\"$NAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"

# Then
cv_step Then "the password is rejected and no account is created" $LINENO
[ "$CV_HTTP_STATUS" = "400" ] || [ "$CV_HTTP_STATUS" = "422" ] || cv_fail "expected 400/422 rejecting the password got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
err=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // .message // empty')
printf '%s' "$err" | grep -qi 'password' || cv_fail "expected an error about the password got '$CV_HTTP_BODY'" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "0" ] || cv_fail "expected no account created got $n" $LINENO

# Cleanup
cv_step Cleanup "delete any created account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_6"
