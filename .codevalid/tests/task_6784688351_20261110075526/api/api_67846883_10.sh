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
cv_step Given "a customer whose cart subtotal is \$99.99 (above SAVE10's \$50.00 minimum)" $LINENO
PA=$(create_product A 9999 10)
[ -n "$PA" ] || cv_fail "expected product row to be created got none" $LINENO
PRODUCT_IDS=("$PA")
register_and_login
add_to_cart "$PA" 1
cv_http GET /coupons/SAVE10 "" 200
SAVE10_MIN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.min_subtotal_cents')
[ "$SAVE10_MIN" -le 9999 ] || cv_fail "expected SAVE10 minimum <= 9999 got $SAVE10_MIN" $LINENO

# When
cv_step When "the customer checks out with WELCOME15" $LINENO
cv_http POST /checkout '{"coupon_code":"WELCOME15"}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "the code is refused, no discounted order exists and the cart is unchanged" $LINENO
case "$CO_STATUS" in
  4??) ;;
  *) cv_fail "expected WELCOME15 at \$99.99 to be refused (4xx) got $CO_STATUS: $CO_BODY" $LINENO ;;
esac
cv_http GET /orders "" 200 -H "Authorization: Bearer $TOKEN"
N=$(printf '%s' "$CV_HTTP_BODY" | jq -r 'if type=="array" then length elif .orders then (.orders|length) elif .items then (.items|length) else 0 end')
[ "$N" = "0" ] || cv_fail "expected no orders after refused coupon got $N: $CV_HTTP_BODY" $LINENO
DB_N=$(sql "SELECT count(*) FROM orders WHERE user_id = $USER_ID" | head -n1)
[ "$DB_N" = "0" ] || cv_fail "expected 0 orders in DB got $DB_N" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
QTY=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PA" '[.items[] | select(.product_id==$p) | .quantity] | first // 0')
[ "$QTY" = "1" ] || cv_fail "expected cart to still hold 1 of product $PA got $QTY" $LINENO

# Cleanup
cv_step Cleanup "remove customer, cart and product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_10"
