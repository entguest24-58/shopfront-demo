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
  local email="cv_round_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"CV Customer $1\"}"
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
cv_step Given "customer 1 with a 6667-cent (\$66.67) cart and customer 2 with a 12345-cent (\$123.45) cart" $LINENO
P1=$(create_product R1 6667 10)
P2=$(create_product R2 12345 10)
register_and_login u1
T1=$LOGIN_TOKEN
add_to_cart "$T1" "$P1" 1
ST1=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$ST1" = "6667" ] || cv_fail "expected cart 1 subtotal_cents 6667 got $ST1" $LINENO
register_and_login u2
T2=$LOGIN_TOKEN
add_to_cart "$T2" "$P2" 1
ST2=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$ST2" = "12345" ] || cv_fail "expected cart 2 subtotal_cents 12345 got $ST2" $LINENO

# When
cv_step When "customer 1 applies SAVE10 and customer 2 applies WELCOME15 at checkout" $LINENO
cv_http POST /checkout '{"coupon_code":"SAVE10"}' -H "Authorization: Bearer $T1"
S1_STATUS=$CV_HTTP_STATUS; S1_BODY=$CV_HTTP_BODY
cv_http POST /checkout '{"coupon_code":"WELCOME15"}' -H "Authorization: Bearer $T2"
S2_STATUS=$CV_HTTP_STATUS; S2_BODY=$CV_HTTP_BODY

# Then
cv_step Then "discounts round to the nearest cent: 667 cents (\$6.67) for SAVE10 and 1852 cents (\$18.52) for WELCOME15" $LINENO
[ "$S1_STATUS" = "201" ] || cv_fail "expected 201 for SAVE10 on 6667 cents got $S1_STATUS: $S1_BODY" $LINENO
[ "$S2_STATUS" = "201" ] || cv_fail "expected 201 for WELCOME15 on 12345 cents got $S2_STATUS: $S2_BODY" $LINENO
O1=$(jq -r ".id" <<<"$S1_BODY")
O2=$(jq -r ".id" <<<"$S2_BODY")
cv_http GET "/orders/$O1" "" 200 -H "Authorization: Bearer $T1"
SUB1=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
DIS1=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY")
[ "$SUB1" = "6667" ] || cv_fail "expected order 1 subtotal_cents 6667 got $SUB1" $LINENO
[ "$DIS1" = "667" ] || cv_fail "expected SAVE10 discount_cents rounded to 667 got $DIS1" $LINENO
cv_http GET "/orders/$O2" "" 200 -H "Authorization: Bearer $T2"
SUB2=$(jq -r ".subtotal_cents" <<<"$CV_HTTP_BODY")
DIS2=$(jq -r ".discount_cents" <<<"$CV_HTTP_BODY")
[ "$SUB2" = "12345" ] || cv_fail "expected order 2 subtotal_cents 12345 got $SUB2" $LINENO
[ "$DIS2" = "1852" ] || cv_fail "expected WELCOME15 discount_cents rounded to 1852 got $DIS2" $LINENO

# Cleanup
cv_step Cleanup "remove both customers, orders and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_13"
