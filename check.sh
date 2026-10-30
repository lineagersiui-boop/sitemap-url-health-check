#!/usr/bin/env bash
# Sitemap URL Health Check: runs the Apify Actor lineagersiui/sitemap-url-health-checker
# on the caller's Apify account, writes a job summary and fails on the chosen flags.
# Needs bash, curl and jq (preinstalled on GitHub-hosted Ubuntu runners). The token is
# only ever sent in an Authorization header read from a file descriptor; it is never
# printed, written to disk or put on a command line.
set -euo pipefail

ACTOR_ID='lineagersiui~sitemap-url-health-checker'
API_BASE="${APIFY_API_BASE:-https://api.apify.com}"
MAX_WAIT_SECS="${SHC_MAX_WAIT_SECS:-4200}"   # Actor time limit is at most 3,600 s; allow a margin
OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

shc_err() { echo "::error title=Sitemap URL Health Check::$*"; exit 1; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || shc_err "$tool is required but was not found on this runner."
done

APIFY_TOKEN="${INPUT_APIFY_TOKEN:-}"
[ -n "$APIFY_TOKEN" ] || shc_err "apify-token is empty. Add your Apify API token as a repository secret and pass it as apify-token."
echo "::add-mask::$APIFY_TOKEN"

# ---- Inputs -------------------------------------------------------------------
shc_list() { printf '%s' "$1" | tr ',' '\n'; }
SITES="$(shc_list "${INPUT_SITE_URL:-}")"
SITEMAPS="$(shc_list "${INPUT_SITEMAP_URL:-}")"
MAX_URLS="${INPUT_MAX_URLS:-500}"
FAIL_ON="${INPUT_FAIL_ON-not_found,server_error,client_error}"
ONLY_PROBLEMS="$(printf '%s' "${INPUT_ONLY_PROBLEMS:-true}" | tr '[:upper:]' '[:lower:]')"

[[ "$MAX_URLS" =~ ^[0-9]+$ ]] && [ "$MAX_URLS" -ge 1 ] && [ "$MAX_URLS" -le 5000 ] \
  || shc_err "max-urls must be a whole number from 1 to 5000 (got '$MAX_URLS')."
case "$ONLY_PROBLEMS" in true|false) ;; *) shc_err "only-problems must be true or false." ;; esac

# confirmPermission is always true: adding this Action to your own site's CI is your
# confirmation that you own the site(s) or have permission to check them.
jq -n --arg sites "$SITES" --arg maps "$SITEMAPS" \
      --argjson max "$MAX_URLS" --argjson only "$ONLY_PROBLEMS" '
  def lst: split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));
  { confirmPermission: true, maxUrls: $max, onlyProblems: $only }
  + (if ($sites | lst | length) > 0 then { siteUrls: ($sites | lst) } else {} end)
  + (if ($maps  | lst | length) > 0 then { sitemapUrls: ($maps | lst) } else {} end)
' > "$WORK_DIR/input.json"

jq -e '(.siteUrls // []) + (.sitemapUrls // []) | length > 0' "$WORK_DIR/input.json" >/dev/null \
  || shc_err "Give site-url or sitemap-url."
jq -e '((.siteUrls // []) | length) <= 10 and ((.sitemapUrls // []) | length) <= 10' "$WORK_DIR/input.json" >/dev/null \
  || shc_err "At most 10 site URLs and 10 sitemap URLs per run."

# ---- API helper -----------------------------------------------------------------
# shc_api METHOD PATH OUTFILE [curl args...]; prints the HTTP status code.
shc_api() {
  local method="$1" path="$2" out="$3"; shift 3
  curl -sS -L --retry 3 --retry-delay 5 --retry-connrefused -X "$method" \
    -H @<(printf 'Authorization: Bearer %s\n' "$APIFY_TOKEN") \
    -o "$out" -w '%{http_code}' "$@" "${API_BASE}${path}"
}
shc_api_msg() { jq -r '.error.message // empty' "$1" 2>/dev/null | head -c 300 || true; }

# ---- Start the run ----------------------------------------------------------------
code="$(shc_api POST "/v2/actors/${ACTOR_ID}/runs" "$WORK_DIR/run.json" \
  -H 'Content-Type: application/json' --data-binary @"$WORK_DIR/input.json")" || shc_err "Could not reach the Apify API."
