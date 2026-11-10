#!/usr/bin/env bash
set -euo pipefail
source "${CODEVALID_ROOT:-.}/.codevalid/lib/cv.sh"

BASE_URL="${BASE_URL:-http://app:6713}"
DATABASE_URL="${DATABASE_URL:-postgresql://app:app@toxiproxy:5432/appdb}"
export BASE_URL DATABASE_URL

# lookup_coupon <code>: anonymous GET /coupons/<code>
lookup_coupon() { cv_http GET "/coupons/$1"; }

# Given
cv_step Given "a code that is not in the coupon catalog" $LINENO
CODE="FREESTUFF"

# When
cv_step When "the user looks up FREESTUFF" $LINENO
lookup_coupon "$CODE"

# Then
cv_step Then "the lookup is refused and no benefit is returned" $LINENO
case "$CV_HTTP_STATUS" in 4??) ;; *) cv_fail "expected a 4xx refusal for FREESTUFF got $CV_HTTP_STATUS: $CV_HTTP_BODY" $LINENO ;; esac
P=$(jq -r ".percent_off // empty" <<<"$CV_HTTP_BODY" 2>/dev/null || true)
M=$(jq -r ".min_subtotal_cents // empty" <<<"$CV_HTTP_BODY" 2>/dev/null || true)
[ -z "$P" ] && [ -z "$M" ] || cv_fail "expected no benefit in the refusal got percent_off=$P min_subtotal_cents=$M" $LINENO

# Cleanup
cv_step Cleanup "nothing was created" $LINENO

echo "CODEVALID_TEST_ASSERTION_OK:api_67846883_4"
