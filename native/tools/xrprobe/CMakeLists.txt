# xrprobe: the ADR-0002 tiebreak measurement.
#
# Built against BOTH SDKs when both are present -- probing is not choosing, and
# the tiebreak needs a result from each. It links neither into the game.
if(NOT (KF2VR_HAVE_OPENXR OR KF2VR_HAVE_OPENVR))
  message(STATUS "xrprobe: no XR SDK vendored, skipping")
  return()
endif()

add_executable(xrprobe main.cpp)
target_link_libraries(xrprobe PRIVATE kf2vr_core)

if(KF2VR_HAVE_OPENXR)
  # The loader is built from the vendored SDK by the top-level CMakeLists via
  # add_subdirectory, so openxr_loader is a real target here.
  target_compile_definitions(xrprobe PRIVATE KF2VR_WITH_OPENXR=1)
  target_link_libraries(xrprobe PRIVATE openxr_loader d3d11)
  # The loader is a DLL and must sit beside the exe, same as openvr_api.
  add_custom_command(TARGET xrprobe POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:openxr_loader> $<TARGET_FILE_DIR:xrprobe>)
else()
  target_compile_definitions(xrprobe PRIVATE KF2VR_WITH_OPENXR=0)
endif()

if(KF2VR_HAVE_OPENVR)
  target_compile_definitions(xrprobe PRIVATE KF2VR_WITH_OPENVR=1)
  target_link_libraries(xrprobe PRIVATE kf2vr::openvr)
  # openvr_api.dll must sit next to the exe; it is a plain DLL dependency.
  add_custom_command(TARGET xrprobe POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:kf2vr::openvr> $<TARGET_FILE_DIR:xrprobe>)
else()
  target_compile_definitions(xrprobe PRIVATE KF2VR_WITH_OPENVR=0)
endif()
