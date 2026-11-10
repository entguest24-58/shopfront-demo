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
cv_step Given "25 products in one category" $LINENO
sql "INSERT INTO products (sku, name, description, category, price_cents, stock) SELECT 'CV-${SUFFIX}-' || g, 'CV Page ' || lpad(g::text, 2, '0') || ' ${SUFFIX}', 'cv', '${CAT_A}', 1000 + g, 5 FROM generate_series(1, 25) g" >/dev/null
CNT=$(sql "SELECT count(*) FROM products WHERE category = '${CAT_A}'" | tr -d '[:space:]')
[ "$CNT" = "25" ] || cv_fail "expected 25 seeded products got $CNT" $LINENO

# When
cv_step When "a visitor requests the first page without choosing a page size" $LINENO
cv_http GET "/products?category=${CAT_A}"

# Then
cv_step Then "page 1 has exactly 20 products and page 2 continues with the rest, no repeats" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
P1=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
N1=$(jq 'length' <<<"$P1")
[ "$N1" = "20" ] || cv_fail "expected 20 products on default page 1 got $N1" $LINENO
cv_http GET "/products?category=${CAT_A}&page=2"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for page 2 got $CV_HTTP_STATUS" $LINENO
P2=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id]')
N2=$(jq 'length' <<<"$P2")
[ "$N2" = "5" ] || cv_fail "expected 5 products on page 2 got $N2" $LINENO
OVER=$(jq -n --argjson a "$P1" --argjson b "$P2" '[$a[] | select(. as $x | $b | index($x))] | length')
[ "$OVER" = "0" ] || cv_fail "expected no repeats between pages got $OVER overlapping" $LINENO

# Cleanup
cv_step Cleanup "delete the test products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_8"
