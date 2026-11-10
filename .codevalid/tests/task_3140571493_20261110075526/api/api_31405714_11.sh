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
cv_step Given "a customer with product P1 x1 in their cart and a second product P2" $LINENO
register_and_login a
A_ID=$USER_ID; A_TOKEN=$TOKEN
create_product p1 900 10
P1=$PRODUCT_ID
create_product p2 700 10
P2=$PRODUCT_ID
cv_http POST /cart/items "{\"product_id\":$P1,\"quantity\":1}" 201 -H "Authorization: Bearer $A_TOKEN"
CART_ROWS_BEFORE=$(sql "SELECT count(*) FROM cart_items WHERE product_id IN ($P1, $P2);")
[ "$CART_ROWS_BEFORE" = "1" ] || cv_fail "expected 1 cart row for the test products before the attempt got $CART_ROWS_BEFORE" $LINENO

# When
cv_step When "an anonymous visitor tries to add P2 and to remove P1 without a token" $LINENO
cv_http POST /cart/items "{\"product_id\":$P2,\"quantity\":1,\"user_id\":$A_ID}"
ADD_STATUS=$CV_HTTP_STATUS
cv_http DELETE "/cart/items/$P1"
DEL_STATUS=$CV_HTTP_STATUS

# Then
cv_step Then "both attempts are refused and no cart was changed" $LINENO
case "$ADD_STATUS" in 2*) cv_fail "expected anonymous add to be refused got $ADD_STATUS" $LINENO ;; esac
case "$DEL_STATUS" in 2*) cv_fail "expected anonymous remove to be refused got $DEL_STATUS" $LINENO ;; esac
n2=$(sql "SELECT count(*) FROM cart_items WHERE product_id = $P2;")
[ "$n2" = "0" ] || cv_fail "expected no cart row for P2 got $n2" $LINENO
cv_http GET /cart "" 200 -H "Authorization: Bearer $A_TOKEN"
q=$(line_field "$CV_HTTP_BODY" "$P1" quantity)
[ "$q" = "1" ] || cv_fail "expected customer's P1 quantity 1 got $q" $LINENO
[ "$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')" = "1" ] || cv_fail "expected customer's cart to hold 1 line got $CV_HTTP_BODY" $LINENO

# Cleanup
cv_step Cleanup "delete the test user, cart lines and products" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_31405714_11"
