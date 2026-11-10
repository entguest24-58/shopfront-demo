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
cv_step Given "a catalog product exists and the visitor holds no credentials" $LINENO
create_product P1 "CV Browse ${SUFFIX}" "CV browse description ${SUFFIX}" "$CAT_A" 1999 7; PID=$NEW_ID

# When
cv_step When "an anonymous visitor requests the product catalog with no Authorization header" $LINENO
cv_http GET "/products?category=${CAT_A}"

# Then
cv_step Then "products are returned with name, description, category, USD price and stock availability" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for anonymous catalog request got $CV_HTTP_STATUS" $LINENO
ITEM=$(printf '%s' "$CV_HTTP_BODY" | jq -c --argjson id "$PID" '.items[] | select(.id == $id)')
[ -n "$ITEM" ] || cv_fail "expected product $PID in anonymous catalog got body $CV_HTTP_BODY" $LINENO
[ "$(jq -r '.name' <<<"$ITEM")" = "CV Browse ${SUFFIX}" ] || cv_fail "expected name 'CV Browse ${SUFFIX}' got $(jq -r '.name' <<<"$ITEM")" $LINENO
[ "$(jq -r '.description' <<<"$ITEM")" = "CV browse description ${SUFFIX}" ] || cv_fail "expected description got $(jq -r '.description' <<<"$ITEM")" $LINENO
[ "$(jq -r '.category' <<<"$ITEM")" = "$CAT_A" ] || cv_fail "expected category $CAT_A got $(jq -r '.category' <<<"$ITEM")" $LINENO
[ "$(jq -r '.price_cents' <<<"$ITEM")" = "1999" ] || cv_fail "expected USD price 1999 cents got $(jq -r '.price_cents' <<<"$ITEM")" $LINENO
[ "$(jq -r '.in_stock' <<<"$ITEM")" = "true" ] || cv_fail "expected in_stock true got $(jq -r '.in_stock' <<<"$ITEM")" $LINENO
[ "$(jq -r '.stock' <<<"$ITEM")" = "7" ] || cv_fail "expected stock 7 got $(jq -r '.stock' <<<"$ITEM")" $LINENO
cv_http GET "/products"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for anonymous unfiltered catalog got $CV_HTTP_STATUS" $LINENO
N=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$N" -gt 0 ] || cv_fail "expected products in unfiltered anonymous catalog got $N" $LINENO
MISSING=$(printf '%s' "$CV_HTTP_BODY" | jq '[.items[] | select((has("name") and has("description") and has("category") and has("price_cents") and has("in_stock")) | not)] | length')
[ "$MISSING" = "0" ] || cv_fail "expected every product to carry name, description, category, price_cents, in_stock got $MISSING missing fields" $LINENO

# Cleanup
cv_step Cleanup "delete the test product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_1"
