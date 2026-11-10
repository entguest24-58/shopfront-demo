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
cv_step Given "a signed-in customer and a product with low stock" $LINENO
register_and_login cust customer
CUST_TOKEN="$TOKEN"
create_product s2 2; P2=$PRODUCT_ID

# When
cv_step When "the customer requests the low-stock report with and without a threshold" $LINENO
cv_http GET /admin/inventory/low-stock "" -H "Authorization: Bearer $CUST_TOKEN"
S1="$CV_HTTP_STATUS"; B1="$CV_HTTP_BODY"
cv_http GET "/admin/inventory/low-stock?threshold=100" "" -H "Authorization: Bearer $CUST_TOKEN"
S2="$CV_HTTP_STATUS"; B2="$CV_HTTP_BODY"

# Then
cv_step Then "no product stock data is returned to the customer" $LINENO
for pair in "default|$S1" "threshold|$S2"; do
  label=${pair%%|*}; st=${pair##*|}
  case "$st" in 2??) ;; *) continue ;; esac
  body=$([ "$label" = default ] && printf '%s' "$B1" || printf '%s' "$B2")
  n=$(printf '%s' "$body" | jq '[.items[]?] | length' 2>/dev/null || echo 0)
  [ "$n" = "0" ] || cv_fail "expected no stock data for customer ($label request) got $st with $n items" $LINENO
done
for body in "$B1" "$B2"; do
  if printf '%s' "$body" | jq -e '.items? // empty | length > 0' >/dev/null 2>&1; then
    cv_fail "expected no product items exposed to customer got $(printf '%s' "$body" | head -c 200)" $LINENO
  fi
  if printf '%s' "$body" | grep -q "CV-s2-$SUFFIX"; then
    cv_fail "expected low-stock product SKU not exposed to customer got it in body" $LINENO
  fi
done

# Cleanup
cv_step Cleanup "remove the created users and products" $LINENO
cleanup_all
echo "CODEVALID_TEST_ASSERTION_OK:api_30744684_6"
