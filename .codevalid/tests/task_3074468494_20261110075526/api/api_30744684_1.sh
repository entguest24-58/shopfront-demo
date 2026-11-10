#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL
SUFFIX="$(date +%s%N)"
PASSWORD="Passw0rd!${SUFFIX: -6}"
CREATED_USER_IDS=()
CREATED_PRODUCT_IDS=()

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c "$1"; }

# register_and_login <label> <role> -> sets USER_ID and TOKEN
register_and_login() {
  local email="cv_${1}_${SUFFIX}@example.com"
  cv_http POST /auth/register "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"name\":\"CV $1\",\"role\":\"$2\"}"
  [ "$CV_HTTP_STATUS" = "201" ] || cv_fail "expected 201 registering $email got $CV_HTTP_STATUS" $LINENO
  USER_ID=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.id')
  CREATED_USER_IDS+=("$USER_ID")
  cv_http POST /auth/login "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}"
  [ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 logging in $email got $CV_HTTP_STATUS" $LINENO
  TOKEN=$(printf '%s' "$CV_HTTP_BODY" | jq -r '.token')
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || cv_fail "expected a token from login got none" $LINENO
}

# create_product <label> <stock> -> sets PRODUCT_ID
create_product() {
  PRODUCT_ID=$(sql "INSERT INTO products (sku, name, description, category, price_cents, stock) VALUES ('CV-$1-$SUFFIX', 'CV $1 $SUFFIX', 'codevalid test', 'testing', 1000, $2) RETURNING id;" | head -n1)
  [[ "$PRODUCT_ID" =~ ^[0-9]+$ ]] || cv_fail "expected a product id inserting product $1 got '$PRODUCT_ID'" $LINENO
  CREATED_PRODUCT_IDS+=("$PRODUCT_ID")
}

cleanup_all() {
  local u p
  for u in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$u" ] && sql "DELETE FROM users WHERE id = $u;" >/dev/null || true
  done
  for p in "${CREATED_PRODUCT_IDS[@]:-}"; do
    [ -n "$p" ] && sql "DELETE FROM products WHERE id = $p;" >/dev/null || true
  done
}
trap cleanup_all EXIT

# in_report <json> <product_id> -> count of matching items
in_report() { printf '%s' "$1" | jq -r --argjson p "$2" '[.items[] | select(.id == $p)] | length'; }
report_stock() { printf '%s' "$1" | jq -r --argjson p "$2" '[.items[] | select(.id == $p)][0].stock // "absent"'; }
# position of a product id in the item list (-1 if absent)
report_pos() { printf '%s' "$1" | jq -r --argjson p "$2" '[.items[].id] | index($p) // -1'; }
is_sorted() { printf '%s' "$1" | jq -r '[.items[].stock] as $s | ($s == ($s | sort))'; }

# Given
cv_step Given "an admin and products with stock 0, 3, 5 (boundary) and 6" $LINENO
register_and_login admin admin
ADMIN_TOKEN="$TOKEN"
create_product s0 0; P0=$PRODUCT_ID
create_product s3 3; P3=$PRODUCT_ID
create_product s5 5; P5=$PRODUCT_ID
create_product s6 6; P6=$PRODUCT_ID

# When
cv_step When "the admin requests the low-stock report without a threshold" $LINENO
cv_http GET /admin/inventory/low-stock "" -H "Authorization: Bearer $ADMIN_TOKEN"
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 from low-stock report got $CV_HTTP_STATUS" $LINENO
REPORT="$CV_HTTP_BODY"

# Then
cv_step Then "products with 5 or fewer units are listed (including exactly 5) and 6 is excluded" $LINENO
for pair in "$P0:0" "$P3:3" "$P5:5"; do
  pid=${pair%%:*}; st=${pair##*:}
  [ "$(in_report "$REPORT" "$pid")" = "1" ] || cv_fail "expected product $pid (stock $st) in default report got absent" $LINENO
  [ "$(report_stock "$REPORT" "$pid")" = "$st" ] || cv_fail "expected stock $st for product $pid got $(report_stock "$REPORT" "$pid")" $LINENO
done
[ "$(in_report "$REPORT" "$P6")" = "0" ] || cv_fail "expected product $P6 (stock 6) excluded from default report got listed" $LINENO
OVER=$(printf '%s' "$REPORT" | jq '[.items[] | select(.stock > 5)] | length')
[ "$OVER" = "0" ] || cv_fail "expected no item with stock > 5 in default report got $OVER" $LINENO

# Cleanup
cv_step Cleanup "remove the created users and products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_30744684_1"
