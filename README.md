# canon-g3020-ubuntu

Build & install the **Canon PIXMA G3020** *printer* and *scanner* drivers on a
**modern Ubuntu** (tested on **Ubuntu 26.04 / gcc 15**) with a **single script**.

Canon only publishes 2020-era source packages (`cnijfilter2` 6.10 and
`scangearmp2` 4.10). Those sources **do not build** on a current toolchain —
gcc 15 defaults to C23 and rejects the old code, `debhelper` rejects the old
compat level, a build dependency was renamed years ago, and more. This repo
carries Canon's original sources plus a small, well-documented set of patches
and a one-shot installer that produces clean `.deb` packages and wires
everything up.

> Not affiliated with Canon. Canon's redistributed sources remain © Canon Inc.
> See [`NOTICE`](NOTICE).

---

## TL;DR

```bash
git clone https://github.com/<you>/canon-g3020-ubuntu.git
cd canon-g3020-ubuntu
./install.sh
```

That's it. When it finishes you can print from any app, check ink with
`canon-ink`, and scan with **Document Scanner** / `scangearmp2` / `scanimage`.

---

## What you get

| Feature | How |
| --- | --- |
| **Printing** | `cnijfilter2` CUPS driver + a `Canon_G3020` queue set as default |
| **Scanning** | `scangearmp2` GUI **and** driverless `sane-airscan` (eSCL/WSD) |
| **Ink levels** | `canon-ink` command (reads the printer over IPP) |

Tested environment:

- Ubuntu 26.04 (resolute), `amd64`
- gcc 15.2, debhelper 13, automake 1.18, autoconf 2.72, libtool 2.5.4
- CUPS 2.4, SANE 1.4 + sane-airscan

The printer/scanner is used over **Wi-Fi / LAN** (the G3020 is a network MFP).
USB should also work via the same driver.

---

## What the installer does

1. **Installs dependencies** (build tools + CUPS/SANE dev libraries).
2. **Extracts** Canon's original tarballs from `src/` into `build/`.
3. **Patches** them for the modern toolchain — see
   [`docs/PORTING.md`](docs/PORTING.md) for the full story.
4. **Builds** both packages using thin compiler wrappers
   ([`tools/cc`](tools/cc), [`tools/cxx`](tools/cxx)) that make 2020-era
   C/C++ compile under gcc 15.
5. **Installs** the resulting `.deb` files and the `canon-ink` helper.
6. **Configures** a `Canon_G3020` CUPS queue using Canon's `cnijbe2://`
   network backend, and disables the buggy `cups-browsed` auto-queue.

Options:

```bash
./install.sh --no-queue     # build + install drivers only
./install.sh --build-only   # just produce the .deb files under build/
./uninstall.sh              # remove queue, packages and helper
```

---

## Using it

### Print

Your default printer becomes **`Canon_G3020`**. Just print from any app.

> With the Canon backend, a small job can take ~30–60 s to leave the queue
> because the driver does an ink/status handshake after sending. That's normal.

### Check ink

```console
$ canon-ink
Canon printer @ 192.168.1.65 — ink / cartridge levels:
  Black(PGBK)    [##########] 100%
  Cyan           [########--]  80%
  Magenta        [########--]  80%
  Yellow         [########--]  80%
  MC             [######----]  60%
```

`canon-ink [printer-ip]` if it isn't at the default address. You can also open
`http://<printer-ip>` for Canon's web UI.

### Scan

- **GUI (easy):** open **Document Scanner** (`simple-scan`) → *Scan* → *Save* as PDF/JPEG.
- **GUI (Canon):** run `scangearmp2` for full resolution/mode/preview control.
- **CLI:**

  ```bash
  scanimage -L                       # find the scanner
  scanimage --mode Color --resolution 300 -o ~/scan.png
  ```

---

## Troubleshooting

- **"No scanner found"** — wake the printer (press a button) and retry; give
  network discovery a few seconds.
- **Nothing prints / job stuck** — make sure the printer is on the network and
  re-run `./install.sh` (it re-detects and rebuilds the queue). If a stale
  `implicitclass://` queue reappears, `sudo systemctl disable --now cups-browsed`.
- **Printer at a different IP** — re-run `./install.sh` (auto-detect) or:

  ```bash
  sudo lpadmin -p Canon_G3020 -E -v socket://<IP>:9100 -P /usr/share/ppd/canong3020.ppd
  ```

---

## Repository layout

```
canon-g3020-ubuntu/
├── install.sh              # one-shot: deps → patch → build → install → configure
├── uninstall.sh
├── tools/
│   ├── cc  cxx             # gcc-15 compatibility compiler wrappers
│   └── canon-ink           # ink-level readout via IPP
├── src/                    # Canon's ORIGINAL source tarballs (unmodified)
│   ├── cnijfilter2-source-6.10-1.tar.gz
│   └── scangearmp2-source-4.10-1.tar.gz
├── docs/PORTING.md         # how this was ported old → new + every change
├── NOTICE                  # licensing / attribution
└── README.md
```

## Porting summary (old → new)

The drivers were written against a ~2020 toolchain. Getting them onto Ubuntu
26.04 / gcc 15 needed these changes (details and reasoning in
[`docs/PORTING.md`](docs/PORTING.md)):

| # | Problem on the new OS | Fix |
| --- | --- | --- |
| 1 | gcc 15 uses **C23** — implicit declarations, `int`/pointer mismatches are now **errors** | build via `tools/cc`/`tools/cxx` wrappers adding `-fcommon -std=gnu17 -Wno-error …` |
| 2 | `debian/compat = 4` rejected by **debhelper 13** | bump to `10` |
| 3 | Build-dep **`libcupsys2-dev`** no longer exists | replace with `libcups2-dev` |
| 4 | `autogen.sh` needs the `libtool` binary | install **`libtool-bin`** |
| 5 | `lgmon3` needs libxml2 headers | install **`libxml2-dev`** |
| 6 | debhelper now **executes** executable config files; Canon shipped `debian/docs` as 0775 | `chmod -x debian/docs` |
| 7 | `dpkg` now defaults **`Rules-Requires-Root: no`**, so `install -o lp -g lp` fails | add `Rules-Requires-Root: binary-targets` (+ `fakeroot`) |
| 8 | `cups-browsed` auto-created a broken `implicitclass://` queue ("No suitable destination host found") | permanent Canon queue + disable `cups-browsed` |

Notably, several *deprecated* autotools macros (`AM_CONFIG_HEADER`, 2-arg
`AM_INIT_AUTOMAKE`, `AC_PROG_LIBTOOL`) still work on automake 1.18 / autoconf
2.72, so the `configure.in` files were left untouched.

## Credits

- Canon Inc. — original `cnijfilter2` / `scangearmp2` sources.
- Porting, scripts and docs: community (MIT-licensed, see `NOTICE`).
