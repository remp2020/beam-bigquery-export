#!/usr/bin/env bash
#
# Exports REMP Beam data from Elasticsearch to BigQuery, one day at a time.
# Each day replaces its partition in the target table, so re-runs and backfills are safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INDICES="pageviews,pageviews_time_spent,pageviews_progress,events,commerce,impressions"
DEFAULT_STAGES="export,bq_upload,cleanup"
BQ_LOAD_ATTEMPTS=3
BQ_LOAD_RETRY_DELAY=30

function usage {
    cat >&2 <<EOF
Usage: $0 [options]

Options:
  --date=<DATE>                     export a single day (default: yesterday)
  --min_date=<DATE> --max_date=<DATE>
                                    export every day in the range, both days included
  --stages=<STAGES>                 comma-separated subset of '${DEFAULT_STAGES}' (default: all)
  --env=<FILE>                      env file to load (default: .env next to this script)
  --dir=<DIR>                       working directory for exported JSON files (default: /tmp)

Dates are in YYYY-MM-DD format (UTC).
EOF
}

function fail {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

function is_valid_date {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# macOS ships BSD date; use GNU date (gdate from coreutils) there
function gnu_date {
    if [ "$(uname)" == "Darwin" ]; then
        gdate "$@"
    else
        date "$@"
    fi
}

function add_day {
    gnu_date -u -I -d "$1 + 1 day"
}

function bq_load_with_retry {
    local attempt
    for attempt in $(seq 1 $BQ_LOAD_ATTEMPTS); do
        if bq -q --headless=true load \
            --source_format=NEWLINE_DELIMITED_JSON \
            --ignore_unknown_values \
            "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$BQ_LOAD_ATTEMPTS" ]; then
            echo " * Load failed (attempt ${attempt}/${BQ_LOAD_ATTEMPTS}), retrying in ${BQ_LOAD_RETRY_DELAY}s" >&2
            sleep $BQ_LOAD_RETRY_DELAY
        fi
    done
    return 1
}

function bq_upload {
    local table_id=$1
    local file_to_upload=$2
    local partition=$3

    local table_full_name="${BQ_PROJECT_ID}:${BQ_DATASET_ID}.${table_id}"
    local schema_file="${SCRIPT_DIR}/bq/${table_id}_schema.json"

    if ! bq --headless=true -q show --schema "${table_full_name}" >/dev/null 2>&1; then
        echo " * Creating BQ table '${table_full_name}'"
        bq --headless=true mk \
            -t \
            --schema "${schema_file}" \
            --time_partitioning_field time \
            --time_partitioning_type DAY \
            "${table_full_name}" || fail "could not create table ${table_full_name}"
    else
        # replace the day's partition, so running the same day again does not duplicate rows
        bq --headless=true rm -f --table "${table_full_name}\$${partition}" \
            || fail "could not delete partition ${partition} of ${table_full_name}"
    fi

    echo " * Uploading data to BQ table '${table_full_name}'"
    bq_load_with_retry "${table_full_name}" "${file_to_upload}" "${schema_file}" \
        || fail "loading ${file_to_upload} into ${table_full_name} failed"
}

# Arguments

date=""
min_date=""
max_date=""
dir="/tmp"
stages="$DEFAULT_STAGES"
env="${SCRIPT_DIR}/.env"

while [ $# -gt 0 ]; do
    case "$1" in
        --min_date=*) min_date="${1#*=}" ;;
        --max_date=*) max_date="${1#*=}" ;;
        --date=*) date="${1#*=}" ;;
        --dir=*) dir="${1#*=}" ;;
        --stages=*) stages="${1#*=}" ;;
        --env=*) env="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: invalid argument '$1'" >&2; usage; exit 1 ;;
    esac
    shift
done

# Configuration

[ -f "$env" ] || fail "env file '$env' not found" 2
set -a
# shellcheck disable=SC1090
source "$env"
set +a

: "${ELASTIC_PREFIX:=}"
: "${BEAM_INDICES:=$DEFAULT_INDICES}"
[ -n "${ELASTIC_CONNECTION:-}" ] || fail "ELASTIC_CONNECTION is not set" 2
[ -n "${BQ_PROJECT_ID:-}" ] || fail "BQ_PROJECT_ID is not set" 2
[ -n "${BQ_DATASET_ID:-}" ] || fail "BQ_DATASET_ID is not set" 2

