# Navit 1663 reproduction sources

Use source ed10997cc2bcd6106e93eb1186b350c61cfab015 and the toolchain/package
versions recorded in findings.md. The original container mounted the checkout
at /workspace; retain that layout or adapt the explicit paths below.
Apply changes.patch only for the prototype tests, not the original failure
reproduction. Commands, fixture layout and measured results are in findings.md.
The exact small harness sources are retained below, so they are not dependent
on the original local checkout. No binaries or copied system libraries are
archived; recreate the described fixtures from the installed packages.

## data/espeak-repro/CMakeLists.txt

```
# Minimal reproduction of navit issue #1663.
# Mirrors the call made in navit's top-level CMakeLists.txt (line 290):
#     find_package(espeak QUIET)
# but without QUIET so the warning is visible, and follows the exact
# decision logic used at lines 444-456 of the same file.
cmake_minimum_required(VERSION 3.5)
project(espeak_repro C)

# Same module path situation as navit: CMAKE_MODULE_PATH contains only the
# project's own cmake/ dir, which does NOT ship a Findespeak.cmake
# (verified: ls cmake/ -> no Find*.cmake for espeak).
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}")

message(STATUS "--- 1. navit-style call (module mode falls back to config mode) ---")
find_package(espeak)
message(STATUS "espeak_FOUND=${espeak_FOUND} (navit branch at CMakeLists.txt:445)")
if(NOT espeak_FOUND)
    message(STATUS "=> navit takes the else() branch: vendored support/espeak + INTERNAL_ESPEAK_COMPLETE=TRUE")
endif()

message(STATUS "--- 2. what an explicit module-mode lookup does ---")
find_path(ESPEAK_INCLUDE_DIR espeak/speak_lib.h)
find_library(ESPEAK_LIBRARY espeak)
message(STATUS "find_path    espeak/speak_lib.h -> ${ESPEAK_INCLUDE_DIR}")
message(STATUS "find_library libespeak          -> ${ESPEAK_LIBRARY}")

find_path(ESPEAKNG_INCLUDE_DIR espeak-ng/libespeak-ng.h)
find_library(ESPEAKNG_LIBRARY espeak-ng)
message(STATUS "find_path    espeak-ng/libespeak-ng.h -> ${ESPEAKNG_INCLUDE_DIR}")
message(STATUS "find_library libespeak-ng            -> ${ESPEAKNG_LIBRARY}")

message(STATUS "--- 3. pkg-config detection (the working alternative) ---")
find_package(PkgConfig)
if(PKG_CONFIG_FOUND)
    pkg_check_modules(PC_ESPEAKNG QUIET espeak-ng)
    message(STATUS "pkg-config espeak-ng: PC_ESPEAKNG_FOUND=${PC_ESPEAKNG_FOUND}")
    message(STATUS "  libs=${PC_ESPEAKNG_LIBRARIES} cflags=${PC_ESPEAKNG_CFLAGS_OTHER}")
    pkg_check_modules(PC_ESPEAK QUIET espeak)
    message(STATUS "pkg-config espeak (classic, libespeak-dev): PC_ESPEAK_FOUND=${PC_ESPEAK_FOUND}")
endif()

```

## data/prototype/CMakeLists.txt

