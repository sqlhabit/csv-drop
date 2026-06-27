# CSV Drop

<img src="https://github.com/sqlhabit/csv-drop/blob/main/snapshot.png?raw=true" width="500">

A lightweight macOS app for uploading CSV files to BigQuery.

Behind the scenes, the app uses [`bqcsv`](https://github.com/sqlhabit/bqcsv) to upload a CSV file.

No API keys or OAuth setup required — the app reuses your existing `gcloud` / `bq` credentials.

## Installation

1. Install **CSV Drop** from the Mac App Store.
2. Run the setup script to install `bqcsv` and verify the Google Cloud SDK:

```bash
curl -fsSL https://raw.githubusercontent.com/sqlhabit/csv-drop/refs/heads/main/bin/install | bash
```

The script checks for `bq` / `gcloud`, installs `bqcsv` (via Homebrew Python when available), and prints next steps.

## Prerequisites

1. [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) with `bq` and `gcloud` installed.
2. `bqcsv` CLI installed (the setup script above handles this).
3. Authenticated CLI session:

```bash
gcloud auth login
gcloud auth application-default login   # optional, if bq asks for ADC
```

## Development

Debug builds can run against a local `bqcsv` checkout instead of an installed CLI:

```bash
cp Development.xcconfig.example Development.xcconfig
# edit Development.xcconfig and set BQCSV_DEV_REPO to your checkout
```

The repo root must contain `src/cli.py`. The app runs `python3 -m src.cli` with `PYTHONPATH` set to that directory. `Development.xcconfig` is gitignored; the shared Xcode scheme passes `BQCSV_DEV_REPO` into the app at launch.

If `BQCSV_DEV_REPO` is unset, Debug falls back to the same lookup as Release (`BQCSV_PATH`, Homebrew, pyenv, `PATH`).
