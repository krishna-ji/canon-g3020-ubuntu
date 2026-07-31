# Porting Canon G3020 drivers from an old OS to modern Ubuntu

This document explains, in detail, **why** Canon's 2020 driver sources fail to
build on a current Ubuntu (26.04, gcc 15) and **exactly what was changed** to
make them build, install and run. Everything here is applied automatically by
[`../install.sh`](../install.sh); this file is the human-readable rationale.

## Background

Canon distributes two source packages for the PIXMA G3020:

| Package | Version | Provides |
| --- | --- | --- |
| `cnijfilter2` | 6.10-1 | CUPS raster/command filters + `cnijbe2` backend + PPDs + status monitor (`cnijlgmon3`) |
| `scangearmp2` | 4.10-1 | SANE/USB scanner engine + a GTK2 GUI (`scangearmp2`) |

Both are "classic" Debian source packages: hand-written `debian/rules` with
explicit targets that call per-component `autogen.sh` → `configure` → `make`.
They were last touched in 2020 and assume an ~Ubuntu 18.04/20.04 toolchain.

Target/build host used for the port:

```
Ubuntu 26.04 (resolute), amd64
gcc 15.2   debhelper 13.31   automake 1.18   autoconf 2.72   libtool 2.5.4
dpkg 1.22+  CUPS 2.4   SANE 1.4
```

---

## The problems and the fixes

### 1. gcc 15 defaults to C23 — old C no longer compiles

This is the big one. Since gcc 14, and firmly in gcc 15, several long-standing
"sloppy C" constructs are **hard errors by default**, not warnings:

- `-Werror=implicit-function-declaration`
- `-Werror=implicit-int`
- `-Werror=int-conversion`
- `-Werror=incompatible-pointer-types`
- `-Werror=return-mismatch`

2020-era Canon code trips all of these. It also relies on the pre-gcc-10
`-fcommon` behaviour for tentative definitions.

**Why not just patch `CFLAGS`?** Because the packages' own `configure.in`
scripts *overwrite* `CFLAGS` (e.g. `scangearmp2/configure.in` literally does
`CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"`), so anything exported into the
environment is discarded during `configure`.

**Fix — compiler wrappers.** We point `CC`/`CXX` at tiny wrapper scripts
([`tools/cc`](../tools/cc), [`tools/cxx`](../tools/cxx)) that always append the
needed flags and then exec the real compiler:

```sh
# tools/cc
exec gcc -fcommon -std=gnu17 -Wno-error \
    -Wno-implicit-function-declaration -Wno-implicit-int \
    -Wno-int-conversion -Wno-incompatible-pointer-types \
    -Wno-return-mismatch "$@"
```

Autoconf records `CC` verbatim and reuses it for every compile *and* link step,
so the flags survive even when `configure.in` clobbers `CFLAGS`. `CXX` gets
`-fcommon -fpermissive -Wno-error -Wno-narrowing`. This is the cleanest fix
because **no Canon source file is edited**.

### 2. `debian/compat = 4` is rejected by debhelper 13

Modern debhelper refuses compat levels below 7. Canon ships compat `4`.

**Fix:** write `10` into `debian/compat`. The `debian/rules` files use only
classic `dh_*` commands that still exist, so level 10 is safe without rewriting
the rules to the `dh $@` sequencer.

### 3. Renamed build dependency `libcupsys2-dev`

`cnijfilter2/debian/control` build-depends on `libcupsys2-dev`, a name retired
many Ubuntu releases ago.

**Fix:** replace it with `libcups2-dev` (and, while we're there, add the
`autoconf`/`automake`/`libtool`/`pkg-config`/`libxml2-dev` packages the build
actually needs, so `dpkg-checkbuilddeps` is honest).

### 4. `autogen.sh` needs the `libtool` *binary*

Canon's `autogen.sh` does `libtool --version` as a sanity check. On modern
Ubuntu the `libtool` package ships only `libtoolize` and the m4 macros — the
`/usr/bin/libtool` wrapper script moved to a **separate package**.

**Fix:** install **`libtool-bin`**. (Symptom if missing:
`**Error**: You must have 'libtool' installed.` during `configure`.)

### 5. `lgmon3` needs libxml2 development files

The status-monitor component includes `<libxml/parser.h>` and calls
`xml2-config`.

**Fix:** install **`libxml2-dev`**. (Symptom if missing:
`fatal error: libxml/parser.h: No such file or directory`.)

### 6. debhelper now *executes* executable config files

Since compat 9+, debhelper treats an **executable** file in `debian/` (like
`debian/docs`, `debian/install`, …) as a script to run, using its stdout as the
file list. Canon shipped every `debian/*` file mode `0775`, so `dh_installdocs`
tried to *execute* the plain text `debian/docs` and blew up:

