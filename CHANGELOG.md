# Changelog
 
All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).
 
## [1.0.1] - 2026-10-06
 
### Fixed
- Passing a tape drive (`/dev/nstN`, `...-nst`) as `--changer` is now rejected
  immediately with a hint, instead of failing after a long SCSI timeout.
- Startup check via `mtx inquiry` verifies the device is a medium changer
  before any slot is processed.


## [1.0.0] - 2026-10-06
 
### Added
- Command-line options (short and long) in addition to environment variables.
- Slot lists and ranges (`1-4,9,20-22`), also as positional arguments.
- Plain `mtx` backend (default); `--mtx-changer` for Bacula/Bareos scripts.
- `--offline` to eject via `mt` before unloading.
- `--dry-run`, `--strict`, `--no-progress`, `--help`, `--version`.
- Automatic unload of the loaded tape on SIGINT/SIGTERM/SIGHUP.
- Progress bar only on a TTY, with remaining time as HH:MM:SS.
- Summary of cycled and skipped slots.
### Changed
- No hard-coded devices; the changer must be given explicitly.
- Empty slots are skipped with a warning instead of aborting.
- More robust parsing of `mtx status` (handles import/export slots).
### Fixed
- Slot numbers with leading zeros no longer break shell arithmetic.
- Wait time of 0 no longer causes a division by zero.
 
