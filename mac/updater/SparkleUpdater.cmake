include_guard(GLOBAL)

option(KISAK_SPARKLE_UPDATER
    "Enable the signed Sparkle updater in the native macOS client" OFF)
set(KISAK_SPARKLE_ROOT
    "${CMAKE_SOURCE_DIR}/mac/vendor/Sparkle"
    CACHE PATH "Directory containing the pinned Sparkle.framework distribution")

if(KISAK_SPARKLE_UPDATER AND APPLE AND NOT CMAKE_OBJCXX_COMPILER_LOADED)
    enable_language(OBJCXX)
endif()

function(kisak_enable_sparkle_updater target_name)
    if(NOT KISAK_SPARKLE_UPDATER)
        return()
    endif()
    if(NOT APPLE)
        message(FATAL_ERROR "KISAK_SPARKLE_UPDATER is macOS-only")
    endif()
    if(NOT TARGET "${target_name}")
        message(FATAL_ERROR "Updater target does not exist: ${target_name}")
    endif()
    set(_sparkle_framework "${KISAK_SPARKLE_ROOT}/Sparkle.framework")
    if(NOT EXISTS "${_sparkle_framework}/Sparkle")
        message(FATAL_ERROR
            "Sparkle.framework is missing from ${KISAK_SPARKLE_ROOT}. "
            "Run mac/updater/fetch_sparkle.zsh first.")
    endif()

    target_sources("${target_name}" PRIVATE
        "${CMAKE_SOURCE_DIR}/src/posix/posix_updater.mm")
    target_include_directories("${target_name}" PRIVATE
        "${_sparkle_framework}/Headers")
    target_compile_definitions("${target_name}" PRIVATE
        KISAK_SPARKLE_UPDATER=1)
    target_link_libraries("${target_name}" PRIVATE
        "${_sparkle_framework}"
        "-framework AppKit"
        "-framework Foundation")
    target_link_options("${target_name}" PRIVATE
        "-Wl,-rpath,@executable_path/../Frameworks")
    set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/src/posix/posix_updater.mm"
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
endfunction()
