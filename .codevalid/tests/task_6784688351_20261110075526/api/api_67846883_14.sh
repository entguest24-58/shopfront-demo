#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_coupon_tamper_${SUFFIX}@example.com"
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
cv_step Given "a signed-in shopper whose cart subtotal is 8000 cents (\$80.00)" $LINENO
register_and_login
cart_with_subtotal 8000

# When
cv_step When "the shopper checks out with SAVE10 while also sending 90% off and a \$70.00 discount" $LINENO
TAMPER_BODY='{"coupon_code":"SAVE10","percent_off":90,"percentOff":90,"discount_percent":90,"discount_cents":7000,"discount":7000,"total_cents":1000}'
cv_http POST /checkout "$TAMPER_BODY" -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "client-supplied discount values are ignored and the discount is 800 cents (\$8.00)" $LINENO
[ "$CO_STATUS" = "201" ] || cv_fail "expected 201 from checkout with SAVE10 got $CO_STATUS: $CO_BODY" $LINENO
CO_DIS=$(jq -r ".discount_cents" <<<"$CO_BODY")
[ "$CO_DIS" = "800" ] || cv_fail "expected checkout discount_cents 800 (not client-supplied 7000 or 90%) got $CO_DIS" $LINENO
ORDER_ID=$(jq -r ".id" <<<"$CO_BODY")
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || cv_fail "expected order id got none" $LINENO
cv_http GET "/orders/$ORDER_ID" "" 200 -H "Authorization: Bearer $TOKEN"
SUB=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
DIS=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY")
CC=$(jq -r ".coupon_code" <<<"$CV_HTTP_BODY")
[ "$SUB" = "8000" ] || cv_fail "expected stored subtotal_cents 8000 got $SUB" $LINENO
[ "$DIS" = "800" ] || cv_fail "expected stored discount_cents 800 from SAVE10's 10% benefit got $DIS" $LINENO
[ "$(( SUB - DIS ))" = "7200" ] || cv_fail "expected discounted subtotal 7200 got $(( SUB - DIS ))" $LINENO
[ "$CC" = "SAVE10" ] || cv_fail "expected coupon_code SAVE10 got $CC" $LINENO

# Cleanup
cv_step Cleanup "remove the shopper, order and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_14"
