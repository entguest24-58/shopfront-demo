#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
CAT="cvcat-rm-${SUFFIX}"
ADMIN_EMAIL="cv-admin-${SUFFIX}@example.com"
ADMIN_PASS="CvAdminPass123!"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <name> <category> -> sets NEW_ID
create_product() {
  NEW_ID=$(sql "INSERT INTO products (sku, name, description, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', '$2', 'cv removal test', '$3', 1500, 4) RETURNING id" | head -n1 | tr -d '[:space:]')
  [ -n "$NEW_ID" ] || cv_fail "expected product $1 to be inserted got no id" $LINENO
}

# admin_login -> sets ADMIN_TOKEN (registers a user, promotes it to admin in the DB, logs in)
admin_login() {
  cv_prereq "register and promote an admin" $LINENO
  cv_http POST /auth/register "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\",\"name\":\"CV Admin\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering admin got $CV_HTTP_STATUS $CV_HTTP_BODY" $LINENO
  sql "UPDATE users SET role = 'admin' WHERE email = '${ADMIN_EMAIL}'" >/dev/null
  cv_http POST /auth/login "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in admin got $CV_HTTP_STATUS" $LINENO
  ADMIN_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token // empty')
  [ -n "$ADMIN_TOKEN" ] || cv_fail "expected admin token got none" $LINENO
}

# remove_product <id>
remove_product() {
  cv_http DELETE "/products/$1" -H "Authorization: Bearer ${ADMIN_TOKEN}"
  [ "$CV_HTTP_STATUS" = "204" ] || cv_fail "expected 204 removing product $1 got $CV_HTTP_STATUS $CV_HTTP_BODY" $LINENO
}

cleanup_all() {
  sql "DELETE FROM products WHERE sku LIKE 'CV-${SUFFIX}-%'" >/dev/null 2>&1 || true
  sql "DELETE FROM users WHERE email = '${ADMIN_EMAIL}'" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

# Given
cv_step Given "a product that was viewable by its direct link and then removed" $LINENO
create_product GONE "CV Direct Link ${SUFFIX}" "$CAT"; GONE_ID=$NEW_ID
cv_prereq "product is reachable by its direct link before removal" $LINENO
cv_http GET "/products/${GONE_ID}"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for product before removal got $CV_HTTP_STATUS" $LINENO
admin_login
remove_product "$GONE_ID"

# When
cv_step When "a visitor opens the removed product's direct link" $LINENO
cv_http GET "/products/${GONE_ID}"

# Then
cv_step Then "the product details are not returned and the visitor is told it is not available" $LINENO
[ "$CV_HTTP_STATUS" = "404" ] || cv_fail "expected 404 not available for removed product got $CV_HTTP_STATUS $CV_HTTP_BODY" $LINENO
LEAK=$(printf '%s' "$CV_HTTP_BODY" | jq -r '(.name // empty), (.sku // empty), (.price_cents // empty)' 2>/dev/null || true)
[ -z "$LEAK" ] || cv_fail "expected no product details in response got $LEAK" $LINENO
ERR=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.error // empty' 2>/dev/null || true)
[ -n "$ERR" ] || cv_fail "expected an error message telling the visitor the product is unavailable got $CV_HTTP_BODY" $LINENO

# Cleanup
cv_step Cleanup "delete the test product and admin user" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_12"
