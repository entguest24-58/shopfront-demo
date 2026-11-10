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
cv_step Given "a customer with an order placed 45 minutes ago" $LINENO
trap cleanup_all EXIT
create_product p1 1500 30
P1=$PRODUCT_ID
register_and_login owner
OWNER_TOKEN=$TOKEN
place_order "$OWNER_TOKEN" "" "$P1:4"
backdate_order "$ORDER_ID" "45 minutes"
STOCK_BEFORE=$(product_stock "$P1")
[ "$STOCK_BEFORE" = "26" ] || cv_fail "expected stock 26 after placing order got $STOCK_BEFORE" $LINENO
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# When
cv_step When "the customer cancels with a forged recent placement time, then retries" $LINENO
cv_http POST "/orders/$ORDER_ID/cancel" "$(jq -nc --arg t "$NOW_ISO" '{created_at:$t, placed_at:$t}')" -H "Authorization: Bearer $OWNER_TOKEN"
FIRST_STATUS=$CV_HTTP_STATUS; FIRST_BODY=$CV_HTTP_BODY
cv_http POST "/orders/$ORDER_ID/cancel" "" -H "Authorization: Bearer $OWNER_TOKEN"
SECOND_STATUS=$CV_HTTP_STATUS; SECOND_BODY=$CV_HTTP_BODY

# Then
cv_step Then "both attempts are refused, the order stays uncancelled and stock is not restored" $LINENO
case "$FIRST_STATUS" in 2*) cv_fail "expected cancel with forged placement time refused got $FIRST_STATUS: $FIRST_BODY" $LINENO ;; esac
case "$SECOND_STATUS" in 2*) cv_fail "expected retried cancel refused got $SECOND_STATUS: $SECOND_BODY" $LINENO ;; esac
cv_http GET "/orders/$ORDER_ID" "" -H "Authorization: Bearer $OWNER_TOKEN"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 reading order back got $CV_HTTP_STATUS" $LINENO
ST=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.status')
[ "$ST" = "placed" ] || cv_fail "expected order status placed got $ST" $LINENO
DB_AGE=$(psql -qtAX -c "SELECT (now() - created_at) > interval '30 minutes' FROM orders WHERE id = $ORDER_ID" | tr -d '[:space:]')
[ "$DB_AGE" = "t" ] || cv_fail "expected stored placement time to stay older than 30 minutes got age check '$DB_AGE'" $LINENO
STOCK_AFTER=$(product_stock "$P1")
[ "$STOCK_AFTER" = "$STOCK_BEFORE" ] || cv_fail "expected stock not restored (stay $STOCK_BEFORE) got $STOCK_AFTER" $LINENO

# Cleanup
cv_step Cleanup "remove user, order and products created by this test" $LINENO
trap - EXIT
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_57488808_11"
