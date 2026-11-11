#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX}"
USER_IDS=()
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

create_product() {
  local pid
  pid=$(sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1)
  [ -n "$pid" ] || cv_fail "expected a product id for $1 got none" $LINENO
  PRODUCT_IDS+=("$pid")
  printf '%s' "$pid"
}

register_and_login() {
  local email="cv_bola_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"CV Shopper $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  LOGIN_ID=$(jq -r ".id" <<<"$CV_HTTP_BODY")
  USER_IDS+=("$LOGIN_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  LOGIN_TOKEN=$(jq -r ".token" <<<"$CV_HTTP_BODY")
  [ -n "$LOGIN_TOKEN" ] && [ "$LOGIN_TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

add_to_cart() {
  cv_http POST /cart/items "{\"product_id\":$2,\"quantity\":$3}" -H "Authorization: Bearer $1"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product $2 to cart got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
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

# Given
cv_step Given "shopper B with an 8000-cent (\$80.00) cart and shopper A signed in separately" $LINENO
PB=$(create_product B 8000 10)
register_and_login b
B_ID=$LOGIN_ID; B_TOKEN=$LOGIN_TOKEN
add_to_cart "$B_TOKEN" "$PB" 1
cv_http GET /cart "" 200 -H "Authorization: Bearer $B_TOKEN"
B_CART_BEFORE=$(jq -c '{items: [.items[] | {product_id, quantity, line_total_cents}], subtotal_cents}' <<<"$CV_HTTP_BODY")
register_and_login a
A_TOKEN=$LOGIN_TOKEN

# When
cv_step When "shopper A attempts to apply SAVE10 to and clear the coupon on shopper B's cart" $LINENO
APPLY_BODY=$(jq -nc --argjson bid "$B_ID" '{coupon_code:"SAVE10", user_id:$bid, userId:$bid, cart_id:$bid, customer_id:$bid}')
cv_http POST /checkout "$APPLY_BODY" -H "Authorization: Bearer $A_TOKEN"
APPLY_STATUS=$CV_HTTP_STATUS; APPLY_BODY_RESP=$CV_HTTP_BODY
REMOVE_BODY=$(jq -nc --argjson bid "$B_ID" '{coupon_code:null, user_id:$bid, userId:$bid, cart_id:$bid, customer_id:$bid}')
cv_http POST /checkout "$REMOVE_BODY" -H "Authorization: Bearer $A_TOKEN"
REMOVE_STATUS=$CV_HTTP_STATUS; REMOVE_BODY_RESP=$CV_HTTP_BODY

# Then
cv_step Then "shopper B's cart and order state are unchanged and B can check out without A's coupon" $LINENO
[ "$APPLY_STATUS" != "201" ] || cv_fail "expected shopper A's attempt to apply SAVE10 on B's cart not to place an order got 201: $APPLY_BODY_RESP" $LINENO
[ "$REMOVE_STATUS" != "201" ] || cv_fail "expected shopper A's attempt to remove coupon on B's cart not to place an order got 201: $REMOVE_BODY_RESP" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $B_TOKEN"
B_CART_AFTER=$(jq -c '{items: [.items[] | {product_id, quantity, line_total_cents}], subtotal_cents}' <<<"$CV_HTTP_BODY")
[ "$B_CART_AFTER" = "$B_CART_BEFORE" ] || cv_fail "expected shopper B's cart unchanged ($B_CART_BEFORE) got $B_CART_AFTER" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $B_TOKEN"
B_ORDERS=$(jq ".items | length" <<<"$CV_HTTP_BODY")
[ "$B_ORDERS" = "0" ] || cv_fail "expected 0 orders for shopper B after A's attempts got $B_ORDERS" $LINENO
cv_http POST /checkout '{}' -H "Authorization: Bearer $B_TOKEN"
[ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected shopper B's own checkout without coupon to return 201 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
B_ORDER_ID=$(jq -r ".id" <<<"$CV_HTTP_BODY")
cv_http GET "/orders/$B_ORDER_ID" "" 200 -H "Authorization: Bearer $B_TOKEN"
B_DIS=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY")
B_CC=$(jq -r ".coupon_code" <<<"$CV_HTTP_BODY")
[ "$B_DIS" = "0" ] || cv_fail "expected shopper B's order discount_cents 0 (unaffected by A's SAVE10) got $B_DIS" $LINENO
[ "$B_CC" = "null" ] || [ -z "$B_CC" ] || cv_fail "expected shopper B's order coupon_code null got $B_CC" $LINENO

# Cleanup
cv_step Cleanup "remove both shoppers, orders and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_15"
