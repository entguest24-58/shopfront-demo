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

ids_for() {
  cv_http GET "/products?q=$1&page_size=100"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 searching '$1' got $CV_HTTP_STATUS" $LINENO
}

# Given
cv_step Given "a product named 'Desk lamp' exists" $LINENO
create_product LAMP "Desk lamp CV${SUFFIX}" "CV test product" "$CAT_A" 2500 3; PID=$NEW_ID

# When
cv_step When "a visitor searches for 'LAMP'" $LINENO
ids_for LAMP
UPPER_IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id] | sort')
UPPER_TOTAL=$(printf '%s' "$CV_HTTP_BODY" | jq '.total')

# Then
cv_step Then "the Desk lamp is found and 'lamp' and 'Lamp' return the same products" $LINENO
printf '%s' "$UPPER_IDS" | jq -e --argjson id "$PID" 'index($id) != null' >/dev/null || cv_fail "expected product $PID ('Desk lamp') in results for 'LAMP' got ids $UPPER_IDS" $LINENO
ids_for lamp
LOWER_IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id] | sort'); LOWER_TOTAL=$(printf '%s' "$CV_HTTP_BODY" | jq '.total')
ids_for Lamp
TITLE_IDS=$(printf '%s' "$CV_HTTP_BODY" | jq -c '[.items[].id] | sort'); TITLE_TOTAL=$(printf '%s' "$CV_HTTP_BODY" | jq '.total')
[ "$LOWER_TOTAL" = "$UPPER_TOTAL" ] && [ "$LOWER_IDS" = "$UPPER_IDS" ] || cv_fail "expected 'lamp' to return the same products as 'LAMP' (total $UPPER_TOTAL) got total $LOWER_TOTAL" $LINENO
[ "$TITLE_TOTAL" = "$UPPER_TOTAL" ] && [ "$TITLE_IDS" = "$UPPER_IDS" ] || cv_fail "expected 'Lamp' to return the same products as 'LAMP' (total $UPPER_TOTAL) got total $TITLE_TOTAL" $LINENO

# Cleanup
cv_step Cleanup "delete the test product" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_46397357_3"
