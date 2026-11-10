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

WORD="zzqnomatch${SUFFIX}"

# Given
cv_step Given "a catalog with products none of which contain the search word" $LINENO
create_product NM "CV Other ${SUFFIX}" "CV unrelated description" "$CAT_A" 900 2; PID=$NEW_ID
CNT=$(sql "SELECT count(*) FROM products WHERE active AND (name ILIKE '%${WORD}%' OR description ILIKE '%${WORD}%')" | tr -d '[:space:]')
[ "$CNT" = "0" ] || cv_fail "expected no product containing ${WORD} got $CNT" $LINENO

# When
cv_step When "a visitor searches for a word that matches nothing" $LINENO
cv_http GET "/products?q=${WORD}"

# Then
cv_step Then "no products are returned" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
N=$(printf '%s' "$CV_HTTP_BODY" | jq '.items | length')
T=$(printf '%s' "$CV_HTTP_BODY" | jq '.total')
[ "$N" = "0" ] || cv_fail "expected 0 items got $N" $LINENO
[ "$T" = "0" ] || cv_fail "expected total 0 got $T" $LINENO

# Cleanup
cv_step Cleanup "delete the test product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_5"
