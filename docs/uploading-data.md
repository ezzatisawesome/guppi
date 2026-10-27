# Uploading data files

Bring data recorded somewhere else — a data logger, a scope export, a
spreadsheet, another bench's `guppi query` export — into a rig's history, where
it plots, queries and exports like anything the rack recorded. The same command
works against a local hub and Guppi Cloud.

```
guppi upload run3.csv --dry-run     # read it, show what would be stored
guppi upload run3.csv               # store it
```

Each column becomes a signal named `<device>.<column>` — `run3.voltage`,
`run3.current` — where the device defaults to the file name (`--device` to
choose). Add `--recording` to also list the file as a recording — a session on
the timeline, named after the file and spanning its time range. Uploading the same file
again does nothing: the hub recognizes the bytes.

A file is stored all at once or not at all — if anything goes wrong partway,
nothing is left behind and you can simply run it again.

Uploaded it wrong (the wrong `--tz`, say)? Take it back out and send it again:

```
guppi uploads                 # list them, with ids
guppi uploads rm 3f2a91c0     # delete one (an id prefix is enough)
```

That removes the upload's samples (and its session, if it made one), and
nothing else. If two
uploads wrote into the same signals over overlapping times, their data can't be
told apart, so deleting just one of them is refused.


## From the browser

Drag a CSV anywhere in Guppi and it goes to the rig you're looking at; a rig's
own page also has an **Upload data** button. Either way the hub reads the file
first and reports what it found — the format it picked, the time column, every
signal with its unit and sample count, and any warnings — and nothing is stored
until you confirm. The dialog is a thin client over the same
`POST /rigs/{rig_id}/uploads` door described below, so a file behaves
identically whether it arrives from `guppi upload` or from a drag: the same
detection, the same messages, the same checksum de-duplication.

Two differences worth knowing. A browser upload asks for a recording by
default (`recording=true`), because the Runs list is how you then find the
window the file covers. And an elapsed-time file has no absolute time in it, so
the hub refuses it until you say when time zero was; the dialog asks for that
inline and re-reads the file.

## What it reads

CSV today; more formats are coming. Everything below is **detected**, and
`--dry-run` shows what was picked, so you only pass an option when the guess is
wrong.

| | Detected | Option |
|---|---|---|
| Delimiter | `,` `;` tab `\|` | `--delimiter ';'` |
| Decimal mark | `1.25`, or `1,25` in a semicolon file | `--decimal ,` |
| Lines before the header | instrument metadata at the top | `--skip-rows 12` |
| Header | present, or none (columns become `col1`, `col2`, …) | |
| Units | `Voltage (V)`, `Current [A]`, or a second header row of units | `--unit Druck=hPa` |
| Layout | **wide** (a column per signal) or **long** (a row per sample) | `--layout long` |
| Time column | named time/timestamp/date/t/elapsed…, else the first column; separate `Date` + `Time` columns are joined | `--time-column Stamp` |
| Time format | see below | `--time-format epoch_ms` |
| Encoding | UTF-8 (with or without Excel's BOM), UTF-16 (Excel's "Unicode Text"), else Windows-1252 | `--encoding latin-1` |

### Times

| Written as | Format name | Notes |
|---|---|---|
| `2026-10-26T14:30:00.125Z`, `2026-10-26 14:30:00`, `… 14:30:00 UTC` | `iso` | a time without a zone is read in **this computer's** zone — `--tz Europe/Berlin` or `--tz +08:00` to say otherwise |
| `1761489000`, `1761489000125`, … | `epoch_s` `epoch_ms` `epoch_us` `epoch_ns` | the unit is picked by size |
| `0.000`, `0.001`, … time since the start | `elapsed_s` `elapsed_ms` `elapsed_us` | needs `--start 2026-10-26T14:30:00`; the unit comes from the header (`Time (ms)`), seconds if none |
| `00:01:02.5`, `01:02.5` (a stopwatch, no date) | `elapsed_clock` | needs `--start`; for times of day, that day's midnight |
| `Mon, 26 Oct 2026 14:30:00 GMT` | `rfc2822` | HTTP dates, web and server logs |
| `45589.6041` | `excel` | Excel serial days; never guessed — pass it |
| `26/10/2026 14:30:00`, `2026/10/26 14:30`, `10/26/2026 2:30 PM`, `26.10.2026 14:30` | detected | slash dates are month-first unless a day over 12 shows otherwise |
| anything else | a strptime pattern | `--time-format '%d-%m-%Y %Hh%M'` |

### Layouts

**Wide** — what most tools write:

```
Time,Voltage (V),Current (A),State
2026-10-26 14:30:00,12.01,0.50,ok
```

**Long** — one sample per row, the signal named in a column (`path`, `signal`,
`channel`, `name` or `tag`) and the value in `value`; an optional `unit`
column. This is what `guppi query --format csv` writes, so an export from one
rig uploads into another:

```
path,time,value,unit
psu1.1.voltage,2026-10-26T14:30:00Z,12.01,V
```

An upload never writes into one of the rig's own signals: if a column would
land on a live device's path (a file named `psu1.csv` with a column
`1.voltage`), it's refused — pass `--device` to file it under another name.
Adding to an earlier upload's signals (day 2 of the same logger) is fine, as
long as numbers stay numbers. One upload holds at most 5,000 signals.

Long-file paths keep their dots under the upload's prefix
(`export.psu1.1.voltage`), so uploaded history never merges into a live
signal of the same name.

### Cells that aren't numbers

A column that's mostly numbers is a numeric signal; a column of words (`ok`,
`fault`) is a text signal. Numbers may carry their unit (`12.5V`, `20 °C` —
the unit is taken from the cells when the header has none) or spreadsheet
digit grouping (`"1,234.5"`, `1.234,5`). Hex (`0x1F`) and engineering
suffixes (`4.7k`) are skipped and counted rather than misread. An empty cell is simply no sample. A cell that can't
be read — `OVL` in a voltage column — is skipped, and a row whose time can't be
read is dropped; both are counted and reported, never guessed at.

## Big files

Millions of points are fine: the hub reads the file in batches, so memory
stays flat whatever the size, and `guppi upload` compresses the file on the way
and shows a running count while the hub works. Roughly a million points a
second on a laptop hub — a 10-million-point file is about ten seconds. The
limit is 512 MB per file (about 35 million points in a typical wide file);
split anything larger, and each part becomes its own upload.

## Other ways in

The command is a thin client over one HTTP endpoint, so a script can upload
directly — the body is the file itself, options are query parameters with the
same names (`time_format`, `skip_rows`, `unit=COL=UNIT`, `dry_run=true`, …):

```
curl -X POST "http://bench.local:8000/rigs/<rig>/uploads?filename=run3.csv&tz=Europe/Berlin" \
     --data-binary @run3.csv
```

A local hub needs no sign-in. In Guppi Cloud an upload needs a signed-in
session (`guppi login`); API keys can't upload.

`guppi uploads` (or `GET /rigs/<rig>/uploads`) lists what's been uploaded;
`DELETE /rigs/<rig>/uploads/<id>` takes one out.
