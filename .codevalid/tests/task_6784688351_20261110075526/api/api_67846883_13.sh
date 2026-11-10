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
cv_step Given "two users: one with a \$66.67 cart, one with a \$123.45 cart" $LINENO
create_product A 6667; P1="$NEW_PID"
create_product B 12345; P2="$NEW_PID"
EMAIL="cv-cpn-b-${SUFFIX}@example.com"
register_and_login
USER2_ID="$USER_ID"; TOKEN2="$TOKEN"
add_to_cart "$P2" 12345
EMAIL="cv-cpn-a-${SUFFIX}@example.com"
register_and_login
TOKEN1="$TOKEN"
add_to_cart "$P1" 6667

# When
cv_step When "checkout with SAVE10 on \$66.67 and WELCOME15 on \$123.45" $LINENO
cv_http POST /checkout '{"coupon_code":"SAVE10"}' -H "Authorization: Bearer $TOKEN1"
S1_STATUS="$CV_HTTP_STATUS"; S1_BODY="$CV_HTTP_BODY"
cv_http POST /checkout '{"coupon_code":"WELCOME15"}' -H "Authorization: Bearer $TOKEN2"
S2_STATUS="$CV_HTTP_STATUS"; S2_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "discounts are 667 and 1852 cents on the stored orders" $LINENO
[ "$S1_STATUS" = "201" ] || cv_fail "expected 201 for SAVE10 checkout got $S1_STATUS: $S1_BODY" $LINENO
[ "$S2_STATUS" = "201" ] || cv_fail "expected 201 for WELCOME15 checkout got $S2_STATUS: $S2_BODY" $LINENO
O1=$(jq -r ".id" <<<"$S1_BODY"); O2=$(jq -r ".id" <<<"$S2_BODY")
cv_http GET "/orders/$O1" "" 200 -H "Authorization: Bearer $TOKEN1"
D=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY"); S=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$S" = "6667" ] || cv_fail "expected SAVE10 order subtotal_cents 6667 got $S" $LINENO
[ "$D" = "667" ] || cv_fail "expected SAVE10 discount_cents 667 (from 666.7) got $D" $LINENO
cv_http GET "/orders/$O2" "" 200 -H "Authorization: Bearer $TOKEN2"
D=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY"); S=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$S" = "12345" ] || cv_fail "expected WELCOME15 order subtotal_cents 12345 got $S" $LINENO
[ "$D" = "1852" ] || cv_fail "expected WELCOME15 discount_cents 1852 (from 1851.75) got $D" $LINENO

# Cleanup
cv_step Cleanup "remove the user, orders, cart and products" $LINENO
cleanup_all
if [ -n "${USER2_ID:-}" ] && [ "$USER2_ID" != "null" ]; then
  sql "DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $USER2_ID)" || true
  sql "DELETE FROM orders WHERE user_id = $USER2_ID" || true
  sql "DELETE FROM cart_items WHERE user_id = $USER2_ID" || true
  sql "DELETE FROM users WHERE id = $USER2_ID" || true
fi
for p in $PRODUCT_IDS; do sql "DELETE FROM products WHERE id = $p" || true; done
echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_13"
