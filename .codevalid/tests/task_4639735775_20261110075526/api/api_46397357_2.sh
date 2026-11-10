#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
CAT_A="cvcat-a-${SUFFIX}"
CAT_B="cvcat-b-${SUFFIX}"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# create_product <label> <name> <description> <category> <price_cents> <stock> -> sets NEW_ID
create_product() {
  NEW_ID=$(sql "INSERT INTO products (sku, name, description, category, price_cents, stock) VALUES ('CV-${SUFFIX}-$1', '$2', '$3', '$4', $5, $6) RETURNING id" | head -n1 | tr -d '[:space:]')
  [ -n "$NEW_ID" ] || cv_fail "expected product $1 to be inserted got no id" $LINENO
}

cleanup_all() {
  sql "DELETE FROM products WHERE sku LIKE 'CV-${SUFFIX}-%'" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

# Given
cv_step Given "a catalog holding a product with zero stock" $LINENO
create_product OOS "CV Soldout ${SUFFIX}" "CV soldout description ${SUFFIX}" "$CAT_A" 4550 0; PID=$NEW_ID

# When
cv_step When "a visitor browses the catalog" $LINENO
cv_http GET "/products?category=${CAT_A}"

# Then
cv_step Then "the out-of-stock product is listed with all fields and shown as not available" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
ITEM=$(printf '%s' "$CV_HTTP_BODY" | jq -c --argjson id "$PID" '.items[] | select(.id == $id)')
[ -n "$ITEM" ] || cv_fail "expected out-of-stock product $PID to be listed got body $CV_HTTP_BODY" $LINENO
[ "$(jq -r '.in_stock' <<<"$ITEM")" = "false" ] || cv_fail "expected in_stock false got $(jq -r '.in_stock' <<<"$ITEM")" $LINENO
[ "$(jq -r '.stock' <<<"$ITEM")" = "0" ] || cv_fail "expected stock 0 got $(jq -r '.stock' <<<"$ITEM")" $LINENO
[ "$(jq -r '.name' <<<"$ITEM")" = "CV Soldout ${SUFFIX}" ] || cv_fail "expected name got $(jq -r '.name' <<<"$ITEM")" $LINENO
[ "$(jq -r '.description' <<<"$ITEM")" = "CV soldout description ${SUFFIX}" ] || cv_fail "expected description got $(jq -r '.description' <<<"$ITEM")" $LINENO
[ "$(jq -r '.category' <<<"$ITEM")" = "$CAT_A" ] || cv_fail "expected category $CAT_A got $(jq -r '.category' <<<"$ITEM")" $LINENO
[ "$(jq -r '.price_cents' <<<"$ITEM")" = "4550" ] || cv_fail "expected price 4550 cents got $(jq -r '.price_cents' <<<"$ITEM")" $LINENO

# Cleanup
cv_step Cleanup "delete the test product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_2"
