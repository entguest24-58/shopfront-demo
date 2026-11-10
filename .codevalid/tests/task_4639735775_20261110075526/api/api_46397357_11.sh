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
cv_step Given "a removed product and an active sibling sharing its category and name words" $LINENO
WORD="Zephyrcv${SUFFIX}"
create_product GONE "CV ${WORD} Removed Lamp" "$CAT"; GONE_ID=$NEW_ID
create_product KEEP "CV ${WORD} Kept Lamp" "$CAT"; KEEP_ID=$NEW_ID
admin_login
remove_product "$GONE_ID"

# When
cv_step When "a visitor searches the catalog for words in the removed product's name" $LINENO
cv_http GET "/products?q=${WORD}%20Removed"
SEARCH_STATUS=$CV_HTTP_STATUS; SEARCH_BODY=$CV_HTTP_BODY

# Then
cv_step Then "search, browse and category filtering all leave the removed product out" $LINENO
[ "$SEARCH_STATUS" = "200" ] || cv_fail "expected 200 for search got $SEARCH_STATUS" $LINENO
HIT=$(printf '%s' "$SEARCH_BODY" | jq --argjson id "$GONE_ID" '[.items[] | select(.id == $id)] | length')
[ "$HIT" = "0" ] || cv_fail "expected removed product $GONE_ID absent from search for its full name words got it listed" $LINENO
cv_http GET "/products?q=${WORD}"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for word search got $CV_HTTP_STATUS" $LINENO
IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
jq -e --argjson id "$GONE_ID" 'index($id) == null' <<<"$IDS" >/dev/null || cv_fail "expected removed product $GONE_ID absent from word search got $IDS" $LINENO
jq -e --argjson id "$KEEP_ID" 'index($id) != null' <<<"$IDS" >/dev/null || cv_fail "expected active sibling $KEEP_ID in word search got $IDS" $LINENO
cv_http GET "/products?category=${CAT}"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for category filter got $CV_HTTP_STATUS" $LINENO
IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
jq -e --argjson id "$GONE_ID" 'index($id) == null' <<<"$IDS" >/dev/null || cv_fail "expected removed product $GONE_ID absent from category filter got $IDS" $LINENO
jq -e --argjson id "$KEEP_ID" 'index($id) != null' <<<"$IDS" >/dev/null || cv_fail "expected active sibling $KEEP_ID in category filter got $IDS" $LINENO
TOTAL=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.total // empty')
if [ -n "$TOTAL" ]; then [ "$TOTAL" = "1" ] || cv_fail "expected category total 1 after removal got $TOTAL" $LINENO; fi
# Browse: walk the unfiltered catalog at the maximum page size (bounded by total)
cv_http GET "/products?page=1&page_size=100"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for browse got $CV_HTTP_STATUS" $LINENO
TOTAL=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.total')
PAGES=$(( (TOTAL + 99) / 100 ))
ALL=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
for ((p=2; p<=PAGES && p<=20; p++)); do
  cv_http GET "/products?page=${p}&page_size=100"
  ALL=$(jq -c --argjson more "$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')" '. + $more' <<<"$ALL")
done
jq -e --argjson id "$GONE_ID" 'index($id) == null' <<<"$ALL" >/dev/null || cv_fail "expected removed product $GONE_ID absent from catalog browse" $LINENO
jq -e --argjson id "$KEEP_ID" 'index($id) != null' <<<"$ALL" >/dev/null || cv_fail "expected active sibling $KEEP_ID present in catalog browse" $LINENO

# Cleanup
cv_step Cleanup "delete the test products and admin user" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_11"