```
# Validation harness for the prototype Findespeak.cmake (navit issue #1663).
# Cases:
#   default                - system-installed libespeak (no hints)
#   custom-prefix          - -DCMAKE_PREFIX_PATH=<fixture prefix with both parts>
#   missing-header         - FIXTURE_ROOT contains library only (root-path ONLY isolation)
#   missing-library        - FIXTURE_ROOT contains include only (root-path ONLY isolation)
cmake_minimum_required(VERSION 3.13)
project(espeak_fix_harness C)

# Use the repo's real cmake/ module directory, where the prototype
# Findespeak.cmake has been added (mirrors CMakeLists.txt:60 wiring).
set(CMAKE_MODULE_PATH "${CMAKE_MODULE_PATH}" "/workspace/cmake")

# Pull in navit's real feature macros so set_with_reason() shows its ACTUAL
# cache effects (cmake/navit_macros.cmake), not a reimplementation.
include(/workspace/cmake/navit_macros.cmake)

# --- deterministic dependency isolation for the negative fixtures:
#     applied AFTER project() so compiler detection is already done; root-path
#     ONLY modes re-root all find_path/find_library searches under FIXTURE_ROOT,
#     so the real /usr installation cannot satisfy the missing-dependency cases.
if(FIXTURE_ROOT)
    set(CMAKE_FIND_ROOT_PATH "${FIXTURE_ROOT}")
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
endif()

message(STATUS "=== harness case: ${CASE_LABEL} ===")
find_package(espeak)            # exact call shape of navit CMakeLists.txt:290 (QUIET dropped)

# --- FOUND-variable casing check (observed, not assumed) ---
message(STATUS "espeak_FOUND        = ${espeak_FOUND}")
message(STATUS "ESPEAK_FOUND        = ${ESPEAK_FOUND}")
message(STATUS "espeak_INCLUDE_DIRS = ${espeak_INCLUDE_DIRS}")
message(STATUS "espeak_LIBRARIES    = ${espeak_LIBRARIES}")

# --- navit's decision block replicated from CMakeLists.txt:444-456.
# In navit this block is inside 'if (Qt5Multimedia_FOUND)'; Qt5 is not
# installed in this container, so Qt5Multimedia_FOUND is assumed TRUE here to
# reach the espeak branch. add_feature/add_plugin defaults mirror
# CMakeLists.txt:125-126, because set_with_reason() only forces the cache when
# a non-"User defined" reason already exists (navit_macros.cmake:14-22).
add_plugin(support/espeak "harness replication of navit default" FALSE)
add_feature(INTERNAL_ESPEAK_COMPLETE "harness replication of navit default" FALSE)

if (espeak_FOUND)
    set_with_reason(support/espeak "native espeak found" FALSE)
    set_with_reason(INTERNAL_ESPEAK_COMPLETE "speech_qt5_espeak requires full libespeak" FALSE)
    message(STATUS "DECISION: speech/qt5_espeak builds against NATIVE ${espeak_LIBRARIES}")
else()
    set_with_reason(support/espeak "native espeak missing" TRUE)
    set_with_reason(INTERNAL_ESPEAK_COMPLETE "speech_qt5_espeak requires full libespeak" TRUE)
    message(STATUS "DECISION: VENDORED fallback -> support/espeak on, INTERNAL_ESPEAK_COMPLETE=TRUE")
endif()

if(INTERNAL_ESPEAK_COMPLETE AND NOT espeak_FOUND)
    message(STATUS "DECISION: navit/speech/qt5_espeak/CMakeLists.txt:7-9 would flag INTERNAL_ESPEAK=1 and link support_espeak")
elseif(espeak_FOUND AND NOT INTERNAL_ESPEAK_COMPLETE)
    message(STATUS "DECISION: INTERNAL_ESPEAK=0, native libespeak linked via speech_qt5_espeak_LIBS")
else()
    message(FATAL_ERROR "BUG: inconsistent decision state")
endif()

# --- consumption shape replicated from navit/speech/qt5_espeak/CMakeLists.txt
#     after the patch: include dirs wired BEFORE the module_add_library()
#     equivalent below consumes them (navit_macros.cmake:56-64) ---
set(speech_qt5_espeak_LIBS "")
if(espeak_FOUND)
    set(speech_qt5_espeak_INCLUDES "${espeak_INCLUDE_DIRS}")
    set(speech_qt5_espeak_LIBS "${espeak_LIBRARIES}")
endif()
message(STATUS "speech_qt5_espeak_INCLUDES = ${speech_qt5_espeak_INCLUDES}")
message(STATUS "speech_qt5_espeak_LIBS     = ${speech_qt5_espeak_LIBS}")

# Compile/link targets only exist in the FOUND case.
if(espeak_FOUND)
    add_library(lib_smoke_placeholder STATIC smoke_espeak.c)
    target_include_directories(lib_smoke_placeholder PUBLIC "${speech_qt5_espeak_INCLUDES}")
    target_link_libraries(lib_smoke_placeholder PRIVATE ${speech_qt5_espeak_LIBS})
    add_executable(espeak_smoke smoke_espeak.c)
    target_include_directories(espeak_smoke PRIVATE "${speech_qt5_espeak_INCLUDES}")
    target_link_libraries(espeak_smoke PRIVATE ${speech_qt5_espeak_LIBS})
endif()

```

## data/prototype/smoke_espeak.c

```
/* Compile/link/run smoke test for the prototype Findespeak.cmake.
 *
 * This file deliberately does NOT rely on any system include path: the header
 * <espeak/speak_lib.h> must be reachable through the INCLUDE_DIRECTORIES
 * property wired from espeak_INCLUDE_DIRS (replicating navit's
 * module_add_library() consumption, cmake/navit_macros.cmake:62).
 */
#include <stdio.h>
#include <espeak/speak_lib.h>

/* espeak 1.48's SYNCHRONOUS Synth path crashes if no synth callback is set. */
static long samplesSynthesized;

static int synthCallback(short *wav, int numsamples, espeak_EVENT *events) {
    if (wav) samplesSynthesized += numsamples;
    return 0;
}

int main(int argc, char **argv) {
    const char *datadir = argc > 1 ? argv[1] : NULL;
    int rate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, (char *)datadir, 0);
    if (rate < 0) {
        fprintf(stderr, "espeak_Initialize failed: %d\n", rate);
        return 1;
    }
    printf("espeak initialized, sample rate %d\n", rate);
    espeak_SetSynthCallback(synthCallback);
    int rc = espeak_Synth("hello navit", 11, 0, POS_CHARACTER, 0, espeakCHARS_AUTO, NULL, NULL);
    printf("espeak_Synth rc=%d samples=%ld\n", rc, samplesSynthesized);
    espeak_Synchronize();
    espeak_Terminate();
    return (rc == EE_OK) ? 0 : 1;
}

```
