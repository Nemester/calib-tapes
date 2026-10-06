# calib-tapes

A small POSIX shell script that cycles tapes through a tape library drive:
it loads each requested slot, keeps the tape mounted for a configurable
time, then unloads it again.

Useful for:

- letting new media **calibrate / acclimatize** in a drive before first use
- **exercising** (re-tensioning) tapes that have been in storage for a long time
- **burn-in testing** a changer and its drives

It works with any SCSI medium changer supported by [`mtx`](https://sourceforge.net/projects/mtx/),
and can optionally drive the library through a Bacula/Bareos `mtx-changer`
script instead.

> [!WARNING]
> Do **not** run this while backup software (Bareos, Bacula, Amanda, …) is
> using the changer. Stop the storage daemon or disable the autochanger
> device first (otherwise both will try to move tapes at the same time.)

## Features

- Slot lists and ranges: `5`, `1-24`, `1-4,9,20-22`
- Checks before every move that the slot is full and the drive is empty
- Empty slots are skipped (or abort with `--strict`)
- Retries failed loads/unloads with a configurable delay and limit
- Progress bar with remaining time when running in a terminal; plain log
  output otherwise (cron, systemd, `nohup`)
- On Ctrl-C / `SIGTERM` / `SIGHUP` the currently loaded tape is unloaded
  before exiting
- `--dry-run` to preview what would happen
- Optional `mt offline` before unload for libraries that need the drive to
  eject first
- Pure POSIX `sh`
  
## Requirements

- `mtx`
- `mt` (only with `--offline`)
- `awk`, `date`, `sleep`, `tr` (standard on any Unix-like system)
- Read/write access to the changer device (usually root or the `tape` group)

## Finding your devices

```sh
lsscsi -g                      # changer shows as "mediumx", note its /dev/sgN
ls -l /dev/tape/by-id/         # stable names for changer and drives
mtx -f /dev/sgN status         # drive indexes are the "Data Transfer Element" numbers
```

Prefer the `/dev/tape/by-id/...` paths (`/dev/sgN` and `/dev/nstN` numbering can change between reboots.)

## Usage

```
calib-tapes.sh -c CHANGER -s SLOTS [options] [SLOTS...]
```

| Option | Env variable | Default | Description |
|---|---|---|---|
| `-c`, `--changer DEV` | `CHANGER` | — | Changer control device (required) |
| `-s`, `--slots LIST` | `SLOTS` | — | Slots to process, e.g. `1-4,9` (required; may also be positional) |
| `-n`, `--drive-index N` | `DRIVE_INDEX` | `0` | Drive number (Data Transfer Element) |
| `-d`, `--drive DEV` | `DRIVE` | — | Drive tape device; required for `--offline` / `--mtx-changer` |
| `-w`, `--wait SECS` | `WAIT_SECS` | `200` | How long each tape stays loaded |
| `-r`, `--retry-delay SECS` | `RETRY_SECS` | `60` | Delay between retries |
| `-m`, `--max-retries N` | `MAX_RETRIES` | `0` | Give up after N attempts (`0` = forever) |
| `-o`, `--offline` | `OFFLINE` | off | `mt offline` before each unload |
| `--mtx-changer PATH` | `MTX_CHANGER` | — | Use a Bacula/Bareos `mtx-changer` script |
| `--strict` | `STRICT` | off | Abort on empty slots instead of skipping |
| `--dry-run` | `DRY_RUN` | off | Print commands without moving tapes |
| `-q`, `--no-progress` | `PROGRESS` | `auto` | Disable the progress bar (`auto`/`yes`/`no`) |
| `-h`, `--help` | | | Show help |
| `-V`, `--version` | | | Show version |

`MTX_BIN` and `MT_BIN` override the paths of `mtx` and `mt`.
Command-line options take precedence over environment variables.

## Examples

Keep the tape in slot 62 in drive 2 for two hours:

```sh
calib-tapes.sh -c /dev/sg5 -n 2 -s 62 -w 7200
```

Exercise slots 1–24 in drive 1, ejecting via `mt` before each unload:

```sh
calib-tapes.sh -c /dev/sg5 -n 1 -d /dev/nst1 --offline 1-24
```

Go through Bareos' `mtx-changer` script (honours its config, e.g. `offline`
and `load_sleep` settings):

```sh
calib-tapes.sh \
  -c /dev/tape/by-id/scsi-XXXXXXXX \
  -d /dev/tape/by-id/scsi-YYYYYYYY-nst \
  -n 2 \
  --mtx-changer /usr/lib/bareos/scripts/mtx-changer \
  10-20,30
```

Preview first, then run unattended with a log file:

```sh
calib-tapes.sh -c /dev/sg5 -s 1-50 --dry-run
nohup calib-tapes.sh -c /dev/sg5 -s 1-50 -w 3600 > calib.log 2>&1 &
```

Typical Bareos workflow:

```sh
echo "disable storage=Tape drive=2" | bconsole   # or stop bareos-sd
calib-tapes.sh -c /dev/sg5 -n 2 -s 60-70 -w 7200
echo "enable storage=Tape drive=2" | bconsole
```

## Exit status

| Code | Meaning |
|---|---|
| 0 | All slots processed |
| 1 | Runtime error (device missing, drive not empty, load/unload gave up, …) |
| 2 | Usage error |
| 129 / 130 / 143 | Interrupted by SIGHUP / SIGINT / SIGTERM |


## License

MIT

## ⭐ Support the Project

If you find this project useful, please consider giving it a star on GitHub.
It helps others discover the project and motivates me to keep improving it. Thank you for your support!