case "$code" in
  201|200) ;;
  401) shc_err "Apify rejected the token (HTTP 401). Check the apify-token secret." ;;
  402) shc_err "Apify usage limit or credit problem (HTTP 402): $(shc_api_msg "$WORK_DIR/run.json")" ;;
  *)   shc_err "Could not start the Actor (HTTP $code): $(shc_api_msg "$WORK_DIR/run.json")" ;;
esac
RUN_ID="$(jq -r '.data.id' "$WORK_DIR/run.json")"
echo "Started Apify run $RUN_ID for $(jq -c '{siteUrls, sitemapUrls, maxUrls, onlyProblems}' "$WORK_DIR/input.json")"
echo "run-id=$RUN_ID" >> "$OUT_FILE"

# ---- Wait for it to finish ------------------------------------------------------------
waited=0
while :; do
  code="$(shc_api GET "/v2/actor-runs/${RUN_ID}?waitForFinish=60" "$WORK_DIR/run.json")" || code=000
  if [ "$code" = 200 ]; then
    STATUS="$(jq -r '.data.status' "$WORK_DIR/run.json")"
    case "$STATUS" in SUCCEEDED|FAILED|TIMED-OUT|ABORTED) break ;; esac
    echo "Run status: $STATUS"
  else
    echo "Polling returned HTTP $code; retrying."
    sleep 10
  fi
  waited=$((waited + 60))
  [ "$waited" -lt "$MAX_WAIT_SECS" ] || shc_err "Gave up waiting for run $RUN_ID after ${MAX_WAIT_SECS}s."
done

if [ "$STATUS" != SUCCEEDED ]; then
  MSG="$(jq -r '.data.statusMessage // ""' "$WORK_DIR/run.json" | head -c 300)"
  shc_err "Apify run $RUN_ID ended with status $STATUS. $MSG"
fi
DATASET_ID="$(jq -r '.data.defaultDatasetId' "$WORK_DIR/run.json")"
KVS_ID="$(jq -r '.data.defaultKeyValueStoreId' "$WORK_DIR/run.json")"

# ---- Fetch SUMMARY and dataset items --------------------------------------------------
code="$(shc_api GET "/v2/key-value-stores/${KVS_ID}/records/SUMMARY" "$WORK_DIR/summary.json")" || code=000
[ "$code" = 200 ] && jq -e 'type == "object"' "$WORK_DIR/summary.json" >/dev/null 2>&1 || echo '{}' > "$WORK_DIR/summary.json"

echo '[]' > "$WORK_DIR/items.json"
offset=0
while :; do
  code="$(shc_api GET "/v2/datasets/${DATASET_ID}/items?format=json&clean=true&offset=${offset}&limit=1000" "$WORK_DIR/page.json")" \
    || shc_err "Could not download results of run $RUN_ID."
  [ "$code" = 200 ] || shc_err "Could not download results of run $RUN_ID (HTTP $code)."
  n="$(jq 'length' "$WORK_DIR/page.json")"
  jq -s '.[0] + .[1]' "$WORK_DIR/items.json" "$WORK_DIR/page.json" > "$WORK_DIR/merged.json"
  mv "$WORK_DIR/merged.json" "$WORK_DIR/items.json"
  [ "$n" -ge 1000 ] || break
  offset=$((offset + 1000))
done

# ---- Evaluate -------------------------------------------------------------------------
jq --arg failon "$FAIL_ON" --arg run "$RUN_ID" --slurpfile summary "$WORK_DIR/summary.json" \
  -f "${GITHUB_ACTION_PATH:-$(dirname "$0")}/evaluate.jq" "$WORK_DIR/items.json" > "$WORK_DIR/result.json"

CHECKED="$(jq -r '.checked' "$WORK_DIR/result.json")"
PROBLEMS="$(jq -r '.problems' "$WORK_DIR/result.json")"
FAILING="$(jq -r '.failing' "$WORK_DIR/result.json")"
{
  echo "checked=$CHECKED"
  echo "problems=$PROBLEMS"
  echo "failing=$FAILING"
} >> "$OUT_FILE"

jq -r '.markdown' "$WORK_DIR/result.json" >> "$SUMMARY_FILE"
echo "Checked $CHECKED URLs: $PROBLEMS with problems, $FAILING matching fail-on ($FAIL_ON). Apify run: $RUN_ID"

if [ "$FAILING" -gt 0 ]; then
  jq -r '.failingRows[:20][] | "::error title=Broken sitemap URL::\(.url) -> \(.status // "no status") [\(.flags | join(", "))]"' "$WORK_DIR/result.json"
  shc_err "$FAILING sitemap URL(s) matched fail-on ($FAIL_ON). See the job summary."
fi
