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
CREATED_SKUS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }
jf() { printf '%s' "$CV_HTTP_BODY" | jq -r "$1"; }

# register_and_login <label> <role customer|admin> -> sets USER_ID and TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "$(jq -nc --arg e "$email" --arg p "$PASSWORD" --arg n "CV $1" '{email:$e,password:$p,name:$n}')"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(jf '.id')
  CREATED_USER_IDS+=("$USER_ID")
  if [ "$2" = "admin" ]; then
    sql "UPDATE users SET role = 'admin' WHERE id = $USER_ID;" >/dev/null
  fi
  cv_http POST /auth/login "$(jq -nc --arg e "$email" --arg p "$PASSWORD" '{email:$e,password:$p}')"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(jf '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
  [ "$(jf '.user.role')" = "$2" ] || cv_fail "expected role $2 for $email got $(jf '.user.role')" $LINENO
}

# admin_create_product <sku> <name> <price_cents> <stock> -> sets PRODUCT_ID (Given only)
admin_create_product() {
  CREATED_SKUS+=("$1")
  cv_http POST /products "$(jq -nc --arg s "$1" --arg n "$2" --argjson p "$3" --argjson st "$4" '{sku:$s,name:$n,description:"codevalid test",category:"cvtest",price_cents:$p,stock:$st}')" -H "Authorization: Bearer $ADMIN_TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 creating product $1 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  PRODUCT_ID=$(jf '.id')
  _cv_is_int "$PRODUCT_ID" || cv_fail "expected numeric product id got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCT_IDS+=("$PRODUCT_ID")
}

cleanup_all() {
  local u p s
  for s in "${CREATED_SKUS[@]:-}"; do
    [ -n "$s" ] && sql "DELETE FROM cart_items WHERE product_id IN (SELECT id FROM products WHERE sku = '$s'); DELETE FROM products WHERE sku = '$s';" >/dev/null 2>&1 || true
  done
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM cart_items WHERE product_id = $p; DELETE FROM products WHERE id = $p;" >/dev/null 2>&1 || true
  done
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM cart_items WHERE user_id = $u; DELETE FROM users WHERE id = $u;" >/dev/null 2>&1 || true
  done
}
trap cleanup_all EXIT

# Given
cv_step Given "an admin-created visible product and a signed-in customer" $LINENO
register_and_login admin admin
ADMIN_TOKEN="$TOKEN"
NAME="CV CustDel $SUFFIX"
admin_create_product "CV-CUSTDEL-$SUFFIX" "$NAME" 1800 4
register_and_login customer customer
CUSTOMER_TOKEN="$TOKEN"

# When
cv_step When "the customer tries to remove the product" $LINENO
cv_http DELETE "/products/$PRODUCT_ID" "" -H "Authorization: Bearer $CUSTOMER_TOKEN"

# Then
cv_step Then "the request is refused and the product stays visible to customers" $LINENO
case "$CV_HTTP_STATUS" in 2??) cv_fail "expected the customer's removal to be refused got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO ;; esac
cv_http GET "/products/$PRODUCT_ID" "" -H "Authorization: Bearer $CUSTOMER_TOKEN"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected product still reachable by direct link (200) got $CV_HTTP_STATUS" $LINENO
[ "$(jf '.id')" = "$PRODUCT_ID" ] || cv_fail "expected product $PRODUCT_ID in response got $(jf '.id')" $LINENO
cv_http GET "/products?q=$(jq -rn --arg q "$NAME" '$q|@uri')" "" 200
FOUND=$(printf '%s' "$CV_HTTP_BODY" | jq --argjson id "$PRODUCT_ID" '[.items[] | select(.id == $id)] | length')
[ "$FOUND" = "1" ] || cv_fail "expected product $PRODUCT_ID in catalog search got $FOUND matches" $LINENO
ACTIVE=$(sql "SELECT active FROM products WHERE id = $PRODUCT_ID;")
[ "$ACTIVE" = "t" ] || cv_fail "expected product to remain active got '$ACTIVE'" $LINENO

# Cleanup
cv_step Cleanup "remove the test product and users" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99117446_13"
