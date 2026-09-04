cmake_minimum_required(VERSION 3.16)

project(KisakCOD)

# === Target detection ============================================================
# KISAK_TARGET: windows | posix | switch
# - windows: upstream MSVC + DirectX 9 build (default on Windows hosts)
# - posix:   in-progress port to macOS/Linux desktop (Phase 1)
# - switch:  cross-compile to Nintendo Switch via devkitA64 (Phase 2)
# See docs/SWITCH_PORT.md for current phase.
if(NOT DEFINED KISAK_TARGET)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        set(KISAK_TARGET "windows")
    elseif(NINTENDO_SWITCH OR DEFINED ENV{DEVKITPRO})
        set(KISAK_TARGET "switch")
    else()
        set(KISAK_TARGET "posix")
    endif()
endif()
set(KISAK_TARGET "${KISAK_TARGET}" CACHE STRING "Build target (windows|posix|switch)")
set_property(CACHE KISAK_TARGET PROPERTY STRINGS "windows" "posix" "switch")

if(NOT KISAK_TARGET MATCHES "^(windows|posix|switch)$")
    message(FATAL_ERROR "Invalid KISAK_TARGET='${KISAK_TARGET}'. Use windows|posix|switch.")
endif()

message(STATUS "[KisakCOD] target=${KISAK_TARGET} system=${CMAKE_SYSTEM_NAME} compiler=${CMAKE_CXX_COMPILER_ID} arch=${CMAKE_SYSTEM_PROCESSOR}")

# Set the default C++ standard
set(CMAKE_CXX_STANDARD 20)

# Set Address Sanitizer
# NOTE: If you use this you will need to copy to the game's directory
# clang_rt.asan_dbg_dynamic-i386.dll and clang_rt.asan_dynamic-i386.dll from the MSVC C directory located below (or similar)
# C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.44.35207\bin\Hostx86\x86
set(USE_ASAN OFF)

# Set the gloabl directory variables
set(SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src)
set(DEPS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/deps)
set(BIN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/bin)
set(SCRIPTS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/scripts)

# Set the output directories
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${BIN_DIR})

# MSVC-only globals (upstream Windows build). Other toolchains set their flags downstream.
if(MSVC)
    set_property(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} PROPERTY VS_STARTUP_PROJECT ${BIN_NAME})
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /MT /O2 /Ot /MP /W3 /Zi ${MSVC_WARNING_DISABLES} /permissive-")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /MTd /Od /MP /W3 /Zi ${MSVC_WARNING_DISABLES} /permissive-")
endif()

# Include global scripts/tricks
include(${SCRIPTS_DIR}/extern/increment_build.cmake)

# Build subprojects by target. POSIX/Switch are WIP (Phase 1 skeleton).
if(KISAK_TARGET STREQUAL "windows")
    add_subdirectory(${SCRIPTS_DIR}/mp)
    add_subdirectory(${SCRIPTS_DIR}/sp)
    add_subdirectory(${SCRIPTS_DIR}/dedi)
elseif(KISAK_TARGET STREQUAL "posix")
    add_subdirectory(${SCRIPTS_DIR}/posix)
elseif(KISAK_TARGET STREQUAL "switch")
    add_subdirectory(${SCRIPTS_DIR}/switch)
endif()
