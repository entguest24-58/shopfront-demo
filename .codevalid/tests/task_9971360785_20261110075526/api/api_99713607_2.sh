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

PASSWORD="Secret${SUFFIX: -4}x"
E_NONAME="cv9971_noname_${SUFFIX}@example.com"
E_NOPASS="cv9971_nopass_${SUFFIX}@example.com"
N_NOEMAIL="CV9971 NoEmail ${SUFFIX}"

# Given
cv_step Given "registration details each missing one of name, email or password" $LINENO
for e in "$E_NONAME" "$E_NOPASS"; do
  n=$(count_users_email "$e")
  [ "$n" = "0" ] || cv_fail "expected no account for $e before the attempt got $n" $LINENO
done

# When
cv_step When "the visitor tries to register without a name, without an email and without a password" $LINENO
cv_http POST /auth/register "{\"email\":\"$E_NONAME\",\"password\":\"$PASSWORD\"}"
S_NONAME=$CV_HTTP_STATUS
cv_http POST /auth/register "{\"name\":\"$N_NOEMAIL\",\"password\":\"$PASSWORD\"}"
S_NOEMAIL=$CV_HTTP_STATUS
cv_http POST /auth/register "{\"name\":\"CV9971 NoPass ${SUFFIX}\",\"email\":\"$E_NOPASS\"}"
S_NOPASS=$CV_HTTP_STATUS

# Then
cv_step Then "each registration is refused and no account is created" $LINENO
for pair in "name:$S_NONAME" "email:$S_NOEMAIL" "password:$S_NOPASS"; do
  s=${pair#*:}
  [[ "$s" =~ ^4[0-9][0-9]$ ]] || cv_fail "expected 4xx refusal when ${pair%%:*} is missing got $s" $LINENO
done
n=$(count_users_email "$E_NONAME")
[ "$n" = "0" ] || cv_fail "expected no account created without a name got $n" $LINENO
n=$(count_users_email "$E_NOPASS")
[ "$n" = "0" ] || cv_fail "expected no account created without a password got $n" $LINENO
n=$(sql "SELECT count(*) FROM users WHERE name = '$N_NOEMAIL';")
[ "$n" = "0" ] || cv_fail "expected no account created without an email got $n" $LINENO

# Cleanup
cv_step Cleanup "delete any account the attempts created" $LINENO
cleanup_users
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99713607_2"
