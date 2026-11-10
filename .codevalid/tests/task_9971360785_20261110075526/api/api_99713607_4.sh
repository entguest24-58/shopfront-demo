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

EMAIL="jane.cv9971_case_${SUFFIX}@example.com"
EMAIL_VARIANT="Jane.CV9971_Case_${SUFFIX}@Example.COM"
NAME="CV9971 Jane ${SUFFIX}"
PASSWORD="Janepw${SUFFIX: -4}x"

# Given
cv_step Given "an account exists for a lowercase email address" $LINENO
cv_http POST /auth/register "{\"name\":\"$NAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 creating the existing account got $CV_HTTP_STATUS" $LINENO
ORIG_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')

# When
cv_step When "a visitor registers with the same email in different letter case" $LINENO
cv_http POST /auth/register "{\"name\":\"CV9971 Variant ${SUFFIX}\",\"email\":\"$EMAIL_VARIANT\",\"password\":\"Other${SUFFIX: -4}zz\"}"

# Then
cv_step Then "registration is refused and no new account is created" $LINENO
[[ "$CV_HTTP_STATUS" =~ ^4[0-9][0-9]$ ]] || cv_fail "expected 4xx refusal for case-only email variation got $CV_HTTP_STATUS" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "1" ] || cv_fail "expected exactly 1 account for the address (any case) got $n" $LINENO
id=$(sql "SELECT id FROM users WHERE lower(email) = lower('$EMAIL');")
[ "$id" = "$ORIG_ID" ] || cv_fail "expected the only account to be $ORIG_ID got $id" $LINENO

# Cleanup
cv_step Cleanup "delete the account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_4"
