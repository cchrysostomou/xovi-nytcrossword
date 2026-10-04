# xovi-nytcrossword

An [AppLoad](https://github.com/asivery/rm-appload) app for reMarkable tablets
running [XOVI](https://github.com/asivery/xovi) that will bring the New York Times
crossword onto the tablet.

> **Status:** Python-free import workflow implemented. The app calculates date
> ranges, downloads NYT print PDFs with `curl`, merges multi-day collections
> with `qpdf` or `mutool`, and imports through XOVI/rm-librarian. A configured
> tablet is still required for an end-to-end live import.

## Layout

```text
xovi/appload/nyt-crossword/   AppLoad app (frontend-only QML)
  manifest.json
  application.qrc
  icon.png
  ui/NytCrossword.qml
scripts/
  nytcrossword-run.sh         entry point the QML invokes
  nytcrossword-shell.sh       Bash backend; every command prints one JSON object
  package-xovi-appload.ps1    builds dist/xovi-nytcrossword-appload-app.zip
  package-tablet.ps1          builds dist/xovi-nytcrossword-runtime.zip
  update-remarkable.ps1       builds both and deploys them over SSH
config.example.env            template for the tablet's config.env
scripts/nytcrwd.py             optional desktop prototype (not wired to AppLoad)
tests/test_appload.py
```

The app sets `"loadsBackend": false` and uses
`net.asivery.CommandExecutor` (`AsyncCommandExecutor`) to run
`/home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh`. All network and file
work belongs in the shell backend; the QML calculates the selected local dates
and renders structured JSON output. Python is not required on the tablet.

## Backend commands

On firmware 3.28 the runtime package includes `nytQuickDownload.qmd`, installed
by the deployment script into qt-resource-rebuilder. It adds an **NYT** Quick
Settings button alongside other quick actions. Restart xochitl with XOVI to
load the patch. The button scans today's library coverage when visible and
every 15 seconds, and is hidden until a successful check or if today is
already present. Pressing it runs `download-today`, which rechecks under the
import lock and imports only a missing crossword. Errors and completion use
native notifications. Detection uses the same naming/folder rules as the app.
`today-status` performs the read-only check using the tablet's local date.

```sh
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh version
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh status
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh \
  preview 2026-10-01 2026-10-04 Oct0126,Oct0226,Oct0326,Oct0426
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh \
  import 2026-10-01 2026-10-04 Oct0126,Oct0226,Oct0326,Oct0426
```

`status` reports cookie configuration, `curl`, PDF-merger, and broker readiness.
`preview` validates a one-to-31-day range without downloading.
`import` downloads every requested PDF, validates it, groups by calendar month,
and splits each month into Sunday–Saturday weeks, merging each selected weekly
group in date order. It ensures each weekly folder and imports one document
per contiguous group. Errors are one
`{"ok":false,"error":"<code>","message":"<text>"}` object with a non-zero exit
code. A failed date aborts the entire collection rather than importing a partial
range.

## Configuration

On the tablet, copy `config.example.env` to
`/home/root/xovi-nytcrossword/config.env` and set `NYT_S_COOKIE`. The backend
parses `KEY=value` lines and never sources the file. Packages never contain
`config.env` or `state/`, so redeploying keeps your settings.

Set `CROSSWORD_FOLDER` to the base library path. Imports automatically use a
year/month/week folder such as
`/Crosswords/NYT_Cwd_2026/10_October/2026-10-04-10`. Year folders use
`NYT_Cwd_{year}`. Week folder dates cover the
Sunday–Saturday week clipped to that calendar month, not just the selected
dates. A cross-month week uses separate paths, for example
`NYT_Cwd_2026/09_September/2026-09-27-30` and `NYT_Cwd_2026/10_October/2026-10-01-03`.
PDFs contain only the selected dates and are named
`NYT_Cwd_YYYY-MM-DD.pdf` for a single date or
`NYT_Cwd_YYYY-MM-DD-YYYY-MM-DD.pdf` for a range.
`preview` returns a `groups` array with dates, puzzle counts, and destinations;
successful imports return a `documents` array. All downloads and merges finish
before library imports begin. If a later monthly import fails, earlier imports
may already exist; the uncertainty marker records confirmed document UUIDs and
blocks automatic retry until those imports are reconciled. Existing documents
are not moved. The default broker FIFOs are
`/run/xovi-mb` and `/run/xovi-mb-out`.

Selecting a range now uses `view` to inspect local library metadata and show
each date as present or missing, including the names of matching PDFs.
**Download missing** uses `import-missing`, rescanning immediately before
downloading. Existing PDFs are not replaced. Missing dates are grouped into
contiguous runs within each month, so gaps already covered by existing PDFs
are never included in a new PDF's date-range filename.

Detection requires `jq` (also detected at `/home/root/.vellum/bin/jq`) and the
local xochitl library. It recognizes PDFs named
`NYT_Cwd_YYYY-MM-DD` or `NYT_Cwd_YYYY-MM-DD-YYYY-MM-DD` in the configured
year/month/week folders (with or without `.pdf`). Existing PDFs directly in
the corresponding year/month folder also count toward coverage. Previous
numeric-year folders (with or without week subfolders) remain recognized;
existing files and folders are not renamed. The previous
`NYT Crosswords YYYY-MM-DD to YYYY-MM-DD` names remain recognized; existing
files are not renamed.
Trashed/deleted documents and missing PDF files do not count. Renamed PDFs,
legacy folders, and manually imported files with different names are not
automatically recognized. The filename is treated as the date-coverage record;
the app does not inspect the crossword content of individual PDF pages.

Presets include Today, This Week (Sunday through today), This Month,
Last Week (the previous complete Sunday–Saturday week), and Last Month
(the previous complete calendar month). Ranges can cross a year boundary,
while retaining the 31-day limit. Existing library files are not moved.

The AppLoad app's **Settings** screen edits the NYT-S session cookie, base
destination folder, and broker wait limit (1-300 seconds). Leave the masked
cookie field blank to preserve the saved cookie. Settings are saved locally,
without putting credentials in command arguments or logs. The private draft
is written inside the owner-only state directory, consumed on save, and the
configuration is replaced atomically with owner-only permissions. Other
configuration keys are preserved. Saving settings does not test NYT login.

### Optional desktop Python prototype

The optional Python script downloads and merges PDFs, then uploads them using
an installed `rmapi` CLI. It is retained as the original desktop prototype,
is not used by AppLoad, and is not included in tablet packages.

Copy `config.example.env` to `config.env` at the repository root. Set
`NYT_S_COOKIE` (the session value only), or `NYT_COOKIE` (the full Cookie header).
Optionally set `RMAPI_PATH` and `RMAPI_FOLDER` for your local upload destination.
Values are plain text without surrounding quotes. Personal values belong only
in the Git-ignored `config.env`, never in the example or source code.

```powershell
python -m pip install -r requirements.txt
python .\scripts\nytcrwd.py 7
python .\scripts\nytcrwd.py 7 --config .\config.env
```

`NYTCROSSWORD_CONFIG` can also select the config file. Credentials are no longer
accepted as command-line arguments, avoiding exposure in shell history and
process listings.

## Build and deploy

The AppLoad package needs Qt `rcc`. If `rcc` is not on `PATH`, the script uses
WSL to download it once into `~/.cache/xovi-nytcrossword/rcc` (with
`apt-get download`). No Qt files are committed or copied to the tablet.

```powershell
.\scripts\package-xovi-appload.ps1   # dist\xovi-nytcrossword-appload-app.zip
.\scripts\package-tablet.ps1         # dist\xovi-nytcrossword-runtime.zip
.\scripts\update-remarkable.ps1 -TargetHost remarkable.local
```

Always pass your tablet's hostname or IP address explicitly with `-TargetHost`;
the deployment script has no default destination.

To install manually instead, extract the runtime zip into
`/home/root/xovi-nytcrossword/` and the AppLoad zip into
`/home/root/xovi/exthome/appload/`. Then restart or refresh AppLoad.

Runtime requirements on the tablet:

- `rm-appload`
- `qt-command-executor` XOVI extension
- TLS-capable `curl` (the backend also detects `/home/root/.vellum/bin/curl`)
- XOVI message broker and `rm-librarian`
- Bash, `flock`, and `stat` for safe broker access; no external `timeout` needed
- `jq` for the range view and missing-file detection
- `qpdf` or `mutool` for multi-day imports; Today works without a merger

### External installation manifest

The app is intentionally designed to run with the XOVI/AppLoad environment, but
it still depends on a few pieces that are not bundled by the repo itself.
Future device provisioning should ensure the following are present and active:

- System/runtime:
  - `curl` with TLS support
  - `flock`, `stat`, `date`, `mktemp`, `sed`, `grep`, `tr`, `sort`, `head`
  - Bash for bounded broker calls using a cancellable builtin-only worker
  - `qpdf` or `mutool` for multi-day imports
- XOVI integration:
  - `rm-appload`
  - `qt-command-executor` extension package
  - message broker FIFOs at `/run/xovi-mb` and `/run/xovi-mb-out`
  - running `xochitl` / XOVI environment before imports
  - `rm-librarian` accessible by the broker
- Configuration:
  - private `config.env` with `NYT_S_COOKIE`
  - `CROSSWORD_FOLDER` or `RMAPI_FOLDER` destination path

The app checks the environment before import and fails gracefully if the broker or
merger is missing, rather than silently importing a partial or invalid document.

The shell backend keeps downloads in a private temporary directory. It validates
the `%PDF-` signature before merging and importing, writes an uncertainty marker
before `importDocument`, and only removes it after rm-librarian returns a valid
document UUID. If an import times out, inspect the library before clearing any
recovery marker; retrying blindly can create a duplicate.

Broker requests run in a Bash subprocess using only builtins for FIFO I/O.
The parent enforces `BROKER_TIMEOUT_S` and kills and reaps that exact worker on
timeout or cancellation. No external `timeout` executable is required.

## Tests

Install the standalone downloader's dependencies from `requirements.txt` first.
Run the tests with:

```sh
python3 -m unittest discover -s tests -v
```

Shell backend tests need a POSIX `sh` and are skipped on Windows; run those under
WSL. The Python config tests use dummy credentials and do not make NYT requests.
