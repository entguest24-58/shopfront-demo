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

WORD="cvdescword${SUFFIX}"

# Given
cv_step Given "a product whose description, not its name, contains a unique word" $LINENO
create_product DESC "CV Plain ${SUFFIX}" "Made with ${WORD} fabric" "$CAT_A" 1200 4; PID=$NEW_ID

# When
cv_step When "a visitor searches for that word" $LINENO
cv_http GET "/products?q=${WORD}"

# Then
cv_step Then "the product is in the results" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
FOUND=$(printf '%s' "$CV_HTTP_BODY" | jq --argjson id "$PID" '[.items[] | select(.id == $id)] | length')
[ "$FOUND" = "1" ] || cv_fail "expected product $PID matched by description in search results got body $CV_HTTP_BODY" $LINENO

# Cleanup
cv_step Cleanup "delete the test product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_4"
