if(NOT WIN32 OR NOT KF2VR_HAVE_OPENXR)
  return()
endif()
add_executable(xrsmoke main.cpp SmokeScene.cpp)
target_compile_definitions(xrsmoke PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(xrsmoke PRIVATE kf2vr_xr d3d11 d3dcompiler windowscodecs ole32)
add_custom_command(TARGET xrsmoke POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_FILE:openxr_loader> $<TARGET_FILE_DIR:xrsmoke>)
if(BUILD_TESTING)
  add_test(NAME d3d11_stereo_smoke COMMAND xrsmoke --self-test --output "${CMAKE_CURRENT_BINARY_DIR}/self-test")
endif()
