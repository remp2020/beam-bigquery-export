# Beam BigQuery Export

Daily export of [REMP Beam](https://github.com/remp2020/remp) tracking data from Elasticsearch to BigQuery.

For each day (yesterday by default) and each Beam index, the script dumps the day's documents from
Elasticsearch and loads them into a BigQuery table partitioned by day. The day's partition is replaced
on every run, so re-runs and backfills are safe.

Exported indices and their BigQuery tables (same name, schema in `bq/`):

| Index | Contents |
|---|---|
| `pageviews` | pageviews, with article, author, tags, referer and device data |
| `pageviews_time_spent` | time spent on each pageview |
| `pageviews_progress` | reading progress |
| `events` | events: banner (REMP Campaign), mail and newsletter (REMP Mailer), and your own custom events |
| `commerce` | commerce funnel steps and payments |
| `impressions` | impressions of page blocks |


## Requirements

- Node.js and npm, for [elasticdump](https://github.com/elasticsearch-dump/elasticsearch-dump)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) with the `bq` tool
- a Google Cloud service account with the **BigQuery Data Editor** and **BigQuery Job User** roles

## Installation

```bash
npm install
cp .env.example .env    # then fill it in
```

Activate the service account for the user that will run the export:

```bash
gcloud auth activate-service-account --key-file=/path/to/service-account.json
gcloud config set project YOUR_PROJECT_ID
```

## Configuration (`.env`)

| Variable | Description |
|---|---|
| `ELASTIC_CONNECTION` | Beam's Elasticsearch, e.g. `https://user:password@elastic.example.com:9200/` |
| `ELASTIC_PREFIX` | prefix of Beam's index names, if any |
| `BEAM_INDICES` | optional, comma-separated subset of the indices above (default: all) |
| `BQ_PROJECT_ID`, `BQ_DATASET_ID` | target BigQuery project and dataset |
| `SENTRY_DSN` | optional; errors are reported to Sentry if `sentry-cli` is installed |

## Usage

```bash
./beam-bigquery-export.sh                                          # yesterday
./beam-bigquery-export.sh --date=2026-10-01                        # one day
./beam-bigquery-export.sh --min_date=2026-01-01 --max_date=2026-09-30   # backfill a range
./beam-bigquery-export.sh --env=/etc/beam-export/.env --dir=/data/tmp   # other env file / work dir
```

- `--stages=export,bq_upload,cleanup` runs a subset of the stages: download from Elasticsearch, load into
  BigQuery, delete the local JSON files.
- Days are UTC. Tables that don't exist yet are created on the first load.
- A failed BigQuery load is retried twice; any failure stops the run with a non-zero exit code.

### Cron

Export yesterday's data every night:

```bash
5 3 * * * cd /path/to/beam-bigquery-export && ./beam-bigquery-export.sh --env=/path/to/.env >> /var/log/beam-bigquery-export.log 2>&1
```

## Updating a table schema

Loads use `--ignore_unknown_values`: fields that are not in the schema file are **silently dropped**.
When Beam starts sending a new field, add it to the schema file and to the BigQuery table:

1. Add the column at the end of `bq/<index>_schema.json` (new columns must be `NULLABLE` or `REPEATED`):
   ```json
   {"name": "new_field", "type": "STRING", "description": "added 2026-10-14"}
   ```
2. Update the table:
   ```bash
   bq update YOUR_PROJECT_ID:YOUR_DATASET.events bq/events_schema.json
   ```
3. Re-export the days you need with `--date` / `--min_date --max_date`.

To compare with the live schema: `bq show --schema --format=prettyjson YOUR_PROJECT_ID:YOUR_DATASET.events`.

## Notes

- Backfills only work for days still kept in Elasticsearch; check your Beam index retention.
- The `pageviews` schema includes `ip` and `user_agent`. If you don't want personal data in BigQuery,
  remove them from the schema file before the first export (the table is created from it).