# Sentry error reporting, if available
if [ -n "${SENTRY_DSN:-}" ] && command -v sentry-cli &> /dev/null; then
    eval "$(sentry-cli bash-hook)"
fi

# Validation

mkdir -p "$dir" || fail "could not create directory '$dir'" 5
[ -d "$dir" ] || fail "'$dir' is not a directory" 5

if [ -n "$min_date" ] || [ -n "$max_date" ]; then
    is_valid_date "$min_date" || fail "--min_date '$min_date' is not in YYYY-MM-DD format" 6
    is_valid_date "$max_date" || fail "--max_date '$max_date' is not in YYYY-MM-DD format" 6
    start_on=$min_date
    end_on=$(add_day "$max_date")
elif [ -n "$date" ]; then
    is_valid_date "$date" || fail "--date '$date' is not in YYYY-MM-DD format" 6
    start_on=$date
    end_on=$(add_day "$date")
else
    start_on=$(gnu_date -u -I -d "yesterday")
    end_on=$(add_day "$start_on")
fi
[[ "$start_on" < "$end_on" ]] || fail "--min_date must not be after --max_date" 6

stage_export=false
stage_bq_upload=false
stage_cleanup=false
IFS=',' read -ra stages_array <<< "$stages"
for s in "${stages_array[@]}"; do
    case "${s// /}" in
        export) stage_export=true ;;
        bq_upload) stage_bq_upload=true ;;
        cleanup) stage_cleanup=true ;;
        *) echo "Error: invalid stage '$s'" >&2; usage; exit 6 ;;
    esac
done

IFS=',' read -ra indices <<< "${BEAM_INDICES// /}"
for idx in "${indices[@]}"; do
    [ -f "${SCRIPT_DIR}/bq/${idx}_schema.json" ] || fail "no schema file bq/${idx}_schema.json for index '${idx}'" 6
done

elasticdump="${SCRIPT_DIR}/node_modules/.bin/elasticdump"
if [ "$stage_export" = true ] && [ ! -x "$elasticdump" ]; then
    fail "elasticdump not found; run 'npm install' in ${SCRIPT_DIR}" 7
fi
if [ "$stage_bq_upload" = true ] && ! command -v bq &> /dev/null; then
    fail "'bq' command not found; install the gcloud CLI" 7
fi

echo ""
echo "Beam → BigQuery export"
echo "======================"
echo "Time: $(gnu_date)"
echo "Days: ${start_on} to ${end_on} (excluded), indices: ${BEAM_INDICES}, stages: ${stages}, dir: ${dir}"
echo "======================"

# Export

day=$start_on
while [ "$day" != "$end_on" ]; do
    partition=${day//-/}

    for idx in "${indices[@]}"; do
        json_file="${dir}/${idx}_${partition}.json"
        index_name="${ELASTIC_PREFIX}${idx}"
        search_body="{\"query\":{\"range\":{\"time\":{\"gte\":\"${day}\",\"lte\":\"${day}\"}}}}"

        if [ "$stage_export" = true ]; then
            echo " * Downloading ${index_name} for ${day}"
            "$elasticdump" \
                --input="${ELASTIC_CONNECTION%/}/${index_name}" \
                --output="${json_file}" \
                --searchBody="${search_body}" \
                --limit=10000 \
                --type=data \
                --sourceOnly \
                --overwrite \
                --quiet \
                || fail "export of ${index_name} for ${day} failed"
            echo " * Saved ${json_file} ($(du -sh "${json_file}" | cut -f1))"
        fi

        if [ "$stage_bq_upload" = true ]; then
            if [ -s "$json_file" ]; then
                bq_upload "$idx" "$json_file" "$partition"
            else
                echo " * No data in ${json_file}, skipping upload"
            fi
        fi

        if [ "$stage_cleanup" = true ]; then
            rm -f "$json_file"
        fi
    done

    day=$(add_day "$day")
done

echo "Done."
