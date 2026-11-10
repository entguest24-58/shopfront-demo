#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
USER_IDS=()
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <price_cents> <stock> -> echoes id
create_product() {
  sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1
}

# register_and_login <label> -> sets LOGIN_ID and LOGIN_TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com" pw="Passw0rd!${SUFFIX}"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$pw\",\"name\":\"CV $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  LOGIN_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  USER_IDS+=("$LOGIN_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$pw\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  LOGIN_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$LOGIN_TOKEN" ] && [ "$LOGIN_TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

# add_to_cart <token> <product_id> <qty>
add_to_cart() {
  cv_http POST /cart/items "{\"product_id\":$2,\"quantity\":$3}" -H "Authorization: Bearer $1"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product $2 x$3 to cart got $CV_HTTP_STATUS" $LINENO
}

cleanup_all() {
  for uid in "${USER_IDS[@]:-}"; do
    [ -n "$uid" ] && [ "$uid" != "null" ] || continue
    sql "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $uid)" || true
    sql "DELETE FROM orders WHERE user_id = $uid" || true
    sql "DELETE FROM cart_items WHERE user_id = $uid" || true
    sql "DELETE FROM users WHERE id = $uid" || true
  done
  for pid in "${PRODUCT_IDS[@]:-}"; do
    [ -n "$pid" ] && sql "DELETE FROM products WHERE id = $pid" || true
  done
}

# field <json> <jq path>
field() { printf '%s' "$1" | jq -r "$2"; }

# Given
cv_step Given "a signed-in customer with two \$26.00 items in the cart" $LINENO
PA=$(create_product A 2600 10)
[ -n "$PA" ] || cv_fail "expected product row to be created got none" $LINENO
PRODUCT_IDS=("$PA")
register_and_login cust
TOKEN=$LOGIN_TOKEN
add_to_cart "$TOKEN" "$PA" 2

# When
cv_step When "the customer checks out with SAVE10 and their own prices and totals" $LINENO
BODY=$(jq -nc --argjson p "$PA" '{coupon_code:"SAVE10", items:[{product_id:$p, quantity:2, unit_price_cents:1, price_cents:1}], price_cents:1, unit_price_cents:1, subtotal_cents:2, discount_cents:5000, shipping_cents:0, tax_cents:0, total_cents:1}')
cv_http POST /checkout "$BODY" -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "the stored order amounts come from the cart and the rules" $LINENO
[ "$CO_STATUS" = "201" ] || cv_fail "expected 201 from checkout got $CO_STATUS: $CO_BODY" $LINENO
ORDER_ID=$(field "$CO_BODY" '.id')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || cv_fail "expected order id got none" $LINENO
cv_http GET "/orders/$ORDER_ID" "" 200 -H "Authorization: Bearer $TOKEN"
O=$CV_HTTP_BODY
[ "$(field "$O" '.subtotal_cents')" = "5200" ] || cv_fail "expected subtotal_cents 5200 got $(field "$O" '.subtotal_cents')" $LINENO
[ "$(field "$O" '.discount_cents')" = "520" ] || cv_fail "expected discount_cents 520 got $(field "$O" '.discount_cents')" $LINENO
[ "$(field "$O" '.shipping_cents')" = "599" ] || cv_fail "expected shipping_cents 599 got $(field "$O" '.shipping_cents')" $LINENO
[ "$(field "$O" '.tax_cents')" = "374" ] || cv_fail "expected tax_cents 374 got $(field "$O" '.tax_cents')" $LINENO
[ "$(field "$O" '.total_cents')" = "5653" ] || cv_fail "expected total_cents 5653 got $(field "$O" '.total_cents')" $LINENO
UP=$(printf '%s' "$O" | jq -r --argjson p "$PA" '[.items[] | select(.product_id==$p) | .unit_price_cents][0] // empty')
[ "$UP" = "2600" ] || cv_fail "expected order line unit_price_cents 2600 got '$UP'" $LINENO

# Cleanup
cv_step Cleanup "remove the order, customer and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_76497283_12"
