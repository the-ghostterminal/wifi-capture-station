# wifi-capture-station

A boot-time Wi-Fi survey station for a Raspberry Pi: it decides from link state
whether it is "home" or "in the field", captures in monitor mode when it is in
the field, and folds the results into a single human-readable record when it
gets back on a network.

Roughly 600 lines of bash across seven scripts, no daemon, no database, no
runtime dependencies beyond `hcxdumptool`, `hcxpcapngtool`, `iw` and `curl`.

The interesting part is not the capture. It is the mode switching, the power
gate, and the fact that every write to the record is atomic - the things that
decide whether an unattended box produces usable data or a corrupt card.

## Architecture

```
                     run_pipeline.sh  (single entry point, one run at a time)
                            |
        +-------------------+--------------------+
        |                                        |
   at_home? yes                             at_home? no
        |                                        |
   skip capture                       capture.sh -> monitor mode
        |                              hcxdumptool -> capture.pcapng
        |                                        |
        |                              SIGTERM, or exit on its own
        +-------------------+--------------------+
                            |
                    extract_macs.sh      pcapng -> .22000 -> AP records
                            |
                       upload.sh          one capture per request, retries
                            |
                    sync_results.sh       results back into the record
```

| Script | Job |
|---|---|
| `bin/common.sh` | paths, logging, the **only** record parser/writer, uplink detection |
| `bin/capture.sh` | preflight, power gate, monitor mode, `hcxdumptool`, cleanup on signal |
| `bin/extract_macs.sh` | `hcxpcapngtool` -> hash lines -> new access points |
| `bin/upload.sh` | POST each finished capture with exponential backoff |
| `bin/sync_results.sh` | pull the backend results file, merge keys back in |
| `bin/gen_blacklist.sh` | compile exclusions into a BPF filter |
| `bin/run_pipeline.sh` | mode decision, locking, signal handling |

## Design decisions

**Link state decides the mode, not IP presence.** A stale DHCP lease from the
last drive looks exactly like a live connection, so an IP-based check would
silently skip an entire session. Carrier state cannot be stale.

**"Home" means "there is an uplink I am not capturing on".** Carrier on `eth0`
alone was wrong for this build: the Pi's uplink is a second radio, so `eth0` was
down while the box was on the sofa, and the station started capturing indoors.
The check now falls back to the default route, and only counts it when it is not
the capture interface.

**Undervoltage aborts before the radio is touched.** `vcgencmd get_throttled` bit
0 is the authoritative signal on a Pi; a hwmon voltage read is the fallback for
other boards. A brownout during a write corrupts the capture and sometimes the
card. No sensor means warn, not fail.

**The capture process is killed by the trap, not waited on.** Bash defers a
trap until the foreground command returns, so with `hcxdumptool` in the
foreground a `SIGTERM` did nothing until the capture ended by itself. It now
runs in the background and the cleanup trap terminates it.

**One parser, one writer.** The `mac > essid > key` format was originally parsed
in three places and they drifted. `common.sh` owns `load_entries` and
`write_entries`; everything else calls them.

**Writes are atomic.** The record and the key pool are built in a temp file in
their own directory and renamed. `/tmp` on this box is tmpfs, so a
temp-then-move from `/tmp` is a copy: a kill mid-move truncated the file.

**ESSIDs are decoded in bash, never through `printf`.** `hcxpcapngtool` emits
hex. Piping it through `sed | xargs printf` made the network name the *format
string*, so any `%` in an ESSID corrupted or blanked it. The decoder now builds
`\xHH` pairs into a variable and passes them to `%b` as data, which also removes
the `xxd` dependency.

**The uploader is the only network edge, and it is configurable.** Endpoints
live in `config/wardrive.conf`, not in the scripts. With no endpoint set the
step reports that and exits `0`, so the rest of the pipeline still runs.

**Failures are loud.** `code=$(retry_curl ...)` under `set -e` killed the script
before the failure branch could run, so upload errors were invisible. The retry
helper now returns and its status is tested.

**The BPF exclusion list is capped.** Each excluded address costs three clauses
and the compiled filter has a size limit. Past the cap the filter is built from
the first N entries and says so, instead of producing something the kernel
rejects and capturing nothing.

**One entry point.** Two systemd units running `capture.sh` and
`run_pipeline.sh` meant two processes fighting over the interface. The pipeline
takes a `flock` and is the only thing that starts a capture.

## The record format

```
aabbccddeeff  >  Cafe Guest                    >  passphrase here
112233445566  >  NoKeyNetwork
```

Twelve lowercase hex characters, then `  >  `. Deliberately readable: the file
gets opened at a desk, not queried. Sorted by MAC, columns aligned to the
longest ESSID, written atomically.

## Install

```sh
sudo ./install.sh              # /opt/wardrive
sudo ./install.sh /srv/wardrive
```

Then set the two endpoints and the key:

```sh
sudo $EDITOR /opt/wardrive/config/wardrive.conf
sudo $EDITOR /opt/wardrive/config/secrets.conf   # chmod 600, API_KEY=...
```

`install.sh` enables a single `wardrive-pipeline.service`. It runs at boot,
decides the mode, and exits.

## Testing

```sh
sudo ./tests/smoke.sh
```

Offline. Runs against a throwaway tree: record round-trip, ESSID decoding
(including `%`), parser behaviour on synthetic hash lines, deduplication, and
BPF generation. It never touches live data.

Single files can be processed directly, which is also how the parser is
exercised:

```sh
./bin/extract_macs.sh capture.pcapng
./bin/extract_macs.sh capture.22000
```

`DRY_RUN=1` makes `upload.sh` and `sync_results.sh` describe what they would do
without touching the network.

## Field notes

Bugs this build found the hard way, all now fixed, all visible in the history:

| Symptom | Cause |
|---|---|
| Captures never uploaded, no error logged | `set -e` + command substitution killed the script before the failure branch |
| Record order flipped between runs | sorted file built, unsorted file written |
| One network name blank in the record | ESSID used as a `printf` format string |
| Kill left the radio in monitor mode | trap waited for the foreground dump to finish |
| Station captured at home | mode decided on `eth0` alone, uplink was another radio |
| Key pool truncated after a power cut | temp file in `/tmp`, then a copy+delete instead of a rename |
| Two captures at boot | two units starting the capture path |
| Clean capture exit skipped all post-processing | post steps only ran on the signal path |

## Scope and legality

This is a radio survey tool. It only records what is broadcast in the clear, and
it does nothing that a phone with a survey app cannot do.

Use it on networks you own or have written authorisation to test. Passive
capture of third-party traffic is regulated in most jurisdictions - in the UAE,
Federal Decree-Law 34/2021 - and "I was only collecting" is not a defence. The
repository contains no captured data, no keys and no endpoints; keep it that
way in your fork.

## Licence

MIT. See `LICENSE`.
