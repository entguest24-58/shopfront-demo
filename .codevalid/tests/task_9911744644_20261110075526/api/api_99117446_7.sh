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

# register_and_login <label> <role customer|admin> -> sets USER_ID and TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"CV $1\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  CREATED_USER_IDS+=("$USER_ID")
  if [ "$2" = "admin" ]; then
    sql "UPDATE users SET role = 'admin' WHERE id = $USER_ID;" >/dev/null
  fi
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
  [ "$(printf '%s' "$CV_HTTP_BODY" | jq -r '.user.role')" = "$2" ] || cv_fail "expected role $2 for $email got $(printf '%s' "$CV_HTTP_BODY" | jq -r '.user.role')" $LINENO
}

# admin_create_product <sku> <name> <price_cents> <stock> <category> -> sets PRODUCT_ID (via API, Given only)
admin_create_product() {
  CREATED_SKUS+=("$1")
  cv_http POST /products "{\"sku\":\"$1\",\"name\":\"$2\",\"description\":\"codevalid test\",\"category\":\"$5\",\"price_cents\":$3,\"stock\":$4}" -H "Authorization: Bearer $ADMIN_TOKEN"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 creating product $1 got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
  PRODUCT_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]] || cv_fail "expected numeric product id got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCT_IDS+=("$PRODUCT_ID")
}

cleanup_all() {
  local u p s
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM cart_items WHERE user_id = $u; DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $u); DELETE FROM orders WHERE user_id = $u;" >/dev/null 2>&1 || true
  done
  for s in "${CREATED_SKUS[@]:-}"; do
    [ -n "$s" ] && sql "DELETE FROM cart_items WHERE product_id IN (SELECT id FROM products WHERE sku = '$s'); DELETE FROM products WHERE sku = '$s';" >/dev/null 2>&1 || true
  done
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM cart_items WHERE product_id = $p; DELETE FROM products WHERE id = $p;" >/dev/null 2>&1 || true
  done
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM users WHERE id = $u;" >/dev/null 2>&1 || true
  done
}
trap cleanup_all EXIT

jf() { printf '%s' "$CV_HTTP_BODY" | jq -r "$1"; }

# Given
cv_step Given "a signed-in admin, an existing product priced 1000 and an unused SKU" $LINENO
register_and_login admin admin
ADMIN_TOKEN="$TOKEN"
admin_create_product "CV-NEGX-$SUFFIX" "CV Neg Existing $SUFFIX" 1000 3 cvtest
EXISTING_ID="$PRODUCT_ID"
NEW_SKU="CV-NEGN-$SUFFIX"
CREATED_SKUS+=("$NEW_SKU")

# When
cv_step When "the admin adds a product with price -100 and changes the existing product's price to -50" $LINENO
cv_http POST /products "{\"sku\":\"$NEW_SKU\",\"name\":\"CV Neg New $SUFFIX\",\"description\":\"neg\",\"category\":\"cvtest\",\"price_cents\":-100,\"stock\":1}" -H "Authorization: Bearer $ADMIN_TOKEN"
CREATE_STATUS="$CV_HTTP_STATUS"; CREATE_BODY="$CV_HTTP_BODY"
cv_http PATCH "/products/$EXISTING_ID" '{"price_cents":-50}' -H "Authorization: Bearer $ADMIN_TOKEN"
PATCH_STATUS="$CV_HTTP_STATUS"; PATCH_BODY="$CV_HTTP_BODY"

# Then
cv_step Then "both requests are refused, nothing is created and the existing price is unchanged" $LINENO
case "$CREATE_STATUS" in 4??) ;; *) cv_fail "expected 4xx adding negative-price product got $CREATE_STATUS: $CREATE_BODY" $LINENO ;; esac
case "$PATCH_STATUS" in 4??) ;; *) cv_fail "expected 4xx changing price to negative got $PATCH_STATUS: $PATCH_BODY" $LINENO ;; esac
COUNT=$(sql "SELECT count(*) FROM products WHERE sku = '$NEW_SKU';")
[ "$COUNT" = "0" ] || cv_fail "expected no product with SKU $NEW_SKU got $COUNT" $LINENO
cv_http GET "/products/$EXISTING_ID" "" 200
[ "$(jf '.price_cents')" = "1000" ] || cv_fail "expected existing price 1000 unchanged got $(jf '.price_cents')" $LINENO

# Cleanup
cv_step Cleanup "remove the test product and admin user" $LINENO
cleanup_all
trap - EXIT
echo "CODEVALID_TEST_ASSERTION_OK:api_99117446_7"
