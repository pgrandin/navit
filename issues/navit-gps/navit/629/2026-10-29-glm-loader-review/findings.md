# Investigation of upstream Navit issue 629

Investigation performed 2026-10-29; preserved 2026-10-30.
Upstream report: https://github.com/navit-gps/navit/issues/629
Tested source: https://github.com/navit-gps/navit/commit/ed10997cc2bcd6106e93eb1186b350c61cfab015

## Conclusion

No source patch is justified by these measurements. In the tested Linux
configuration, current trunk already supplies an ORIGIN-relative install RUNPATH
and reaches Navit's application code. Deliberately disabling the install RUNPATH
causes a loader error; supplying the library directory through LD_LIBRARY_PATH
restores loading. This reproduces a search-path failure mechanism, not the exact
historical libfib.so failure or a current distribution packaging bug.

The next useful investigation would run the actual affected packager's build and
installation flow, retaining its RPATH handling and inspecting the resulting ELF
files. No upstream ticket closure or claim of a complete fix follows from this
experiment.

## Source findings at the tested commit

- CMakeLists.txt:84–103 selects LIB_DIR, observed here as lib64/navit.
- CMakeLists.txt:104 sets CMAKE_INSTALL_RPATH to
  `$ORIGIN:$ORIGIN/../lib64/navit` in this configuration.
- cmake/navit_macros.cmake:77–85 defines supportlib_add_library: it calls
  add_library without an explicit type and installs support libraries under
  LIB_DIR. The ordinary build produced libsupport_fib.a; BUILD_SHARED_LIBS=ON
  produced libsupport_fib.so.
- navit/support/fib/CMakeLists.txt:1 declares support_fib.
- navit/CMakeLists.txt:101–114 builds shared navit_core in the tested plugin
  configuration and links the support libraries.
- Installed navit has DT_NEEDED libnavit_core.so. In the shared-support build,
  libnavit_core.so has DT_NEEDED libsupport_fib.so and other support libraries.

The issue reports a library named libfib.so; this checkout produces
libsupport_fib.so. Historical renames and the revisions mentioned in issue
comments were not verified in the shallow checkout.

## Environment and commands

The investigation used an isolated Linux container, CMake 3.25.1, GCC 12.2,
make and binutils. Maptool and the sample map were disabled; other features were
selected by configure from the available dependencies. This was a build of those
configured targets, not all optional Navit components. The container had no
network access during the investigation. A usable default graphics subsystem
was unavailable: graphics_null was built, but the runtime configuration requested
gtk_drawing_area, which failed to load.

The following is a standalone reconstruction of the successful comparison
commands, with explicit prefixes and no omitted arguments. Use the tested commit
above in a writable checkout, with the build dependencies already installed.
Do not reuse output directories from a different checkout/configuration.

```sh
mkdir -p data
navit_repro_root="$(pwd)/data"

cmake -S . -B "$navit_repro_root/build-a" \
  -DCMAKE_INSTALL_PREFIX="$navit_repro_root/stage-a/usr" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_MAPTOOL=0 -DSAMPLE_MAP=0 \
  -DBUILD_SHARED_LIBS=ON
cmake --build "$navit_repro_root/build-a" -j4
cmake --install "$navit_repro_root/build-a"

cmake -S . -B "$navit_repro_root/build-b" \
  -DCMAKE_INSTALL_PREFIX="$navit_repro_root/stage-b/usr" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_MAPTOOL=0 -DSAMPLE_MAP=0 \
  -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_INSTALL_RPATH=TRUE
cmake --build "$navit_repro_root/build-b" -j4
cmake --install "$navit_repro_root/build-b"

readelf -d "$navit_repro_root/stage-a/usr/bin/navit"
readelf -d "$navit_repro_root/stage-a/usr/lib64/navit/libnavit_core.so"
readelf -d "$navit_repro_root/stage-b/usr/bin/navit"

# Run separately and retain each status; application failures are expected.
# HOME=/root matches the original unprivileged-container run, including its
# inability to create /root/.navit; that did not cause the ELF loader failure.
(cd "$navit_repro_root/stage-a/usr/bin" &&
 env -i PATH=/usr/bin:/bin HOME=/root LD_LIBRARY_PATH= ./navit)
printf 'normal RUNPATH status=%s\n' "$?"
(cd "$navit_repro_root/stage-b/usr/bin" &&
 env -i PATH=/usr/bin:/bin HOME=/root LD_LIBRARY_PATH= ./navit)
printf 'no RUNPATH status=%s\n' "$?"
(cd "$navit_repro_root/stage-b/usr/bin" &&
 env -i PATH=/usr/bin:/bin HOME=/root \
 LD_LIBRARY_PATH="$navit_repro_root/stage-b/usr/lib64/navit" ./navit)
printf 'library-path control status=%s\n' "$?"
```

Do not run the expected-failure runtime commands under `set -e`, which would
stop before recording all statuses. lib64/navit is the measured path on this
host; inspect LIB_DIR and installation output when reproducing elsewhere.

## Measured results

Both configured builds and installations completed successfully. Build A's
executable and navit_core carried the RUNPATH shown above. Build B's installed
executable and navit_core had no RPATH/RUNPATH entries.

| Case | Process status | Result |
| --- | ---: | --- |
| A: normal install RUNPATH, empty LD_LIBRARY_PATH | 1 | Reached Navit; `FATAL: No graphics subsystem available.` |
| B: install RUNPATH disabled, empty LD_LIBRARY_PATH | 127 | `error while loading shared libraries: libnavit_core.so: cannot open shared object file: No such file or directory` |
| B: its lib64/navit directory supplied in LD_LIBRARY_PATH | 1 | Reached the same Navit graphics failure |

The first missing library measured was libnavit_core.so, not libsupport_fib.so.
Removing the search path can also affect shared navit_core with static support
libraries; shared support libraries were the test configuration, not a proven
prerequisite for every loader failure. Forcing support libraries static would
not eliminate the shared navit_core dependency.

## Limits and review corrections

- Setting CMAKE_SKIP_INSTALL_RPATH=TRUE simulates a missing installed search path; no
  actual Buildroot, Fedora or Gentoo packaging flow was run.
- Reaching application code is not successful interactive navigation. Graphics,
  GPS and maps had additional environment/configuration failures.
- Android and cross builds were neither configured nor built.
- Initial shell pipelines obscured statuses; the final controls captured actual
  program exit statuses. An attempted chroot was unavailable and is not evidence.
- The observed RUNPATH is ORIGIN-relative, so the earlier successful DESTDIR
  staging run was valid loader evidence; a generic concern about absolute /usr
  paths did not apply to that binary.
- Configure generated an untracked cmake_plugin_settings.txt at the checkout
  root. No tracked Navit source files were modified.
- GLM performed source inspection, commands and draft analysis through a plain
  chat-completions tool loop. Operator review removed unsupported historical and
  packaging claims and rejected an unjustified code-change recommendation.

This committed record preserves the reviewed Navit findings and reproduction
instructions. Raw model transcripts, container state and compiled binaries are
not included.
