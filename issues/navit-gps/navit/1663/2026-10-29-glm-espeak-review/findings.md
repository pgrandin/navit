# Archival note, 2026-10-30

The following is the reviewed report from the 2026-10-29 experiment. Its
no-commit/no-push statements describe that original run; this bundle now
preserves the findings and prototype in Git. The patch is evidence, not a
merged or production-validated fix. Full Navit Qt5 configuration remains
unverified. Original /workspace paths describe the isolated container.

# Navit issue #1663 — findings (prototype pass)

Investigation of https://github.com/navit-gps/navit/issues/1663 on a trunk clone
(`/workspace`, HEAD `ed10997`). Scope: classic libespeak only. **No commit, no
push, nothing posted**; all tracked-tree work is an uncommitted working-tree
change, all test artifacts are under `/workspace/data/`.

## 1. Root cause (file/line evidence)

- `CMakeLists.txt:60` sets `CMAKE_MODULE_PATH` to the repo's own `cmake/`
  directory; that directory contains no `Findespeak.cmake` (only
  `FindPROTOBUF_C.cmake`, `FindXGettextGlade.cmake`, plus non-Find modules).
- `CMakeLists.txt:290` calls `find_package(espeak QUIET)` (inside the Qt5
  block; evaluated only when `Qt5Widgets_FOUND OR Qt5Quick_FOUND`, lines
  286–291). With module mode unavailable, CMake falls back to config mode and
  looks for `espeakConfig.cmake` / `espeak-config.cmake`. In the checked clone
  (trunk at `ed10997`) no such config file and no `Findespeak.cmake` exist, and
  in the Debian packages installed in this environment none of the relevant
  packages ship either (we did not survey every Debian package nor externally
  supplied CMake modules): `libespeak-dev` ships neither a CMake config nor an
  `espeak.pc` (`libespeak-ng-dev` ships only a *pkg-config* file, `espeak-ng.pc`).
- Therefore, in this clone and environment, `espeak_FOUND` is never satisfied
  (we did not survey every package or externally supplied CMake module that
  could set it); the only consumer,
  `CMakeLists.txt:444–456`, always takes its `else()` branch:
  `support/espeak` (vendored lib) forced on, `INTERNAL_ESPEAK_COMPLETE` on, and
  `navit/speech/qt5_espeak` links `support_espeak` with `-DINTERNAL_ESPEAK=1`
  (`navit/speech/qt5_espeak/CMakeLists.txt:7–9`). Native libespeak is silently
  ignored even when installed (the issue reporter's exact symptom).
- `navit/speech/espeak` (`CMakeLists.txt:581`, default FALSE, Windows-only at
  line 746 and no Linux enabler) is independent of this bug.
- **Error from a previous pass, corrected:** this clone is shallow (a single
  commit, `ed10997`), so it **cannot establish** whether navit's history ever
  contained a Find module or any other espeak detection machinery; that
  historical question is simply unanswerable here.

## 2. Failure reproduction (exact commands/output from pass 1)

`/workspace/data/espeak-repro/` holds a minimal CMake project calling
`find_package(espeak)` (QUIET dropped) and replicating navit's decision logic.

Command:
```
cmake -S /workspace/data/espeak-repro -B /workspace/data/espeak-repro/build
```
Relevant output (CMake 3.25.1):
```
CMake Warning at CMakeLists.txt:15 (find_package):
  By not providing "Findespeak.cmake" in CMAKE_MODULE_PATH this project has
  asked CMake to find a package configuration file provided by "espeak", but
  CMake did not find one.
  Could not find a package configuration file provided by "espeak" with any
  of the following names:
    espeakConfig.cmake
    espeak-config.cmake
-- espeak_FOUND=0 (navit branch at CMakeLists.txt:445)
-- => navit takes the else() branch: vendored support/espeak + INTERNAL_ESPEAK_COMPLETE=TRUE
-- find_path    espeak/speak_lib.h -> /usr/include
-- find_library libespeak          -> /usr/lib/x86_64-linux-gnu/libespeak.so
-- pkg-config espeak-ng: PC_ESPEAKNG_FOUND=1
-- pkg-config espeak (classic, libespeak-dev): PC_ESPEAK_FOUND=0
```
System state: CMake 3.25.1, GCC 12.2, pkg-config 1.8.1, libespeak-dev
1.48.15 (headers `/usr/include/espeak/speak_lib.h`, lib
`/usr/lib/x86_64-linux-gnu/libespeak.so`, **no `espeak.pc`**), libespeak-ng-dev
1.51 (`espeak-ng.pc` present, headers under `/usr/include/espeak-ng/`).

## 3. Prototype fix (reviewed, simplified)

Files in `/workspace/data/issue-1663.patch` (verified to apply cleanly with
`git apply --check`):

1. **New `cmake/Findespeak.cmake`** — standard find_path/find_library +
   `FindPackageHandleStandardArgs`, exporting the lower-cased result variables
   navit already consumes (`espeak_FOUND`, `espeak_LIBRARIES`,
   `espeak_INCLUDE_DIRS`). Per review: no custom `espeak_DIR` API and no
   include-derived-from-library guessing. Custom installs go through
   `CMAKE_PREFIX_PATH` (prefix layout `<prefix>/include/espeak/speak_lib.h` +
   `<prefix>/lib*/libespeak.*`) or by pre-setting the standard cache variables
   `ESPEAK_INCLUDE_DIR` / `ESPEAK_LIBRARY`.
2. **One changed file:** `navit/speech/qt5_espeak/CMakeLists.txt` — wire
   include directories **before** `module_add_library()` consumes them:
   ```cmake
   # espeak include dirs must be set before module_add_library() consumes ${speech_qt5_espeak_INCLUDES} (navit_macros.cmake:62)
   if(espeak_FOUND)
   	set(speech_qt5_espeak_INCLUDES "${espeak_INCLUDE_DIRS}")
   endif()
   ```
   The link side needs no change: `set_with_reason()` at `CMakeLists.txt:447–449`
   already appends `${espeak_LIBRARIES}` to `speech_qt5_espeak_LIBS`, which
   `module_add_library()` (`cmake/navit_macros.cmake:60`) links.

### FOUND-variable casing (checked, not assumed)

`find_package_handle_standard_args(espeak ...)` (package name as passed:
lowercase `espeak`) was **observed** in this environment to set both
`espeak_FOUND` and `ESPEAK_FOUND`, so navit's existing consumer at
`CMakeLists.txt:445` (lowercase) is the one satisfied. Harness always prints
both (`data/prototype/logs/*.log`). CMake version: 3.25.1.

## 4. Validation matrix (all under `/workspace/data/prototype/`)

Harness: `data/prototype/CMakeLists.txt` includes the **real** navit
`cmake/navit_macros.cmake`, calls the real `Findespeak.cmake`, replicates
navit's decision block verbatim (with `add_plugin`/`add_feature` defaults of
`CMakeLists.txt:125–126` so `set_with_reason` forces the cache as in-tree), and
replicates the `module_add_library` consumption (include/link mechanics of
`navit_macros.cmake:56–64`). Smoke program: `data/prototype/smoke_espeak.c`
(`espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, ...)`, `espeak_Synth`,
`espeak_Synchronize()`; note: espeak 1.48 requires a synth callback in
SYNCHRONOUS mode or it segfaults — the smoke test sets one).

