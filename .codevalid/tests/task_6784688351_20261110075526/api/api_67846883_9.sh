#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_welcome_${SUFFIX}@example.com"
PASSWORD="Passw0rd!${SUFFIX}"
USER_ID=""
TOKEN=""
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

create_product() {
  sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1
}

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
cv_step Given "a customer whose cart subtotal is exactly \$100.00" $LINENO
PA=$(create_product A 5000 10)
[ -n "$PA" ] || cv_fail "expected product row to be created got none" $LINENO
PRODUCT_IDS=("$PA")
register_and_login
add_to_cart "$PA" 2
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"

# When
cv_step When "the customer checks out with WELCOME15" $LINENO
cv_http POST /checkout '{"coupon_code":"WELCOME15"}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "the code is accepted and the stored order has subtotal 10000 and discount 1500" $LINENO
[ "$CO_STATUS" = "201" ] || cv_fail "expected 201 from checkout with WELCOME15 at \$100.00 got $CO_STATUS: $CO_BODY" $LINENO
ORDER_ID=$(printf '%s' "$CO_BODY" | jq -r '.id')
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || cv_fail "expected an order id got none: $CO_BODY" $LINENO
cv_http GET "/orders/$ORDER_ID" "" 200 -H "Authorization: Bearer $TOKEN"
B=$CV_HTTP_BODY
got=$(printf '%s' "$B" | jq -r '.subtotal_cents')
[ "$got" = "10000" ] || cv_fail "expected subtotal_cents=10000 got $got" $LINENO
got=$(printf '%s' "$B" | jq -r '.discount_cents')
[ "$got" = "1500" ] || cv_fail "expected discount_cents=1500 got $got" $LINENO
got=$(printf '%s' "$B" | jq -r '.coupon_code')
[ "$got" = "WELCOME15" ] || cv_fail "expected coupon_code=WELCOME15 got $got" $LINENO

# Cleanup
cv_step Cleanup "remove order, customer and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_9"
