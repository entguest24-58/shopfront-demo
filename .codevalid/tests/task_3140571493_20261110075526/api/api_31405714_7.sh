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
cv_step Given "a cart with 1 unit at 12.50 and 1 unit at 3.00, viewed once" $LINENO
register_and_login a
create_product a 1250 10; P1=$PRODUCT_ID
create_product b 300 10; P2=$PRODUCT_ID
cv_http POST /cart/items "{\"product_id\":$P1,\"quantity\":1}" 201 -H "Authorization: Bearer $TOKEN"
cv_http POST /cart/items "{\"product_id\":$P2,\"quantity\":1}" 201 -H "Authorization: Bearer $TOKEN"
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
[ "$(line_field "$CV_HTTP_BODY" "$P1" line_total_cents)" = "1250" ] || cv_fail "expected initial line total 1250 got $CV_HTTP_BODY" $LINENO
[ "$(printf '%s' "$CV_HTTP_BODY" | jq -r .subtotal_cents)" = "1550" ] || cv_fail "expected initial subtotal 1550 got $CV_HTTP_BODY" $LINENO

# When
cv_step When "the customer adds another unit of the first product" $LINENO
cv_http POST /cart/items "{\"product_id\":$P1,\"quantity\":1}" -H "Authorization: Bearer $TOKEN"
[[ "$CV_HTTP_STATUS" =~ ^2 ]] || cv_fail "expected 2xx adding another unit got $CV_HTTP_STATUS" $LINENO

# Then
cv_step Then "viewing the cart again shows quantity 2, line total 25.00 and subtotal 28.00" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
q=$(line_field "$CV_HTTP_BODY" "$P1" quantity)
[ "$q" = "2" ] || cv_fail "expected quantity 2 got $q" $LINENO
[ "$(line_count "$CV_HTTP_BODY" "$P1")" = "1" ] || cv_fail "expected a single line for product got $CV_HTTP_BODY" $LINENO
l1=$(line_field "$CV_HTTP_BODY" "$P1" line_total_cents)
[ "$l1" = "2500" ] || cv_fail "expected line_total_cents 2500 got $l1" $LINENO
l2=$(line_field "$CV_HTTP_BODY" "$P2" line_total_cents)
[ "$l2" = "300" ] || cv_fail "expected untouched line_total_cents 300 got $l2" $LINENO
sub=$(printf '%s' "$CV_HTTP_BODY" | jq -r .subtotal_cents)
[ "$sub" = "2800" ] || cv_fail "expected subtotal_cents 2800 got $sub" $LINENO

# Cleanup
cv_step Cleanup "delete the test user, cart lines and products" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_31405714_7"
