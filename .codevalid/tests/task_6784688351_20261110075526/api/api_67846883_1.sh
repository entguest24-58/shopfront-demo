#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL

# lookup_coupon <code>: anonymous GET /coupons/<code>
lookup_coupon() { cv_http GET "/coupons/$1"; }

# Given
cv_step Given "an anonymous visitor with no account, token or cart" $LINENO
AUTH_HEADER=""
[ -z "$AUTH_HEADER" ] || cv_fail "expected no credentials got some" $LINENO

# When
cv_step When "the visitor looks up SAVE10 without signing in" $LINENO
lookup_coupon SAVE10

# Then
cv_step Then "the benefit is 10% off for subtotals of at least \$50.00" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for anonymous SAVE10 lookup got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
C=$(jq -r ".code" <<<"$CV_HTTP_BODY"); P=$(jq -r ".percent_off" <<<"$CV_HTTP_BODY"); M=$(jq -r ".min_subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$C" = "SAVE10" ] || cv_fail "expected code SAVE10 got $C" $LINENO
[ "$P" = "10" ] || cv_fail "expected percent_off 10 got $P" $LINENO
[ "$M" = "5000" ] || cv_fail "expected min_subtotal_cents 5000 got $M" $LINENO

# Cleanup
cv_step Cleanup "nothing was created" $LINENO

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_1"
