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
cv_step Given "a signed-in customer whose cart holds two products" $LINENO
register_and_login a
create_product keep 1000 10; KEEP=$PRODUCT_ID
create_product drop 550 10; DROP=$PRODUCT_ID
cv_http POST /cart/items "{\"product_id\":$KEEP,\"quantity\":2}" 201 -H "Authorization: Bearer $TOKEN"
cv_http POST /cart/items "{\"product_id\":$DROP,\"quantity\":1}" 201 -H "Authorization: Bearer $TOKEN"
sub=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.subtotal_cents')
[ "$sub" = "2550" ] || cv_fail "expected starting subtotal 2550 got $sub" $LINENO

# When
cv_step When "the customer removes one of the products" $LINENO
cv_http DELETE "/cart/items/$DROP" "" -H "Authorization: Bearer $TOKEN"
[[ "$CV_HTTP_STATUS" =~ ^2 ]] || cv_fail "expected 2xx removing product got $CV_HTTP_STATUS" $LINENO

# Then
cv_step Then "the cart holds only the other product and the subtotal excludes the removed line" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
[ "$(line_count "$CV_HTTP_BODY" "$DROP")" = "0" ] || cv_fail "expected removed product $DROP absent from cart got $CV_HTTP_BODY" $LINENO
[ "$(line_count "$CV_HTTP_BODY" "$KEEP")" = "1" ] || cv_fail "expected kept product $KEEP still in cart got $CV_HTTP_BODY" $LINENO
n=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$n" = "1" ] || cv_fail "expected 1 line in cart got $n" $LINENO
q=$(line_field "$CV_HTTP_BODY" "$KEEP" quantity)
[ "$q" = "2" ] || cv_fail "expected kept product quantity 2 got $q" $LINENO
sub=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.subtotal_cents')
[ "$sub" = "2000" ] || cv_fail "expected subtotal_cents 2000 after removal got $sub" $LINENO

# Cleanup
cv_step Cleanup "delete the test user, cart lines and products" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_31405714_5"
