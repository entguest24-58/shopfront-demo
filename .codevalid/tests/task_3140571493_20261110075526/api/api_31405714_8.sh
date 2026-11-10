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
cv_step Given "customer A with a cart line and customer B with an empty cart" $LINENO
register_and_login a; A_ID=$USER_ID; A_TOKEN=$TOKEN
register_and_login b; B_ID=$USER_ID; B_TOKEN=$TOKEN
create_product secret 4321 10
cv_http POST /cart/items "{\"product_id\":$PRODUCT_ID,\"quantity\":3}" 201 -H "Authorization: Bearer $A_TOKEN"

# When
cv_step When "customer B requests the cart (the only cart route; scoped by token)" $LINENO
cv_http GET /cart "" -H "Authorization: Bearer $B_TOKEN"
B_STATUS=$CV_HTTP_STATUS
B_BODY=$CV_HTTP_BODY

# Then
cv_step Then "none of A's lines, quantities or totals are returned to B, and A's cart is intact" $LINENO
if [[ "$B_STATUS" =~ ^2 ]]; then
  n=$(printf '%s' "$B_BODY" | jq --argjson p "$PRODUCT_ID" '[.items[]? | select(.product_id == $p)] | length')
  [ "$n" = "0" ] || cv_fail "expected A's product absent from B's cart got $B_BODY" $LINENO
  if printf '%s' "$B_BODY" | grep -q "CV secret $SUFFIX\|12963"; then cv_fail "expected none of A's cart data in B's response got $B_BODY" $LINENO; fi
fi
cv_http GET /cart "" 200 -H "Authorization: Bearer $A_TOKEN"
q=$(line_field "$CV_HTTP_BODY" "$PRODUCT_ID" quantity)
[ "$q" = "3" ] || cv_fail "expected A's cart still to hold quantity 3 got $q" $LINENO

# Cleanup
cv_step Cleanup "delete both users, cart lines and the product" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_31405714_8"
