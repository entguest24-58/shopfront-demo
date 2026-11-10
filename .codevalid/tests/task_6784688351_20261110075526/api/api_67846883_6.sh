#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_coupon_${SUFFIX}@example.com"
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

# cart_with_subtotal <cents>: one product priced at <cents>, quantity 1
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
cv_step Given "a signed-in customer whose cart subtotal is 5000 cents" $LINENO
register_and_login
cart_with_subtotal 5000

# When
cv_step When "the customer applies SAVE10 at checkout" $LINENO
cv_http POST /checkout '{"coupon_code":"SAVE10"}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "the discount is 500 cents and the discounted subtotal is 4500 cents" $LINENO
[ "$CO_STATUS" = "201" ] || cv_fail "expected 201 with SAVE10 accepted got $CO_STATUS: $CO_BODY" $LINENO
ORDER_ID=$(jq -r ".id" <<<"$CO_BODY")
cv_http GET "/orders/$ORDER_ID" "" 200 -H "Authorization: Bearer $TOKEN"
SUB=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY"); DIS=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY"); CC=$(jq -r ".coupon_code" <<<"$CV_HTTP_BODY")
[ "$SUB" = "5000" ] || cv_fail "expected subtotal_cents 5000 got $SUB" $LINENO
[ "$DIS" = "500" ] || cv_fail "expected discount_cents 500 got $DIS" $LINENO
[ "$(( SUB - DIS ))" = "4500" ] || cv_fail "expected discounted subtotal 4500 got $(( SUB - DIS ))" $LINENO
[ "$CC" = "SAVE10" ] || cv_fail "expected coupon_code SAVE10 on the order got $CC" $LINENO

# Cleanup
cv_step Cleanup "remove the customer, order and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_6"
