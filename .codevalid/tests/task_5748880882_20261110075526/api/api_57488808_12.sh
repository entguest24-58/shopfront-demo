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
cv_step Given "a customer with a two-product order placed 5 minutes ago" $LINENO
trap cleanup_all EXIT
create_product a 1500 30; PA=$PRODUCT_ID
create_product b 700 30; PB=$PRODUCT_ID
register_and_login owner
OWNER_TOKEN=$TOKEN
place_order "$OWNER_TOKEN" "" "$PA:3" "$PB:2"
backdate_order "$ORDER_ID" "5 minutes"
AMOUNTS_BEFORE=$(psql -qtAX -c "SELECT subtotal_cents||','||discount_cents||','||shipping_cents||','||tax_cents||','||total_cents FROM orders WHERE id = $ORDER_ID" | tr -d '[:space:]')
ITEMS_BEFORE=$(psql -qtAX -c "SELECT string_agg(product_id||':'||quantity||':'||unit_price_cents, ',' ORDER BY product_id) FROM order_items WHERE order_id = $ORDER_ID" | tr -d '[:space:]')
[ -n "$AMOUNTS_BEFORE" ] && [ -n "$ITEMS_BEFORE" ] || cv_fail "expected stored order amounts and items got '$AMOUNTS_BEFORE' / '$ITEMS_BEFORE'" $LINENO
SA_BEFORE=$(product_stock "$PA"); SB_BEFORE=$(product_stock "$PB")
[ "$SA_BEFORE" = "27" ] && [ "$SB_BEFORE" = "28" ] || cv_fail "expected stock 27/28 after placing order got $SA_BEFORE/$SB_BEFORE" $LINENO
TAMPER=$(jq -nc --argjson a "$PA" --argjson b "$PB" '{total_cents:1, subtotal_cents:1, discount_cents:999999, tax_cents:0, items:[{product_id:$a, quantity:500},{product_id:$b, quantity:500}], quantity:500}')

# When
cv_step When "the customer cancels the order while sending new total, discount and quantities" $LINENO
cv_http POST "/orders/$ORDER_ID/cancel" "$TAMPER" -H "Authorization: Bearer $OWNER_TOKEN"

# Then
cv_step Then "the order is cancelled, stored amounts and quantities unchanged, stock restored by the ordered quantities only" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from cancel got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
cv_http GET "/orders/$ORDER_ID" "" -H "Authorization: Bearer $OWNER_TOKEN"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 reading order back got $CV_HTTP_STATUS" $LINENO
ST=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.status')
[ "$ST" = "cancelled" ] || cv_fail "expected order status cancelled got $ST" $LINENO
AMOUNTS_AFTER=$(psql -qtAX -c "SELECT subtotal_cents||','||discount_cents||','||shipping_cents||','||tax_cents||','||total_cents FROM orders WHERE id = $ORDER_ID" | tr -d '[:space:]')
[ "$AMOUNTS_AFTER" = "$AMOUNTS_BEFORE" ] || cv_fail "expected stored amounts unchanged $AMOUNTS_BEFORE got $AMOUNTS_AFTER" $LINENO
ITEMS_AFTER=$(psql -qtAX -c "SELECT string_agg(product_id||':'||quantity||':'||unit_price_cents, ',' ORDER BY product_id) FROM order_items WHERE order_id = $ORDER_ID" | tr -d '[:space:]')
[ "$ITEMS_AFTER" = "$ITEMS_BEFORE" ] || cv_fail "expected stored items unchanged $ITEMS_BEFORE got $ITEMS_AFTER" $LINENO
SA_AFTER=$(product_stock "$PA"); SB_AFTER=$(product_stock "$PB")
[ "$SA_AFTER" = "30" ] || cv_fail "expected product A stock 30 (27+3 ordered) after cancel got $SA_AFTER" $LINENO
[ "$SB_AFTER" = "30" ] || cv_fail "expected product B stock 30 (28+2 ordered) after cancel got $SB_AFTER" $LINENO

# Cleanup
cv_step Cleanup "remove user, order and products created by this test" $LINENO
trap - EXIT
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_57488808_12"
