add_executable(kf2vr_tests
  TestMain.cpp
  TestTransform.cpp
  TestBehaviour.cpp
)
target_link_libraries(kf2vr_tests PRIVATE kf2vr_core kf2vr_xr)
target_include_directories(kf2vr_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
add_test(NAME golden COMMAND kf2vr_tests)
