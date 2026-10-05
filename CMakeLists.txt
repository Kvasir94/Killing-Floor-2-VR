cmake_minimum_required(VERSION 3.24)
project(KF2VR LANGUAGES CXX)

# x64 only. KFGame.exe is x86-64 (verified: PE machine 0x8664, build 8767), so
# anything that will eventually share its address space must match.
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "KF2-VR is x64 only; KFGame.exe is x86-64.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
  add_compile_options(/W4 /permissive- /Zc:__cplusplus /utf-8)
  # Deterministic float behaviour: pose maths that changes under optimisation
  # would make the golden tests meaningless as a regression net.
  add_compile_options(/fp:precise)
endif()

# Vendored XR SDKs (not committed; see third_party/VERSIONS.md).
include(third_party/xr-sdks.cmake)
if(KF2VR_HAVE_OPENXR)
  # Loader only. Tests, API layers and the conformance suite are the SDK's own
  # concern and just slow our configure down.
  set(DYNAMIC_LOADER ON  CACHE BOOL "" FORCE)
  set(BUILD_TESTS    OFF CACHE BOOL "" FORCE)
  set(BUILD_API_LAYERS OFF CACHE BOOL "" FORCE)
  add_subdirectory(third_party/openxr-sdk EXCLUDE_FROM_ALL)
endif()

include(CTest)
add_subdirectory(native/vrcore)
add_subdirectory(native/xr)
add_subdirectory(native/adapter)
add_subdirectory(native/tools/xrprobe)

add_subdirectory(native/tools/xrsmoke)
add_subdirectory(native/tools/handassets)
if(BUILD_TESTING)
  add_subdirectory(native/tests)
endif()
