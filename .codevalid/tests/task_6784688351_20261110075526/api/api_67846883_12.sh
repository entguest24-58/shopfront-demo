#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv-cpn-${SUFFIX}@example.com"
PASSWORD="CvPassw0rd!${SUFFIX}"
USER_ID=""
TOKEN=""
PRODUCT_IDS=""

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

create_product() {
  local id
  id=$(sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, 10) RETURNING id" | head -n1)
  [ -n "$id" ] || cv_fail "expected a product id got none" $LINENO
  PRODUCT_IDS="$PRODUCT_IDS $id"
  NEW_PID="$id"
}

register_and_login() {
  cv_http POST /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"CV Customer\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(jq -r ".id" <<<"$CV_HTTP_BODY")
  cv_http POST /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(jq -r ".token" <<<"$CV_HTTP_BODY")
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

add_to_cart() {
  cv_http POST /cart/items "{\"product_id\":$1,\"quantity\":1}" -H "Authorization: Bearer $TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product $1 to cart got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  local st
  st=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
  [ "$st" = "$2" ] || cv_fail "expected cart subtotal_cents $2 got $st" $LINENO
}

cleanup_all() {
  if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    sql "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $USER_ID)" || true
    sql "DELETE FROM orders WHERE user_id = $USER_ID" || true
    sql "DELETE FROM cart_items WHERE user_id = $USER_ID" || true
    sql "DELETE FROM users WHERE id = $USER_ID" || true
  fi
  for p in $PRODUCT_IDS; do sql "DELETE FROM products WHERE id = $p" || true; done
}

# Given
cv_step Given "a registered user with a \$200.00 cart" $LINENO
register_and_login
create_product A 20000; P1="$NEW_PID"
add_to_cart "$P1" 20000

# When
cv_step When "checkout applying the nonexistent code SAVE99" $LINENO
cv_http POST /checkout '{"coupon_code":"SAVE99"}' -H "Authorization: Bearer $TOKEN"
CHECKOUT_STATUS="$CV_HTTP_STATUS"
CHECKOUT_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "the code is refused, no order is placed and the cart subtotal is unchanged" $LINENO
case "$CHECKOUT_STATUS" in 4??) ;; *) cv_fail "expected a 4xx refusal for SAVE99 got $CHECKOUT_STATUS: $CHECKOUT_BODY" $LINENO ;; esac
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
S=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$S" = "20000" ] || cv_fail "expected cart subtotal_cents 20000 got $S" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $TOKEN"
N=$(jq -r ".items | length" <<<"$CV_HTTP_BODY")
[ "$N" = "0" ] || cv_fail "expected no orders after refused code got $N" $LINENO

# Cleanup
cv_step Cleanup "remove the user, cart and product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_12"
