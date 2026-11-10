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
cv_step Given "products in two different categories" $LINENO
create_product A1 "CV CatA one ${SUFFIX}" "cv" "$CAT_A" 1000 1; A1=$NEW_ID
create_product A2 "CV CatA two ${SUFFIX}" "cv" "$CAT_A" 1100 1; A2=$NEW_ID
create_product B1 "CV CatB one ${SUFFIX}" "cv" "$CAT_B" 1200 1; B1=$NEW_ID

# When
cv_step When "a visitor narrows the catalog to category A" $LINENO
cv_http GET "/products?category=${CAT_A}"

# Then
cv_step Then "only category A products are returned" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 got $CV_HTTP_STATUS" $LINENO
OTHER=$(printf '%s' "$CV_HTTP_BODY" | jq --arg c "$CAT_A" '[.items[] | select(.category != $c)] | length')
[ "$OTHER" = "0" ] || cv_fail "expected only $CAT_A products got $OTHER from other categories" $LINENO
IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id] | sort')
[ "$IDS" = "$(jq -nc --argjson a "$A1" --argjson b "$A2" '[$a,$b]|sort')" ] || cv_fail "expected exactly products $A1,$A2 got $IDS" $LINENO
printf '%s' "$IDS" | jq -e --argjson id "$B1" 'index($id) == null' >/dev/null || cv_fail "expected category B product $B1 to be excluded got $IDS" $LINENO

# Cleanup
cv_step Cleanup "delete the test products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_6"
