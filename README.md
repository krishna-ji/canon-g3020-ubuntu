# canon-g3020-ubuntu

Build & install the **Canon PIXMA G3020** *printer* and *scanner* drivers on a
**modern Ubuntu** (tested on **Ubuntu 26.04 / gcc 15**) with a **single script**.

Canon only publishes 2020-era source packages (`cnijfilter2` 6.10 and
`scangearmp2` 4.10). Those sources **do not build** on a current toolchain —
gcc 15 defaults to C23 and rejects the old code, `debhelper` rejects the old
compat level, a build dependency was renamed years ago, and more. This repo
carries both Canon source trees under [`src/`](src/), with the portability
fixes built in. `install.sh` builds the `.deb` packages and sets up the drivers.
No Canon downloads are needed; APT supplies the Ubuntu dependencies.

> Not affiliated with Canon. Canon's redistributed sources remain © Canon Inc.
> See [`NOTICE`](NOTICE).

---

## TL;DR

```bash
git clone https://github.com/krishna-ji/canon-g3020-ubuntu.git
cd canon-g3020-ubuntu
./install.sh
```

The installer configures a print queue if it discovers one G3020 on the
network. Check ink with `canon-ink <printer-ip>` and scan with `scangearmp2`,
`scanimage`, or **Document Scanner** if you have it installed.

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

1. **Installs dependencies** from Ubuntu using the driver packages' own
   `debian/control` files.
2. **Builds** both packages from temporary copies of the local source trees
   and saves the `.deb` files in `build/`. See [`docs/PORTING.md`](docs/PORTING.md)
   for the fixes in the source trees.
3. **Installs** the packages, CUPS/SANE utilities, and the `canon-ink` helper.
4. **Configures** a `Canon_G3020` CUPS queue using Canon's `cnijbe2://`
   network backend if exactly one G3020 is discovered.

Options:

```bash
./install.sh --no-queue               # install without configuring CUPS
./install.sh --build-only             # install build dependencies and produce .deb files
./install.sh --build-only --skip-deps # build offline without sudo if dependencies are installed
./uninstall.sh                        # remove queue, packages and helper
```

### Prebuilt packages

[GitHub Releases](https://github.com/krishna-ji/canon-g3020-ubuntu/releases)
has the same two `.deb` files that `install.sh` writes to `build/`, built
for Ubuntu 26.04 (`amd64`):

- `canon-g3020-printer_6.10-1_amd64.deb`
- `canon-g3020-scanner_4.10-1_amd64.deb`

To install just the driver packages, download both files and run this from
their download directory:

```bash
sudo apt install ./canon-g3020-printer_6.10-1_amd64.deb ./canon-g3020-scanner_4.10-1_amd64.deb
```

Use `./install.sh` for automatic CUPS queue setup and the `canon-ink` helper.

---

## Using it

### Print

Once configured, **`Canon_G3020`** is the system default. Print from any app.

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
├── install.sh              # one-shot: dependencies → build → install → configure
├── uninstall.sh
├── tools/
│   └── canon-ink           # ink-level readout via IPP
├── src/                    # extracted Canon sources, packaging, and vendor libraries
│   ├── cnijfilter2-source-6.10-1/
│   └── scangearmp2-source-4.10-1/
├── build/                  # generated .deb files (ignored by Git)
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
| 1 | gcc 15 uses **C23** — implicit declarations, `int`/pointer mismatches are now **errors** | set legacy GCC compatibility flags in each package's `debian/rules` |
| 2 | `debian/compat = 4` rejected by **debhelper 13** | bump to `10` |
| 3 | Build-dep **`libcupsys2-dev`** no longer exists | replace with `libcups2-dev` |
| 4 | `autogen.sh` needs the `libtool` binary | install **`libtool-bin`** |
| 5 | `lgmon3` needs libxml2 headers | install **`libxml2-dev`** |
| 6 | debhelper now **executes** executable config files; Canon shipped `debian/docs` as 0775 | `chmod -x debian/docs` |
| 7 | `dpkg` now defaults **`Rules-Requires-Root: no`**, so `install -o lp -g lp` fails | add `Rules-Requires-Root: binary-targets` (+ `fakeroot`) |
| 8 | `cups-browsed` auto-created a broken `implicitclass://` queue ("No suitable destination host found") | create and default to the permanent Canon queue |

Notably, several *deprecated* autotools macros (`AM_CONFIG_HEADER`, 2-arg
`AM_INIT_AUTOMAKE`, `AC_PROG_LIBTOOL`) still work on automake 1.18 / autoconf
2.72, so the `configure.in` files were left untouched.

## Credits

- Canon Inc. — original `cnijfilter2` / `scangearmp2` sources.
- Porting, scripts and docs: community (MIT-licensed, see `NOTICE`).