### Case 1 — system-installed libespeak (compile+link+run) — PASS
```
cmake -S . -B build-installed            # no hints
cmake --build build-installed
./build-installed/espeak_smoke /usr/lib/x86_64-linux-gnu
```
```
-- Found espeak: /usr/lib/x86_64-linux-gnu/libespeak.so
-- espeak_FOUND = TRUE   ESPEAK_FOUND = TRUE
-- espeak_INCLUDE_DIRS = /usr/include
-- espeak_LIBRARIES    = /usr/lib/x86_64-linux-gnu/libespeak.so
-- DECISION: speech/qt5_espeak builds against NATIVE ...
[100%] Built target espeak_smoke
espeak initialized, sample rate 22050
espeak_Synth rc=0 samples=15993    RUN_RC=0
```

### Case 2 — custom prefix via CMAKE_PREFIX_PATH (compile+link+run) — PASS
Fixture: `fakeprefix/{include/espeak/speak_lib.h,lib/libespeak.so}` (copies of
the real files).
```
cmake -S . -B build-custom-prefix -DCMAKE_PREFIX_PATH=/workspace/data/prototype/fakeprefix
cmake --build build-custom-prefix
./build-custom-prefix/espeak_smoke /usr/lib/x86_64-linux-gnu
```
```
-- Found espeak: /workspace/data/prototype/fakeprefix/lib/libespeak.so
-- espeak_INCLUDE_DIRS = /workspace/data/prototype/fakeprefix/include
-- espeak_LIBRARIES    = /workspace/data/prototype/fakeprefix/lib/libespeak.so
-- DECISION: speech/qt5_espeak builds against NATIVE .../fakeprefix/lib/libespeak.so
espeak initialized, sample rate 22050 / espeak_Synth rc=0  RUN_RC=0
```
Runtime note: the linker records `libespeak.so.1`'s soname, which the dynamic
loader resolves to the system install (`ldd` shows
`/lib/x86_64-linux-gnu/libespeak.so.1`); compile/link used the fixture's
absolute path via `find_library`. For a genuinely self-contained prefix the
usual rpath/install machinery of navit applies (unverified here).

