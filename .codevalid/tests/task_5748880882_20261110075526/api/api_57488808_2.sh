#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd-${SUFFIX}"
CREATED_USERS=()
CREATED_PRODUCTS=()

# register_and_login <label> -> sets USER_ID, TOKEN
register_and_login() {
  local email="cv-${1}-${SUFFIX}@example.com"
  cv_http POST /auth/register "$(jq -nc --arg e "$email" --arg p "$PASSWORD" --arg n "CV $1" '{email:$e,password:$p,name:$n}')"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  CREATED_USERS+=("$USER_ID")
  cv_http POST /auth/login "$(jq -nc --arg e "$email" --arg p "$PASSWORD" '{email:$e,password:$p}')"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
}

# create_product <label> <price_cents> <stock> -> sets PRODUCT_ID
create_product() {
  PRODUCT_ID=$(psql -qtAX -v ON_ERROR_STOP=1 -c "INSERT INTO products (sku, name, category, price_cents, stock) VALUES ('CV-${1}-${SUFFIX}', 'CV ${1} ${SUFFIX}', 'cvtest', ${2}, ${3}) RETURNING id" | head -n1 | tr -d '[:space:]')
  _cv_is_int "$PRODUCT_ID" || cv_fail "expected product row to be created got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCTS+=("$PRODUCT_ID")
}

# place_order <token> <coupon|''> <product_id:qty>... -> sets ORDER_ID, ORDER_BODY
place_order() {
  local tok="$1" coupon="$2"; shift 2
  local pq
  for pq in "$@"; do
    cv_http POST /cart/items "$(jq -nc --argjson p "${pq%%:*}" --argjson q "${pq##*:}" '{product_id:$p,quantity:$q}')" -H "Authorization: Bearer $tok"
    [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 adding product to cart got $CV_HTTP_STATUS" $LINENO
  done
  if [ -n "$coupon" ]; then
    cv_http POST /checkout "$(jq -nc --arg c "$coupon" '{coupon_code:$c}')" -H "Authorization: Bearer $tok"
  else
    cv_http POST /checkout '{}' -H "Authorization: Bearer $tok"
  fi
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 from checkout got $CV_HTTP_STATUS" $LINENO
  ORDER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  ORDER_BODY="$CV_HTTP_BODY"
  _cv_is_int "$ORDER_ID" || cv_fail "expected an order id from checkout got '$ORDER_ID'" $LINENO
}

# backdate_order <order_id> <interval>
backdate_order() {
  psql -qtAX -v ON_ERROR_STOP=1 -c "UPDATE orders SET created_at = now() - interval '${2}' WHERE id = ${1}" >/dev/null \
    || cv_fail "expected to backdate order $1 by $2" $LINENO
}

product_stock() {
  psql -qtAX -v ON_ERROR_STOP=1 -c "SELECT stock FROM products WHERE id = ${1}" | head -n1 | tr -d '[:space:]'
}

cleanup_all() {
  local ids
  if [ ${#CREATED_USERS[@]} -gt 0 ]; then
    ids=$(IFS=,; echo "${CREATED_USERS[*]}")
    psql -qtAX -c "DELETE FROM orders WHERE user_id IN (${ids}); DELETE FROM cart_items WHERE user_id IN (${ids}); DELETE FROM users WHERE id IN (${ids});" >/dev/null || true
  fi
  if [ ${#CREATED_PRODUCTS[@]} -gt 0 ]; then
    ids=$(IFS=,; echo "${CREATED_PRODUCTS[*]}")
    psql -qtAX -c "DELETE FROM order_items WHERE product_id IN (${ids}); DELETE FROM cart_items WHERE product_id IN (${ids}); DELETE FROM products WHERE id IN (${ids});" >/dev/null || true
  fi
}

# Given
cv_step Given "a customer who placed an order with two items and coupon SAVE10" $LINENO
trap cleanup_all EXIT
create_product a 2500 20; PA=$PRODUCT_ID
create_product b 1250 20; PB=$PRODUCT_ID
register_and_login owner
OWNER_TOKEN=$TOKEN
place_order "$OWNER_TOKEN" "SAVE10" "$PA:1" "$PB:2"
# subtotal 5000, discount 500, shipping 599 (4500 < 5000), tax round(4500*0.08)=360, total 5459
cv_prereq "checkout recorded expected totals" $LINENO
for f in subtotal_cents:5000 discount_cents:500 shipping_cents:599 tax_cents:360 total_cents:5459; do
  v=$(printf '%s' "$ORDER_BODY" | jq -r ".${f%%:*}")
  [ "$v" = "${f##*:}" ] || cv_fail "expected checkout ${f%%:*}=${f##*:} got $v" $LINENO
done

# When
cv_step When "the customer opens their own order" $LINENO
cv_http GET "/orders/$ORDER_ID" "" -H "Authorization: Bearer $OWNER_TOKEN"

# Then
cv_step Then "the order shows its items, discount, shipping, tax and total as recorded" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from GET /orders/$ORDER_ID got $CV_HTTP_STATUS" $LINENO
B="$CV_HTTP_BODY"
[ "$(printf '%s' "$B" | jq -r '.id')" = "$ORDER_ID" ] || cv_fail "expected id $ORDER_ID got $(printf '%s' "$B" | jq -r '.id')" $LINENO
for f in discount_cents:500 shipping_cents:599 tax_cents:360 total_cents:5459; do
  v=$(printf '%s' "$B" | jq -r ".${f%%:*}")
  [ "$v" = "${f##*:}" ] || cv_fail "expected ${f%%:*}=${f##*:} got $v" $LINENO
done
N=$(printf '%s' "$B" | jq '.items | length')
[ "$N" = "2" ] || cv_fail "expected 2 items got $N" $LINENO
IA=$(printf '%s' "$B" | jq -c --argjson p "$PA" '.items[] | select(.product_id == $p) | {u:.unit_price_cents,q:.quantity}')
[ "$IA" = '{"u":2500,"q":1}' ] || cv_fail "expected item A unit 2500 qty 1 got $IA" $LINENO
IB=$(printf '%s' "$B" | jq -c --argjson p "$PB" '.items[] | select(.product_id == $p) | {u:.unit_price_cents,q:.quantity}')
[ "$IB" = '{"u":1250,"q":2}' ] || cv_fail "expected item B unit 1250 qty 2 got $IB" $LINENO
WANT_ITEMS=$(printf '%s' "$ORDER_BODY" | jq -c '[.items[] | {product_id,name,unit_price_cents,quantity}] | sort_by(.product_id)')
GOT_ITEMS=$(printf '%s' "$B" | jq -c '[.items[] | {product_id,name,unit_price_cents,quantity}] | sort_by(.product_id)')
[ "$WANT_ITEMS" = "$GOT_ITEMS" ] || cv_fail "expected items as placed $WANT_ITEMS got $GOT_ITEMS" $LINENO

# Cleanup
cv_step Cleanup "remove user, order and products created by this test" $LINENO
trap - EXIT
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_57488808_2"
