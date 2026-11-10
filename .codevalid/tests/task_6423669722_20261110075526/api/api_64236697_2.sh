#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
USER_IDS=()
PRODUCT_IDS=()

# register_and_login <label>: registers a customer via the API, sets TOKEN and UID_OUT
register_and_login() {
  local email="wl_${1}_${SUFFIX}@example.test"
  cv_prereq "register customer $1" $LINENO
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"Wishlist $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $1 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  UID_OUT=$(jq -r '.id' <<<"$CV_HTTP_BODY")
  USER_IDS+=("$UID_OUT")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $1 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  TOKEN=$(jq -r '.token' <<<"$CV_HTTP_BODY")
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token for $1 got none" $LINENO
}

# create_product <label>: inserts an active product row, sets PID
create_product() {
  cv_prereq "create product $1" $LINENO
  PID=$(psql -tAq -v ON_ERROR_STOP=1 -c "INSERT INTO products (sku, name, category, price_cents, stock, active) VALUES ('WL-$1-$SUFFIX', 'Wishlist $1 $SUFFIX', 'test', 1999, 5, true) RETURNING id" | head -n1 | tr -d '[:space:]')
  [[ "$PID" =~ ^[0-9]+$ ]] || cv_fail "expected a product id for $1 got '$PID'" $LINENO
  PRODUCT_IDS+=("$PID")
}

# db_count <user_id> <product_id>: rows in wishlist_items
db_count() { psql -tAq -c "SELECT count(*) FROM wishlist_items WHERE user_id=$1 AND product_id=$2" | tr -d '[:space:]'; }

# count_in <json> <product_id>: occurrences of the product in .items
count_in() { jq --argjson p "$2" '[.items[]? | select(.product_id == $p)] | length' <<<"$1"; }

cleanup_all() {
  for u in "${USER_IDS[@]}"; do psql -q -c "DELETE FROM wishlist_items WHERE user_id=$u" >/dev/null || true; done
  for p in "${PRODUCT_IDS[@]}"; do psql -q -c "DELETE FROM wishlist_items WHERE product_id=$p" >/dev/null || true; psql -q -c "DELETE FROM products WHERE id=$p" >/dev/null || true; done
  for u in "${USER_IDS[@]}"; do psql -q -c "DELETE FROM users WHERE id=$u" >/dev/null || true; done
}

# Given
cv_step Given "a signed-in customer who has saved three products" $LINENO
register_and_login a; TOK_A=$TOKEN
create_product p1; P1=$PID; create_product p2; P2=$PID; create_product p3; P3=$PID
for p in "$P1" "$P2" "$P3"; do
  cv_http POST /wishlist/items "{\"product_id\":$p}" -H "Authorization: Bearer $TOK_A"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 saving $p got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
done

# When
cv_step When "the customer views their wishlist" $LINENO
cv_http GET /wishlist "" -H "Authorization: Bearer $TOK_A"

# Then
cv_step Then "every saved product is returned" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
for p in "$P1" "$P2" "$P3"; do
  N=$(count_in "$CV_HTTP_BODY" "$p")
  [ "$N" = "1" ] || cv_fail "expected product $p once in wishlist got $N: $CV_HTTP_BODY" $LINENO
done
TOTAL=$(jq '.items | length' <<<"$CV_HTTP_BODY")
[ "$TOTAL" = "3" ] || cv_fail "expected 3 items got $TOTAL" $LINENO

# Cleanup
cv_step Cleanup "remove the wishlist rows, products and user" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_64236697_2"
