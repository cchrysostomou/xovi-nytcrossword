# xovi-nytcrossword

An [AppLoad](https://github.com/asivery/rm-appload) app for reMarkable tablets
running [XOVI](https://github.com/asivery/xovi) that will bring the New York Times
crossword onto the tablet.

> **Status:** boilerplate. The app launches, calls the shell backend, and shows
> whether the backend is configured. Puzzle fetching and solving are not
> implemented yet.

## Layout

```text
xovi/appload/nyt-crossword/   AppLoad app (frontend-only QML)
  manifest.json
  application.qrc
  icon.png
  ui/NytCrossword.qml
scripts/
  nytcrossword-run.sh         entry point the QML invokes
  nytcrossword-shell.sh       POSIX sh backend; every command prints one JSON object
  package-xovi-appload.ps1    builds dist/xovi-nytcrossword-appload-app.zip
  package-tablet.ps1          builds dist/xovi-nytcrossword-runtime.zip
  update-remarkable.ps1       builds both and deploys them over SSH
config.example.env            template for the tablet's config.env
tests/test_appload.py
```

The app sets `"loadsBackend": false` and uses
`net.asivery.CommandExecutor` (`AsyncCommandExecutor`) to run
`/home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh`. All network and file
work belongs in the shell backend; the QML only renders its JSON output.

## Backend commands

```sh
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh version
sh /home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh status
```

`status` returns `{"ok":true,"version":"0.1.0","configured":<bool>}`. Errors are
`{"ok":false,"error":"<code>","message":"<text>"}` with a non-zero exit code.

## Configuration

On the tablet, copy `config.example.env` to
`/home/root/xovi-nytcrossword/config.env` and set `NYT_S_COOKIE`. The backend
parses `KEY=value` lines and never sources the file. Packages never contain
`config.env` or `state/`, so redeploying keeps your settings.

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

## Tests

Shell backend tests need a POSIX `sh`, so run the suite from WSL:

```sh
python3 -m unittest discover -s tests -v
```
