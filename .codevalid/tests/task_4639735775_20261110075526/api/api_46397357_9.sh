#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
CAT="cvcat-big-${SUFFIX}"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

cleanup_all() {
  sql "DELETE FROM products WHERE sku LIKE 'CV-${SUFFIX}-%'" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

# Given
cv_step Given "more than 100 products (150) in the catalog under one category" $LINENO
sql "INSERT INTO products (sku, name, description, category, price_cents, stock) SELECT 'CV-${SUFFIX}-' || g, 'CV Big ' || lpad(g::text, 3, '0') || ' ${SUFFIX}', 'cv', '${CAT}', 1000 + g, 5 FROM generate_series(1, 150) g" >/dev/null
CNT=$(sql "SELECT count(*) FROM products WHERE category = '${CAT}' AND active = true" | tr -d '[:space:]')
[ "$CNT" = "150" ] || cv_fail "expected 150 seeded products got $CNT" $LINENO

# When
cv_step When "a visitor requests page 1 with page_size=100" $LINENO
cv_http GET "/products?category=${CAT}&page=1&page_size=100"

# Then
cv_step Then "the page holds exactly 100 products" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
N=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$N" = "100" ] || cv_fail "expected exactly 100 products on the page got $N" $LINENO
UNIQ=$(printf '%s' "$CV_HTTP_BODY" | jq '[.items[].id] | unique | length')
[ "$UNIQ" = "100" ] || cv_fail "expected 100 distinct products got $UNIQ" $LINENO
FOREIGN=$(printf '%s' "$CV_HTTP_BODY" | jq --arg c "$CAT" '[.items[] | select(.category != $c)] | length')
[ "$FOREIGN" = "0" ] || cv_fail "expected only products of category $CAT got $FOREIGN others" $LINENO

# Cleanup
cv_step Cleanup "delete the test products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_9"
