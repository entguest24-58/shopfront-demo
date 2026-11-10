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

WORD="cvmatch${SUFFIX}"

# Given
cv_step Given "products with and without the word across two categories" $LINENO
create_product AH "CV ${WORD} alpha" "cv" "$CAT_A" 1000 1; A_HIT=$NEW_ID
create_product AM "CV plain alpha ${SUFFIX}" "cv" "$CAT_A" 1000 1; A_MISS=$NEW_ID
create_product BH "CV ${WORD} beta" "cv" "$CAT_B" 1000 1; B_HIT=$NEW_ID

# When
cv_step When "a visitor searches the word within category A" $LINENO
cv_http GET "/products?q=${WORD}&category=${CAT_A}"

# Then
cv_step Then "only the category A product containing the word is returned" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
[ "$IDS" = "[$A_HIT]" ] || cv_fail "expected only [$A_HIT] (not $A_MISS or $B_HIT) got $IDS" $LINENO

# Cleanup
cv_step Cleanup "delete the test products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_7"
