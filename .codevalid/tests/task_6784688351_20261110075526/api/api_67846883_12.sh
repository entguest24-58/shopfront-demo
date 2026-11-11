#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_coupon_unknown_${SUFFIX}@example.com"
PASSWORD="Passw0rd!${SUFFIX}"
USER_ID=""
TOKEN=""
PRODUCT_ID=""

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

register_and_login() {
  cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Customer\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(jq -r ".id" <<<"$CV_HTTP_BODY")
  cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(jq -r ".token" <<<"$CV_HTTP_BODY")
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

cart_with_subtotal() {
  PRODUCT_ID=$(sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-CPN-${SUFFIX}', 'CV Coupon Product ${SUFFIX}', 'testing', $1, 10) RETURNING id" | head -n1)
  [ -n "$PRODUCT_ID" ] || cv_fail "expected a product id got none" $LINENO
  cv_http POST /cart/items "{\"product_id\":$PRODUCT_ID,\"quantity\":1}" -H "Authorization: Bearer $TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding to cart got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  ST=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
  [ "$ST" = "$1" ] || cv_fail "expected cart subtotal_cents $1 got $ST" $LINENO
}

cleanup_all() {
  if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    sql "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $USER_ID)" || true
    sql "DELETE FROM orders WHERE user_id = $USER_ID" || true
    sql "DELETE FROM cart_items WHERE user_id = $USER_ID" || true
    sql "DELETE FROM users WHERE id = $USER_ID" || true
  fi
  [ -z "$PRODUCT_ID" ] || sql "DELETE FROM products WHERE id = $PRODUCT_ID" || true
}

# Given
cv_step Given "a signed-in customer whose cart subtotal is 20000 cents (\$200.00)" $LINENO
register_and_login
cart_with_subtotal 20000

# When
cv_step When "the customer applies the nonexistent code SAVE99 at checkout" $LINENO
cv_http POST /checkout '{"coupon_code":"SAVE99"}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "SAVE99 is refused, no order is created and the cart subtotal stays 20000 cents" $LINENO
case "$CO_STATUS" in
  4??) ;;
  *) cv_fail "expected a 4xx refusal of nonexistent code SAVE99 got $CO_STATUS: $CO_BODY" $LINENO ;;
esac
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
SUB=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$SUB" = "20000" ] || cv_fail "expected cart subtotal_cents unchanged at 20000 got $SUB" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $TOKEN"
ON=$(jq ".items | length" <<<"$CV_HTTP_BODY")
[ "$ON" = "0" ] || cv_fail "expected no orders after refused code SAVE99 got $ON" $LINENO

# Cleanup
cv_step Cleanup "remove the customer, cart items and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_12"
