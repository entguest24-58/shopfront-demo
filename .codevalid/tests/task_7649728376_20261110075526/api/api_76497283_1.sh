#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_checkout_${SUFFIX}@example.com"
PASSWORD="Passw0rd!${SUFFIX}"
USER_ID=""
TOKEN=""
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <price_cents> <stock> -> echoes id
create_product() {
  sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1
}

stock_of() { sql "SELECT stock FROM products WHERE id = $1" | head -n1; }

register_and_login() {
  cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Customer\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

add_to_cart() {
  cv_http POST /cart/items "{\"product_id\":$1,\"quantity\":$2}" -H "Authorization: Bearer $TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product $1 x$2 to cart got $CV_HTTP_STATUS" $LINENO
}

cleanup_all() {
  if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    sql "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $USER_ID)" || true
    sql "DELETE FROM orders WHERE user_id = $USER_ID" || true
    sql "DELETE FROM cart_items WHERE user_id = $USER_ID" || true
    sql "DELETE FROM users WHERE id = $USER_ID" || true
  fi
  for pid in "${PRODUCT_IDS[@]:-}"; do
    [ -n "$pid" ] && sql "DELETE FROM products WHERE id = $pid" || true
  done
}

# Given
cv_step Given "a signed-in customer with two in-stock products in the cart" $LINENO
cv_prereq "create products and customer" $LINENO
PA=$(create_product A 1500 10); PB=$(create_product B 2500 7)
[ -n "$PA" ] && [ -n "$PB" ] || cv_fail "expected product rows to be created got none" $LINENO
PRODUCT_IDS=("$PA" "$PB")
register_and_login
add_to_cart "$PA" 3
add_to_cart "$PB" 2

# When
cv_step When "the customer checks out" $LINENO
cv_http POST /checkout '{}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "an order holds the cart contents, stock is deducted and the cart is empty" $LINENO
[ "$CO_STATUS" = "201" ] || cv_fail "expected 201 from checkout got $CO_STATUS: $CO_BODY" $LINENO
ORDER_ID=$(printf '%s' "$CO_BODY" | jq -r '.id')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || cv_fail "expected order id in checkout response got none" $LINENO
cv_http GET "/orders/$ORDER_ID" "" 200 -H "Authorization: Bearer $TOKEN"
QA=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PA" '[.items[] | select(.product_id==$p) | .quantity][0] // empty')
QB=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PB" '[.items[] | select(.product_id==$p) | .quantity][0] // empty')
[ "$QA" = "3" ] || cv_fail "expected order line for product A with quantity 3 got '$QA'" $LINENO
[ "$QB" = "2" ] || cv_fail "expected order line for product B with quantity 2 got '$QB'" $LINENO
N=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$N" = "2" ] || cv_fail "expected 2 order lines got $N" $LINENO
cv_http GET "/products/$PA" "" 200
SA=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.stock')
[ "$SA" = "7" ] || cv_fail "expected product A stock 7 (10-3) got $SA" $LINENO
cv_http GET "/products/$PB" "" 200
SB=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.stock')
[ "$SB" = "5" ] || cv_fail "expected product B stock 5 (7-2) got $SB" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
CN=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$CN" = "0" ] || cv_fail "expected empty cart after checkout got $CN lines" $LINENO

# Cleanup
cv_step Cleanup "remove the order, customer and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_76497283_1"
