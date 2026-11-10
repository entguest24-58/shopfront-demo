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
cv_step Given "customer A with an order placed 5 minutes ago, and customer B signed in" $LINENO
trap cleanup_all EXIT
create_product p1 2345 40
P1=$PRODUCT_ID
register_and_login custa
A_TOKEN=$TOKEN
place_order "$A_TOKEN" "" "$P1:3"
A_ORDER=$ORDER_ID
A_TOTAL=$(printf '%s' "$ORDER_BODY" | jq -r '.total_cents')
backdate_order "$A_ORDER" "5 minutes"
register_and_login custb
B_TOKEN=$TOKEN
STOCK_BEFORE=$(product_stock "$P1")
[ "$STOCK_BEFORE" = "37" ] || cv_fail "expected stock 37 after A's order got $STOCK_BEFORE" $LINENO

# When
cv_step When "customer B tries to cancel customer A's order" $LINENO
cv_http POST "/orders/$A_ORDER/cancel" "" -H "Authorization: Bearer $B_TOKEN"

# Then
cv_step Then "the cancellation is refused without revealing the order, A's order stays placed and stock is unchanged" $LINENO
case "$CV_HTTP_STATUS" in
  2*) cv_fail "expected B's cancellation of A's order to be refused got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO ;;
esac
if printf '%s' "$CV_HTTP_BODY" | jq -e 'type == "object" and (has("status") or has("total_cents") or has("items") or has("user_id") or has("created_at") or has("cancelled_at"))' >/dev/null 2>&1; then
  cv_fail "expected refusal to reveal nothing about the order got $CV_HTTP_BODY" $LINENO
fi
if printf '%s' "$CV_HTTP_BODY" | grep -q -e "custa-${SUFFIX}" -e "\"$A_TOTAL\"" -e ":$A_TOTAL[,}]"; then
  cv_fail "expected refusal to reveal nothing about A's order got $CV_HTTP_BODY" $LINENO
fi
cv_http GET "/orders/$A_ORDER" "" -H "Authorization: Bearer $A_TOKEN"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 reading A's order as A got $CV_HTTP_STATUS" $LINENO
ST=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.status')
[ "$ST" = "placed" ] || cv_fail "expected A's order to stay placed got $ST" $LINENO
CA=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.cancelled_at')
[ "$CA" = "null" ] || cv_fail "expected A's order cancelled_at null got $CA" $LINENO
STOCK_AFTER=$(product_stock "$P1")
[ "$STOCK_AFTER" = "$STOCK_BEFORE" ] || cv_fail "expected stock unchanged at $STOCK_BEFORE got $STOCK_AFTER" $LINENO

# Cleanup
cv_step Cleanup "remove users, orders and products created by this test" $LINENO
trap - EXIT
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_57488808_10"
