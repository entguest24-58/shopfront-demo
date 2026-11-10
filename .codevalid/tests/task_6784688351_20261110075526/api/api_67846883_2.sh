#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL

# lookup_coupon <code>: anonymous GET /coupons/<code>
lookup_coupon() { cv_http GET "/coupons/$1"; }

# Given
cv_step Given "any user, no sign-in required" $LINENO
CODE="WELCOME15"

# When
cv_step When "the user looks up WELCOME15" $LINENO
lookup_coupon "$CODE"

# Then
cv_step Then "the benefit is 15% off for subtotals of at least \$100.00" $LINENO
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for WELCOME15 lookup got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO
C=$(jq -r ".code" <<<"$CV_HTTP_BODY"); P=$(jq -r ".percent_off" <<<"$CV_HTTP_BODY"); M=$(jq -r ".min_subtotal_cents" <<<"$CV_HTTP_BODY")
[ "$C" = "WELCOME15" ] || cv_fail "expected code WELCOME15 got $C" $LINENO
[ "$P" = "15" ] || cv_fail "expected percent_off 15 got $P" $LINENO
[ "$M" = "10000" ] || cv_fail "expected min_subtotal_cents 10000 got $M" $LINENO

# Cleanup
cv_step Cleanup "nothing was created" $LINENO

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_2"
