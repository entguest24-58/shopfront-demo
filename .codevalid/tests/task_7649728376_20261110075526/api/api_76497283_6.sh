#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
EMAIL="cv_checkout_${SUFFIX}@example.com"
PASSWORD="Passw0rd!${SUFFIX}"
USER_ID=""
TOKEN=""
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <price_cents> <stock> -> echoes id
create_product() {
  sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1
}

stock_of() { sql "SELECT stock FROM products WHERE id = $1" | head -n1; }

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
cv_step Given "a cart with 3 of A and 1 of B, then A's stock falls to 2" $LINENO
PA=$(create_product A 1200 5); PB=$(create_product B 800 4)
[ -n "$PA" ] && [ -n "$PB" ] || cv_fail "expected product rows to be created got none" $LINENO
PRODUCT_IDS=("$PA" "$PB")
register_and_login
add_to_cart "$PA" 3
add_to_cart "$PB" 1
cv_prereq "drop product A stock to 2" $LINENO
sql "UPDATE products SET stock = 2 WHERE id = $PA" >/dev/null
[ "$(stock_of "$PA")" = "2" ] || cv_fail "expected product A stock set to 2 got $(stock_of "$PA")" $LINENO

# When
cv_step When "the customer checks out" $LINENO
cv_http POST /checkout '{}' -H "Authorization: Bearer $TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY

# Then
cv_step Then "checkout is refused naming A with available 2; nothing changes" $LINENO
case "$CO_STATUS" in 4??) ;; *) cv_fail "expected a 4xx refusal got $CO_STATUS: $CO_BODY" $LINENO ;; esac
AV=$(printf '%s' "$CO_BODY" | jq -r --argjson p "$PA" '[.. | objects | select(.product_id? == $p) | .available][0] // empty')
[ "$AV" = "2" ] || cv_fail "expected response to identify product A with available 2 got '$AV': $CO_BODY" $LINENO
HASB=$(printf '%s' "$CO_BODY" | jq -r --argjson p "$PB" '[.. | objects | select(.product_id? == $p)] | length')
[ "$HASB" = "0" ] || cv_fail "expected product B (in stock) not listed as short got it listed: $CO_BODY" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $TOKEN"
ON=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$ON" = "0" ] || cv_fail "expected no order created got $ON" $LINENO
cv_http GET "/products/$PA" "" 200
SA=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.stock')
[ "$SA" = "2" ] || cv_fail "expected product A stock unchanged at 2 got $SA" $LINENO
cv_http GET "/products/$PB" "" 200
SB=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.stock')
[ "$SB" = "4" ] || cv_fail "expected product B stock unchanged at 4 got $SB" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $TOKEN"
CA=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PA" '[.items[] | select(.product_id==$p) | .quantity][0] // empty')
CB=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PB" '[.items[] | select(.product_id==$p) | .quantity][0] // empty')
[ "$CA" = "3" ] && [ "$CB" = "1" ] || cv_fail "expected cart to still hold A x3 and B x1 got A='$CA' B='$CB'" $LINENO

# Cleanup
cv_step Cleanup "remove customer, cart and products" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_76497283_6"
