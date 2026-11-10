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
cv_step Given "customer A with one saved product and a second unsaved product" $LINENO
register_and_login a; TOK_A=$TOKEN; UA=$UID_OUT
create_product p1; P1=$PID; create_product p2; P2=$PID
cv_http POST /wishlist/items "{\"product_id\":$P1}" -H "Authorization: Bearer $TOK_A"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 saving for A got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO

# When
cv_step When "an anonymous visitor tries to save, view and remove wishlist products" $LINENO
cv_http POST /wishlist/items "{\"product_id\":$P2,\"user_id\":$UA}"
SAVE_STATUS=$CV_HTTP_STATUS
cv_http GET "/wishlist?user_id=$UA"
VIEW_STATUS=$CV_HTTP_STATUS; VIEW_BODY=$CV_HTTP_BODY
cv_http DELETE "/wishlist/items/$P1?user_id=$UA"
DEL_STATUS=$CV_HTTP_STATUS

# Then
cv_step Then "nothing is saved or removed and no wishlist contents are returned" $LINENO
[[ "$SAVE_STATUS" != 2* ]] || cv_fail "expected anonymous save refused got $SAVE_STATUS" $LINENO
[[ "$VIEW_STATUS" != 2* ]] || cv_fail "expected anonymous view refused got $VIEW_STATUS" $LINENO
[[ "$DEL_STATUS" != 2* ]] || cv_fail "expected anonymous remove refused got $DEL_STATUS" $LINENO
grep -q "Wishlist p1 $SUFFIX" <<<"$VIEW_BODY" && cv_fail "expected no wishlist contents for anonymous got: $VIEW_BODY" $LINENO
cv_http GET /wishlist "" 200 -H "Authorization: Bearer $TOK_A"
[ "$(count_in "$CV_HTTP_BODY" "$P1")" = "1" ] || cv_fail "expected A's product $P1 still saved got $CV_HTTP_BODY" $LINENO
[ "$(count_in "$CV_HTTP_BODY" "$P2")" = "0" ] || cv_fail "expected product $P2 not saved got $CV_HTTP_BODY" $LINENO

# Cleanup
cv_step Cleanup "remove the wishlist rows, products and user" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_64236697_11"
