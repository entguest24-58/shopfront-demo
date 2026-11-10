#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
USER_IDS=()
PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <price_cents> <stock> -> echoes id
create_product() {
  sql "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', 'CV Product $1 ${SUFFIX}', 'testing', $2, $3) RETURNING id" | head -n1
}

# register_and_login <label> -> sets LOGIN_ID and LOGIN_TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com" pw="Passw0rd!${SUFFIX}"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$pw\",\"name\":\"CV $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from register got $CV_HTTP_STATUS" $LINENO
  LOGIN_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  USER_IDS+=("$LOGIN_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$pw\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from login got $CV_HTTP_STATUS" $LINENO
  LOGIN_TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$LOGIN_TOKEN" ] && [ "$LOGIN_TOKEN" != "null" ] || cv_fail "expected a login token got none" $LINENO
}

# add_to_cart <token> <product_id> <qty>
add_to_cart() {
  cv_http POST /cart/items "{\"product_id\":$2,\"quantity\":$3}" -H "Authorization: Bearer $1"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product $2 x$3 to cart got $CV_HTTP_STATUS" $LINENO
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

# field <json> <jq path>
field() { printf '%s' "$1" | jq -r "$2"; }

# Given
cv_step Given "customer B with a product in their cart and customer A with an empty cart" $LINENO
PA=$(create_product A 1200 10)
[ -n "$PA" ] || cv_fail "expected product row to be created got none" $LINENO
PRODUCT_IDS=("$PA")
register_and_login custb
B_ID=$LOGIN_ID; B_TOKEN=$LOGIN_TOKEN
add_to_cart "$B_TOKEN" "$PA" 3
register_and_login custa
A_TOKEN=$LOGIN_TOKEN

# When
cv_step When "customer A checks out naming customer B's cart" $LINENO
cv_http POST /checkout "{\"user_id\":$B_ID,\"cart_id\":$B_ID,\"customer_id\":$B_ID}" -H "Authorization: Bearer $A_TOKEN"
CO_STATUS=$CV_HTTP_STATUS; CO_BODY=$CV_HTTP_BODY
echo "checkout by A returned $CO_STATUS: $CO_BODY"

# Then
cv_step Then "no order from B's cart, B's cart unchanged, stock not deducted" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $B_TOKEN"
BQ=$(printf '%s' "$CV_HTTP_BODY" | jq -r --argjson p "$PA" '[.items[] | select(.product_id==$p) | .quantity][0] // empty')
BN=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$BQ" = "3" ] && [ "$BN" = "1" ] || cv_fail "expected B's cart to still hold product x3 (1 line) got qty '$BQ' in $BN lines" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $B_TOKEN"
BO=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$BO" = "0" ] || cv_fail "expected no orders for B got $BO" $LINENO
cv_http GET /orders "" 200 -H "Authorization: Bearer $A_TOKEN"
AO=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$AO" = "0" ] || cv_fail "expected no order created for A from B's cart got $AO" $LINENO
cv_http GET "/products/$PA" "" 200
S=$(field "$CV_HTTP_BODY" '.stock')
[ "$S" = "10" ] || cv_fail "expected stock unchanged at 10 got $S" $LINENO
[ "$CO_STATUS" != "201" ] || cv_fail "expected checkout by A to be refused got 201: $CO_BODY" $LINENO

# Cleanup
cv_step Cleanup "remove both customers, any orders and the product" $LINENO
cleanup_all

echo "CODEVALID_TEST_ASSERTION_OK:api_76497283_11"
