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

EMAIL="cv9971_dup_${SUFFIX}@example.com"
NAME="CV9971 Original ${SUFFIX}"
PASSWORD="Origin${SUFFIX: -4}x"
PASSWORD2="Second${SUFFIX: -4}y"

# Given
cv_step Given "an account already exists for the email address" $LINENO
cv_http POST /auth/register "{\"name\":\"$NAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 creating the existing account got $CV_HTTP_STATUS" $LINENO
ORIG_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
ORIG_HASH=$(sql "SELECT password_hash FROM users WHERE id = $ORIG_ID;")

# When
cv_step When "a visitor registers again with exactly the same email" $LINENO
cv_http POST /auth/register "{\"name\":\"CV9971 Intruder ${SUFFIX}\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD2\"}"

# Then
cv_step Then "registration is refused and the existing account is unchanged" $LINENO
[[ "$CV_HTTP_STATUS" =~ ^4[0-9][0-9]$ ]] || cv_fail "expected 4xx refusal for duplicate email got $CV_HTTP_STATUS" $LINENO
n=$(count_users_email "$EMAIL")
[ "$n" = "1" ] || cv_fail "expected exactly 1 account for $EMAIL got $n" $LINENO
row=$(sql "SELECT id || '|' || name || '|' || role FROM users WHERE lower(email) = lower('$EMAIL');")
[ "$row" = "$ORIG_ID|$NAME|customer" ] || cv_fail "expected existing account '$ORIG_ID|$NAME|customer' got '$row'" $LINENO
h=$(sql "SELECT password_hash FROM users WHERE id = $ORIG_ID;")
[ "$h" = "$ORIG_HASH" ] || cv_fail "expected password hash unchanged got a different one" $LINENO
cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected original password still to log in (200) got $CV_HTTP_STATUS" $LINENO

# Cleanup
cv_step Cleanup "delete the account" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_3"
