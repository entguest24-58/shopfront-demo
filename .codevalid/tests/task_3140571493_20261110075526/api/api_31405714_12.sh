#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
CREATED_USER_IDS=()
CREATED_PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# register_and_login <label> -> sets USER_ID and TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"CV $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  [[ "$USER_ID" =~ ^[0-9]+$ ]] || cv_fail "expected a user id registering $email got '$USER_ID'" $LINENO
  CREATED_USER_IDS+=("$USER_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
}

# create_product <label> <price_cents> <stock> -> sets PRODUCT_ID
create_product() {
  PRODUCT_ID=$(sql "INSERT INTO products (sku, name, description, category, price_cents, stock) VALUES ('CV-$1-$SUFFIX', 'CV $1 $SUFFIX', 'codevalid test', 'testing', $2, $3) RETURNING id;" | head -n1)
  [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]] || cv_fail "expected a product id inserting product $1 got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCT_IDS+=("$PRODUCT_ID")
}

cleanup_all() {
  local u p
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM cart_items WHERE user_id = $u; DELETE FROM users WHERE id = $u;" >/dev/null || true
  done
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM cart_items WHERE product_id = $p; DELETE FROM products WHERE id = $p;" >/dev/null || true
  done
}
trap cleanup_all EXIT

# line_field <json> <product_id> <field>
line_field() { printf '%s' "$1" | jq -r --argjson p "$2" "[.items[] | select(.product_id == \$p)][0].$3 // \"absent\""; }
line_count() { printf '%s' "$1" | jq -r --argjson p "$2" '[.items[] | select(.product_id == $p)] | length'; }

# Given
cv_step Given "a signed-in customer with an empty cart and a product priced 4999 cents" $LINENO
register_and_login a
A_ID=$USER_ID; A_TOKEN=$TOKEN
create_product p1 4999 10
P1=$PRODUCT_ID
cv_http GET /cart "" 200 -H "Authorization: Bearer $A_TOKEN"
[ "$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')" = "0" ] || cv_fail "expected empty cart got $CV_HTTP_BODY" $LINENO

# When
cv_step When "the customer adds 2 units supplying their own price and line total" $LINENO
cv_http POST /cart/items "{\"product_id\":$P1,\"quantity\":2,\"price_cents\":1,\"unit_price_cents\":1,\"line_total_cents\":2,\"subtotal_cents\":2}" -H "Authorization: Bearer $A_TOKEN"
echo "add status: $CV_HTTP_STATUS"

# Then
cv_step Then "the cart line and subtotal use the product's real price" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $A_TOKEN"
n=$(line_count "$CV_HTTP_BODY" "$P1")
if [ "$n" != "0" ]; then
  q=$(line_field "$CV_HTTP_BODY" "$P1" quantity)
  up=$(line_field "$CV_HTTP_BODY" "$P1" unit_price_cents)
  lt=$(line_field "$CV_HTTP_BODY" "$P1" line_total_cents)
  sub=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.subtotal_cents')
  [ "$up" = "4999" ] || cv_fail "expected unit price 4999 got $up" $LINENO
  expected_lt=$((4999 * q))
  [ "$lt" = "$expected_lt" ] || cv_fail "expected line total $expected_lt got $lt" $LINENO
  [ "$sub" = "$expected_lt" ] || cv_fail "expected subtotal $expected_lt got $sub" $LINENO
fi
price=$(sql "SELECT price_cents FROM products WHERE id = $P1;")
[ "$price" = "4999" ] || cv_fail "expected product price to stay 4999 got $price" $LINENO

# Cleanup
cv_step Cleanup "delete the test user, cart lines and product" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_31405714_12"