```
debian/docs: Syntax error: "(" unexpected
dh_installdocs: error: debian/docs (executable config) returned exit code ...
```

**Fix:** `chmod -x debian/docs` in both packages so it's treated as a list.

### 7. `Rules-Requires-Root` default flipped to `no`

Canon's `debian/rules` stages files with `install -o lp -g lp …` (chown to the
`lp` user). Historically the binary target ran under `fakeroot`, so the chown
was virtualised. Modern `dpkg-buildpackage`, when the `Rules-Requires-Root`
field is **absent**, now runs the binary target **without** root emulation, so
the chown fails:

```
install: failed to chown '.../usr/share/ppd/...': Operation not permitted
```

**Fix:** add `Rules-Requires-Root: binary-targets` to the `Source:` stanza of
`debian/control` (and ensure `fakeroot` is installed). `dpkg-buildpackage` then
runs `fakeroot debian/rules binary` again and the chowns succeed.

### 8. `cups-browsed` created a broken driverless queue

Independent of the build: on first network contact, `cups-browsed`
auto-created an `implicitclass://Canon_G3020_series/` queue. Print jobs to it
hung forever with:

```
job-printer-state-message = "No suitable destination host found by cups-browsed, retrying later"
```

That is why "it wasn't printing" even though the hardware was fine.

**Fix:** create a *permanent* queue bound to Canon's `cnijbe2://` backend and
`sudo systemctl disable --now cups-browsed` so the broken duplicate can't be
recreated. (Re-enable with `systemctl enable --now cups-browsed` if you rely on
automatic discovery of other printers.)

---

## Things that did **not** need changing

Worth recording, because it saved a lot of edits:

- **Deprecated autotools macros still work.** `AM_CONFIG_HEADER`, the two-arg
  `AM_INIT_AUTOMAKE(name, version)`, and `AC_PROG_LIBTOOL` produce only
  warnings on automake 1.18 / autoconf 2.72 / libtool 2.5.4 — they still
  expand correctly, so the `configure.in` files are left untouched.
- **glib gettext is intact.** `AM_GLIB_GNU_GETTEXT`, `glib-gettextize` and
  `/usr/share/aclocal/glib-gettext.m4` are still shipped by `libglib2.0-dev`
  (glib 2.88), so the scanner's i18n build works unmodified.
- **GTK2 is still available.** `libgtk2.0-dev` exists on Ubuntu 26.04, so the
  legacy `scangearmp2` GTK2 GUI builds.
- **The prebuilt Canon `.so` blobs are fine.** They're normal `amd64` ELF
  shared objects; `dpkg-shlibdeps` warns that it "cannot find" them, but that's
  harmless — they ship inside the same package and resolve at runtime after
  `ldconfig`.

---

## Backend & ink-level notes

- **Print backend.** Two options both work:
  - `socket://<ip>:9100` (AppSocket) — dead simple and reliable.
  - `cnijbe2://Canon/?port=net&serial=<MAC>` — Canon's own backend; enables
    status readback. The installer uses this and auto-discovers the `serial`
    (MAC) via `/usr/lib/cups/backend/cnijbe2`.
- **Ink levels.** `cnijlgmon3` is *not* a standalone ink GUI — CUPS invokes it
  during jobs (it reads `CONTENT_TYPE`/`PPD` and the job data on stdin). For an
  on-demand readout we instead query the printer directly over **IPP**, which
  reports standard `marker-names` / `marker-levels`:

  ```bash
  ipptool -tv ipp://<ip>/ipp/print get-printer-attributes.test | grep marker
  ```

  [`tools/canon-ink`](../tools/canon-ink) wraps that into a friendly bar chart.

## Reproducing the build by hand

```bash
sudo apt-get install build-essential debhelper fakeroot autoconf automake \
  libtool libtool-bin pkg-config intltool gettext libcups2-dev libxml2-dev \
  libgtk2.0-dev libglib2.0-dev libusb-1.0-0-dev libsane-dev

tar xzf src/cnijfilter2-source-6.10-1.tar.gz
cd cnijfilter2-source-6.10-1
echo 10 > debian/compat
chmod -x debian/docs
sed -i 's/^Build-Depends:.*/Build-Depends: debhelper (>= 10), libcups2-dev, libxml2-dev, libtool, autoconf, automake, pkg-config/' debian/control
sed -i '/^Standards-Version:/a Rules-Requires-Root: binary-targets' debian/control
CC=../tools/cc CXX=../tools/cxx dpkg-buildpackage -b -us -uc -d
# → ../cnijfilter2_6.10-1_amd64.deb   (repeat analogously for scangearmp2)
```
