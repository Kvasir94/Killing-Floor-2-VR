# Locate the vendored XR SDKs and expose them as imported targets.
#
# Fetching both SDKs is NOT choosing a backend. ADR-0002 defers that choice to
# an M1 experiment that has to run a standalone sample against EACH candidate,
# so both have to be present and buildable for the tiebreak to happen at all.
# What the ADR forbids is shipping two backends into the game, and nothing here
# links either one into the adapter.
#
# Neither SDK is committed; third_party/*/ is gitignored. Versions are pinned in
# third_party/VERSIONS.md.

set(KF2VR_THIRD_PARTY "${CMAKE_CURRENT_LIST_DIR}")

# ---- OpenXR ---------------------------------------------------------------
# The pre-generated KhronosGroup/OpenXR-SDK, not OpenXR-SDK-Source: the latter
# generates its headers at configure time and needs Python jinja2, which is a
# build dependency we have no reason to take on. -Source is kept alongside only
# as reference material for hello_xr's D3D11 plugin.
set(KF2VR_OPENXR_ROOT "${KF2VR_THIRD_PARTY}/openxr-sdk")
if(EXISTS "${KF2VR_OPENXR_ROOT}/include/openxr/openxr.h")
  set(KF2VR_HAVE_OPENXR ON)
else()
  set(KF2VR_HAVE_OPENXR OFF)
  message(STATUS "OpenXR SDK not found at ${KF2VR_OPENXR_ROOT}")
endif()

# ---- OpenVR ---------------------------------------------------------------
# Ships a prebuilt win64 import library and DLL; nothing to compile.
set(KF2VR_OPENVR_ROOT "${KF2VR_THIRD_PARTY}/openvr")
if(EXISTS "${KF2VR_OPENVR_ROOT}/headers/openvr.h"
   AND EXISTS "${KF2VR_OPENVR_ROOT}/lib/win64/openvr_api.lib")
  set(KF2VR_HAVE_OPENVR ON)
  add_library(kf2vr::openvr SHARED IMPORTED GLOBAL)
  set_target_properties(kf2vr::openvr PROPERTIES
    IMPORTED_IMPLIB        "${KF2VR_OPENVR_ROOT}/lib/win64/openvr_api.lib"
    IMPORTED_LOCATION      "${KF2VR_OPENVR_ROOT}/bin/win64/openvr_api.dll"
    INTERFACE_INCLUDE_DIRECTORIES "${KF2VR_OPENVR_ROOT}/headers")
else()
  set(KF2VR_HAVE_OPENVR OFF)
  message(STATUS "OpenVR SDK not found at ${KF2VR_OPENVR_ROOT}")
endif()
