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
cv_step When "an anonymous visitor requests page 1 with page_size=1000" $LINENO
cv_http GET "/products?category=${CAT}&page=1&page_size=1000"

# Then
cv_step Then "no more than 100 products are returned on the page" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
N=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
[ "$N" -le 100 ] || cv_fail "expected at most 100 products on an oversized page request got $N (catalog pulled in one request)" $LINENO
[ "$N" -gt 0 ] || cv_fail "expected the page to still list products got $N" $LINENO
PS_RESP=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.page_size // empty')
if [ -n "$PS_RESP" ]; then
  [ "$PS_RESP" -le 100 ] || cv_fail "expected reported page_size <= 100 got $PS_RESP" $LINENO
fi

# Cleanup
cv_step Cleanup "delete the test products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_10"