### Case 3 — missing header, deterministic (fixture root isolation) — PASS
Fixture: `prefix-libonly` has the library but **no** include tree. Search
isolation via standard root-path machinery, applied **after** the harness's
`project()` so compiler detection is unaffected:
```
cmake -S . -B build-missing-header \
  -DCASE_LABEL=missing-header \
  -DFIXTURE_ROOT=/workspace/data/prototype/prefix-libonly
# inside harness CMakeLists.txt, after project():
#   CMAKE_FIND_ROOT_PATH = ${FIXTURE_ROOT}
#   CMAKE_FIND_ROOT_PATH_MODE_INCLUDE = ONLY
#   CMAKE_FIND_ROOT_PATH_MODE_LIBRARY = ONLY
```
```
-- Could NOT find espeak (missing: ESPEAK_INCLUDE_DIR)
-- espeak_FOUND = FALSE  ESPEAK_FOUND = FALSE
-- DECISION: VENDORED fallback -> support/espeak on, INTERNAL_ESPEAK_COMPLETE=TRUE
-- DECISION: navit/speech/qt5_espeak/CMakeLists.txt:7-9 would flag INTERNAL_ESPEAK=1 and link support_espeak
```
The library was found only from the fixture root and no system fallback
occurred — `espeak_FOUND=FALSE` is deterministic. Cache evidence
(`build-missing-header/CMakeCache.txt`):
```
ESPEAK_INCLUDE_DIR:PATH=ESPEAK_INCLUDE_DIR-NOTFOUND
ESPEAK_LIBRARY:FILEPATH=/workspace/data/prototype/prefix-libonly/lib/libespeak.so
```

### Case 4 — missing library, deterministic — PASS
Fixture: `prefix-includeonly` has the include tree but no library; same root
isolation (`FIXTURE_ROOT=/workspace/data/prototype/prefix-includeonly`):
```
-- Could NOT find espeak (missing: ESPEAK_LIBRARY)
-- espeak_FOUND = FALSE  ESPEAK_FOUND = FALSE
-- DECISION: VENDORED fallback -> support/espeak on, INTERNAL_ESPEAK_COMPLETE=TRUE
```
`/usr/lib/x86_64-linux-gnu/libespeak.so` exists on this host, yet was not
found — proves the root-path ONLY isolation actually excluded /usr. Cache
evidence (`build-missing-library/CMakeCache.txt`):
```
ESPEAK_INCLUDE_DIR:PATH=/workspace/data/prototype/prefix-includeonly/include
ESPEAK_LIBRARY:FILEPATH=ESPEAK_LIBRARY-NOTFOUND
```

### Vendored fallback availability after not-found
Two independent pieces of evidence:
1. Decision logic: `espeak_FOUND=FALSE` leaves the `else()` branch of
   `CMakeLists.txt:444–456` fully active (harness Cases 3–4 above show
   `support/espeak` on and `INTERNAL_ESPEAK_COMPLETE=TRUE` via navit's real
   `set_with_reason` cache mechanics).
2. The vendored sources are still syntactically valid: all 27
   `navit/support/espeak/*.c` files pass `gcc -fsyntax-only
   -I/workspace -I/workspace/navit` (0 failures). This is a **syntax-only
   validation** — it is not a proof that a full vendored build links or works;
   no link/compile of the complete vendored library was performed here
   (`data/prototype/logs/vendored-fallback-check.log`).

### Dropped / unverified items (explicit)
- **Full navit Qt5 configuration was NOT exercised.** Qt5 development packages
  are not installed in this container, and navit's `find_package(espeak)` is
  reached only when `Qt5Widgets|Quick` is found; additionally navit's own
  configure currently aborts *earlier* at `find_package(PROTOBUF_C REQUIRED)`
  (`CMakeLists.txt:766`, unrelated: protobuf-c dev files absent). The espeak
  find/consume path and decision block were therefore validated with a
  verbatim replication (incl. navit's real macros), not the real tree build.
- Per review, custom installs that do **not** follow the
  `CMAKE_PREFIX_PATH` prefix convention (e.g. library-only custom path without
  pre-set `ESPEAK_INCLUDE_DIR`) are no longer auto-derived; users must set the
  standard cache variables (standard CMake practice). Not separately tested.
- Install-stage (`install(FILES ...)`, rpath on install) of the native link is
  not covered by the prototype tests.

## 5. Proposed next step (not done in this pass)
Apply `/workspace/data/issue-1663.patch` to a Qt5-equipped environment and
re-run navit's full `cmake` configure to confirm the upstream feature summary
switches to the native path (`support/espeak` off, `speech/qt5_espeak` with
`-DINTERNAL_ESPEAK=0`).

## 6. Artifact index
- Patch (new file + one tracked edit): `data/issue-1663.patch`
- Patch application check: `data/parcheck/` (applies cleanly, `PATCH_CHECK_OK`)
- Original failure repro: `data/espeak-repro/{CMakeLists.txt,build/}`
- Validation harness: `data/prototype/{CMakeLists.txt,smoke_espeak.c}`
- Fixtures: `data/prototype/{fakeprefix,prefix-libonly,prefix-includeonly}`
- Case logs: `data/prototype/logs/*.log`, builds in
  `data/prototype/build-{installed,custom-prefix,missing-header,missing-library}`
- Transient gcc stderr captures relocated from `/tmp` to
  `data/prototype/logs/tmp-scratch/` (scratch only; remaining artifacts stay
  under `/workspace/data/`).
- Callback-quirk probes kept as method evidence: `data/prototype/{initonly.c,synthcb.c}`.
