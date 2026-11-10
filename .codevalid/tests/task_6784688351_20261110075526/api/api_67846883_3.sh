#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL

# lookup_coupon <code>: anonymous GET /coupons/<code>
lookup_coupon() { cv_http GET "/coupons/$1"; }

# Given
cv_step Given "the benefits of the uppercase codes SAVE10 and WELCOME15" $LINENO
lookup_coupon SAVE10
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for SAVE10 reference lookup got $CV_HTTP_STATUS" $LINENO
REF_SAVE=$(jq -cS "{code,percent_off,min_subtotal_cents}" <<<"$CV_HTTP_BODY")
lookup_coupon WELCOME15
[ "$CV_HTTP_STATUS" = "200" ] || cv_fail "expected 200 for WELCOME15 reference lookup got $CV_HTTP_STATUS" $LINENO
REF_WEL=$(jq -cS "{code,percent_off,min_subtotal_cents}" <<<"$CV_HTTP_BODY")

# When
cv_step When "the user looks up save10 and WeLcOmE15" $LINENO
lookup_coupon save10
S1=$CV_HTTP_STATUS; B1=$CV_HTTP_BODY
lookup_coupon WeLcOmE15
S2=$CV_HTTP_STATUS; B2=$CV_HTTP_BODY

# Then
cv_step Then "each mixed-case lookup returns the same benefit as the uppercase code" $LINENO
[ "$S1" = "200" ] || cv_fail "expected 200 for save10 got $S1: $B1" $LINENO
[ "$S2" = "200" ] || cv_fail "expected 200 for WeLcOmE15 got $S2: $B2" $LINENO
G1=$(jq -cS "{code,percent_off,min_subtotal_cents}" <<<"$B1")
G2=$(jq -cS "{code,percent_off,min_subtotal_cents}" <<<"$B2")
[ "$G1" = "$REF_SAVE" ] || cv_fail "expected save10 benefit $REF_SAVE got $G1" $LINENO
[ "$G2" = "$REF_WEL" ] || cv_fail "expected WeLcOmE15 benefit $REF_WEL got $G2" $LINENO
[ "$(jq -r .percent_off <<<"$B1")" = "10" ] || cv_fail "expected save10 percent_off 10 got $(jq -r .percent_off <<<"$B1")" $LINENO
[ "$(jq -r .percent_off <<<"$B2")" = "15" ] || cv_fail "expected WeLcOmE15 percent_off 15 got $(jq -r .percent_off <<<"$B2")" $LINENO

# Cleanup
cv_step Cleanup "nothing was created" $LINENO

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_3"
