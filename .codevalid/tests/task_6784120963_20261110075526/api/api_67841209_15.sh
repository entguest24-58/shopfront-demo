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

# register_and_login <label> -> sets USER_ID, USER_NAME and TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com"
  USER_NAME="CV $1 $SUFFIX"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"$USER_NAME\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  CREATED_USER_IDS+=("$USER_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
}

# create_product <label> -> sets PRODUCT_ID
create_product() {
  PRODUCT_ID=$(sql "INSERT INTO products (sku, name, description, category, price_cents, stock) VALUES ('CV-$1-$SUFFIX', 'CV $1 $SUFFIX', 'codevalid test', 'testing', 1000, 10) RETURNING id;" | head -n1)
  [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]] || cv_fail "expected a product id inserting product $1 got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCT_IDS+=("$PRODUCT_ID")
}

# record_purchase <user_id> <product_id>: a placed order containing the product
record_purchase() {
  local oid
  oid=$(sql "INSERT INTO orders (user_id, subtotal_cents, tax_cents, total_cents) VALUES ($1, 1000, 0, 1000) RETURNING id;" | head -n1)
  [[ "$oid" =~ ^[0-9]+$ ]] || cv_fail "expected an order id for user $1 got '$oid'" $LINENO
  sql "INSERT INTO order_items (order_id, product_id, name, unit_price_cents, quantity) VALUES ($oid, $2, 'CV item', 1000, 1);" >/dev/null \
    || cv_fail "expected order item for product $2 to be inserted" $LINENO
}

review_count() { sql "SELECT count(*) FROM reviews WHERE user_id = $1 AND product_id = $2;" | head -n1; }

cleanup_all() {
  local u p
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM reviews WHERE product_id = $p;" >/dev/null || true
  done
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM reviews WHERE user_id = $u; DELETE FROM orders WHERE user_id = $u; DELETE FROM cart_items WHERE user_id = $u; DELETE FROM users WHERE id = $u;" >/dev/null || true
  done
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM order_items WHERE product_id = $p; DELETE FROM products WHERE id = $p;" >/dev/null || true
  done
}
trap cleanup_all EXIT

# Given
cv_step Given "two customers who both bought the product, neither has reviewed it" $LINENO
create_product p1
register_and_login victim; V_ID="$USER_ID"; V_T="$TOKEN"; V_NAME="$USER_NAME"; record_purchase "$V_ID" "$PRODUCT_ID"
register_and_login attacker; A_ID="$USER_ID"; A_T="$TOKEN"; A_NAME="$USER_NAME"; record_purchase "$A_ID" "$PRODUCT_ID"

# When
cv_step When "the attacker submits a review naming the victim as author" $LINENO
cv_http POST "/products/$PRODUCT_ID/reviews" "{\"rating\":1,\"comment\":\"spoof $SUFFIX\",\"user_id\":$V_ID,\"userId\":$V_ID,\"author\":\"$V_NAME\",\"author_id\":$V_ID}" -H "Authorization: Bearer $A_T"
SPOOF_STATUS="$CV_HTTP_STATUS"

# Then
cv_step Then "no review is attributed to the victim and the victim can still review" $LINENO
[ "$(review_count "$V_ID" "$PRODUCT_ID")" = "0" ] || cv_fail "expected no review stored under the victim got one (spoof status $SPOOF_STATUS)" $LINENO
case "$SPOOF_STATUS" in
  2*) [ "$(review_count "$A_ID" "$PRODUCT_ID")" = "1" ] || cv_fail "expected accepted review attributed to the submitter" $LINENO ;;
esac
cv_http GET "/products/$PRODUCT_ID/reviews" "" 200
n=$(printf '%s' "$CV_HTTP_BODY" | jq --arg a "$V_NAME" '[.items[] | select(.author == $a)] | length')
[ "$n" = "0" ] || cv_fail "expected no listed review authored by the victim got $n" $LINENO
cv_http POST "/products/$PRODUCT_ID/reviews" '{"rating":5,"comment":"victim own"}' -H "Authorization: Bearer $V_T"
[ "$CV_HTTP_STATUS" = "201" ] || [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected victim's own review accepted got $CV_HTTP_STATUS ($CV_HTTP_BODY)" $LINENO

# Cleanup
cv_step Cleanup "delete the test reviews, orders, users and products" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_67841209_15"
