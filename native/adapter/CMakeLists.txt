# The proxy DLL needs MinHook and the OpenXR loader. Its tests need neither:
# they are CPU maths and D3D11 WARP. Gating both behind one early return meant a
# missing optional dependency silently dropped seventeen suites, and CTest then
# reported "100% tests passed" over what was left. Keep the two gates separate.
set(KF2VR_ADAPTER_DLL ON)
add_subdirectory(../tools/vrmonitor "${CMAKE_BINARY_DIR}/native/tools/vrmonitor")
add_subdirectory(../tools/framesampler "${CMAKE_BINARY_DIR}/native/tools/framesampler")
if(NOT WIN32 OR NOT KF2VR_HAVE_OPENXR OR NOT EXISTS "${PROJECT_SOURCE_DIR}/third_party/minhook/include/MinHook.h")
  set(KF2VR_ADAPTER_DLL OFF)
  message(STATUS "kf2vr_adapter: MinHook/OpenXR not vendored; skipping the proxy DLL. Tests still build.")
endif()

if(KF2VR_ADAPTER_DLL)
  # The root's C/C++ switches are not ml64 options. Keep their existing
  # semantics for compiled sources while excluding the assembly shim.
  get_directory_property(adapter_compile_options COMPILE_OPTIONS)
  set_property(DIRECTORY PROPERTY COMPILE_OPTIONS "$<$<COMPILE_LANGUAGE:C,CXX>:${adapter_compile_options}>")
  enable_language(C)
  enable_language(ASM_MASM)
  add_library(kf2vr_minhook STATIC
    ../../third_party/minhook/src/buffer.c
    ../../third_party/minhook/src/hook.c
    ../../third_party/minhook/src/trampoline.c
    ../../third_party/minhook/src/hde/hde64.c)
  target_include_directories(kf2vr_minhook PUBLIC ../../third_party/minhook/include)
  add_library(kf2vr_server_adapter SHARED ServerAdapter.cpp Proxy.cpp WeaponIsolation.cpp PerkContext.cpp dinput8.def)
  target_compile_definitions(kf2vr_server_adapter PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX KF2VR_SERVER_ADAPTER)
  target_link_libraries(kf2vr_server_adapter PRIVATE kf2vr_minhook bcrypt)
  set_target_properties(kf2vr_server_adapter PROPERTIES OUTPUT_NAME dinput8 PREFIX ""
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/server"
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/server")
  add_library(kf2vr_adapter SHARED Adapter.cpp Proxy.cpp AtlasBlit.cpp StereoViews.cpp SpatialMenu.cpp SpatialHud.cpp XrGamepad.cpp HeadAim.cpp RingsideBell.cpp assets/RingsideBell.rc WeaponIsolation.cpp WeaponContext.cpp WeaponHandling.cpp WeaponRuntimeDispatch.cpp PerkContext.cpp dinput8.def)
  target_include_directories(kf2vr_adapter PRIVATE include)
  target_sources(kf2vr_adapter PRIVATE FocusTiming.cpp FocusTiming.asm)
  if(BUILD_TESTING)
    add_executable(kf2vr_focus_timing_test tests/FocusTimingTest.cpp FocusTiming.cpp FocusTiming.asm)
    target_include_directories(kf2vr_focus_timing_test PRIVATE .)
    target_compile_definitions(kf2vr_focus_timing_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    target_link_libraries(kf2vr_focus_timing_test PRIVATE kf2vr_minhook)
    add_test(NAME native_focus_timing COMMAND kf2vr_focus_timing_test)
  endif()
  target_sources(kf2vr_adapter PRIVATE ../portal/PortalCapture.cpp ../portal/PortalHitscan.cpp)
  target_compile_definitions(kf2vr_adapter PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_adapter PRIVATE kf2vr_minhook kf2vr_xr d3d11 d3dcompiler dxgi bcrypt advapi32 windowscodecs ole32 winmm)
  set_target_properties(kf2vr_adapter PROPERTIES OUTPUT_NAME dinput8 PREFIX "")
  if(MSVC)
    # Session capture contains a bounded worker and RAII locks. Allocation/I/O
    # exceptions must unwind those locks before recording fails closed.
    target_compile_options(kf2vr_adapter PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/EHsc>)
    # Keep Release optimization; retain local PDBs for diagnostic stack labels.
    target_compile_options(kf2vr_adapter PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/Zi>)
    target_link_options(kf2vr_adapter PRIVATE /DEBUG:FULL /OPT:REF /OPT:ICF)
  endif()
  add_custom_command(TARGET kf2vr_adapter POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:openxr_loader> $<TARGET_FILE_DIR:kf2vr_adapter>)
endif()

# Windows and D3D11 are what these actually require; the Win32 headers are
# reached through the adapter sources even where no D3D11 device is created.
if(BUILD_TESTING AND NOT WIN32)
  message(STATUS "kf2vr_adapter: adapter and portal suites require Windows; skipping 16 tests.")
endif()
if(BUILD_TESTING AND WIN32)
  add_executable(kf2vr_promo_log_test tests/PromoEventLogTest.cpp)
  target_include_directories(kf2vr_promo_log_test PRIVATE . ../vrcore/include)
  target_compile_definitions(kf2vr_promo_log_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_promo_event_log COMMAND kf2vr_promo_log_test "${CMAKE_CURRENT_BINARY_DIR}/promo-log-test.jsonl")
  add_executable(kf2vr_replay_input_test tests/ReplayInputTest.cpp)
  target_include_directories(kf2vr_replay_input_test PRIVATE . ../xr/include ../vrcore/include)
  add_test(NAME native_replay_input COMMAND kf2vr_replay_input_test)
  add_executable(kf2vr_magazine_feed_test tests/MagazineFeedStateTest.cpp)
  target_include_directories(kf2vr_magazine_feed_test PRIVATE .)
  add_test(NAME native_magazine_feed COMMAND kf2vr_magazine_feed_test)
  add_executable(kf2vr_present_handoff_test tests/PresentHandoffTest.cpp)
  target_include_directories(kf2vr_present_handoff_test PRIVATE .)
  add_test(NAME native_present_handoff COMMAND kf2vr_present_handoff_test)
  add_executable(kf2vr_script_write_batch_test tests/ScriptWriteBatchTest.cpp)
  target_include_directories(kf2vr_script_write_batch_test PRIVATE .)
  target_compile_definitions(kf2vr_script_write_batch_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_script_write_batch COMMAND kf2vr_script_write_batch_test)
  add_executable(kf2vr_script_field_cache_test tests/ScriptFieldCacheTest.cpp)
  target_include_directories(kf2vr_script_field_cache_test PRIVATE .)
  target_compile_definitions(kf2vr_script_field_cache_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_script_field_cache COMMAND kf2vr_script_field_cache_test)
  add_executable(kf2vr_frame_drilldown_test tests/FrameDrilldownTest.cpp)
  target_include_directories(kf2vr_frame_drilldown_test PRIVATE .)
  target_compile_definitions(kf2vr_frame_drilldown_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_frame_drilldown COMMAND kf2vr_frame_drilldown_test)
  # Run explicitly and retain its JSON; no timing threshold in correctness tests.
  add_executable(kf2vr_vm_identity_benchmark tests/VmIdentityBenchmark.cpp)
  add_executable(kf2vr_vm_entry_test tests/VmEntryTest.cpp)
  target_include_directories(kf2vr_vm_entry_test PRIVATE .)
  target_compile_definitions(kf2vr_vm_entry_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_vm_entry COMMAND kf2vr_vm_entry_test)
  target_include_directories(kf2vr_vm_identity_benchmark PRIVATE .)
  target_compile_definitions(kf2vr_vm_identity_benchmark PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_executable(kf2vr_render_performance_test tests/RenderPerformanceTest.cpp)
  target_include_directories(kf2vr_render_performance_test PRIVATE .)
  target_compile_definitions(kf2vr_render_performance_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_render_performance_test PRIVATE d3d11)
  add_test(NAME native_render_performance COMMAND kf2vr_render_performance_test)

  # WARP only: renders actual pixels and checks state restoration, never opens XR.
  add_executable(kf2vr_atlas_test tests/AtlasBlitTest.cpp AtlasBlit.cpp)
  target_include_directories(kf2vr_atlas_test PRIVATE . ../xr/include)
  target_compile_definitions(kf2vr_atlas_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_atlas_test PRIVATE kf2vr_core d3d11 d3dcompiler dxgi)
  add_test(NAME native_atlas_blit COMMAND kf2vr_atlas_test)

  add_executable(kf2vr_hud_test tests/SpatialHudTest.cpp SpatialHud.cpp)
  target_include_directories(kf2vr_hud_test PRIVATE . ../xr/include)
  target_link_libraries(kf2vr_hud_test PRIVATE kf2vr_core)
  add_test(NAME native_spatial_hud COMMAND kf2vr_hud_test)

  add_executable(kf2vr_reload_pop_test tests/ReloadMeshPopTest.cpp)
  target_include_directories(kf2vr_reload_pop_test PRIVATE . ../xr/include)
  target_compile_definitions(kf2vr_reload_pop_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_reload_pop_test PRIVATE kf2vr_core)
  add_test(NAME native_reload_mesh_pop COMMAND kf2vr_reload_pop_test)

  add_executable(kf2vr_weapon_haptics_test tests/WeaponHapticsTest.cpp)
  target_include_directories(kf2vr_weapon_haptics_test PRIVATE .)
  target_compile_definitions(kf2vr_weapon_haptics_test PRIVATE NOMINMAX)
  add_test(NAME native_weapon_haptics COMMAND kf2vr_weapon_haptics_test)

  add_executable(kf2vr_hand_wrist_test tests/HandWristTest.cpp)
  target_include_directories(kf2vr_hand_wrist_test PRIVATE .)
  target_compile_definitions(kf2vr_hand_wrist_test PRIVATE NOMINMAX)
  target_link_libraries(kf2vr_hand_wrist_test PRIVATE kf2vr_core)
  add_test(NAME native_hand_wrist COMMAND kf2vr_hand_wrist_test)

  add_executable(kf2vr_menu_test tests/SpatialMenuTest.cpp SpatialMenu.cpp)
  target_include_directories(kf2vr_menu_test PRIVATE . ../xr/include)
  target_link_libraries(kf2vr_menu_test PRIVATE kf2vr_core)
  add_test(NAME native_spatial_menu COMMAND kf2vr_menu_test)

  add_executable(kf2vr_gamepad_test tests/XrGamepadTest.cpp XrGamepad.cpp)
  target_include_directories(kf2vr_gamepad_test PRIVATE . ../xr/include)
  target_compile_definitions(kf2vr_gamepad_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_gamepad_test PRIVATE kf2vr_core)
  add_test(NAME native_xr_gamepad COMMAND kf2vr_gamepad_test)

  add_executable(kf2vr_independent_locomotion_test tests/IndependentLocomotionTest.cpp)
  target_include_directories(kf2vr_independent_locomotion_test PRIVATE .)
  add_test(NAME native_independent_locomotion COMMAND kf2vr_independent_locomotion_test)

  # Pure camera mathematics and invalid-input guards; never calls game functions.
  add_executable(kf2vr_stereo_test tests/StereoViewsTest.cpp StereoViews.cpp)
  target_include_directories(kf2vr_stereo_test PRIVATE . include ../xr/include)
  target_compile_definitions(kf2vr_stereo_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_stereo_test PRIVATE kf2vr_core)
  add_test(NAME native_stereo_views COMMAND kf2vr_stereo_test)

  add_executable(kf2vr_world_gate_test tests/LocalWorldGateTest.cpp)
  target_include_directories(kf2vr_world_gate_test PRIVATE include)
  target_compile_definitions(kf2vr_world_gate_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_world_gate COMMAND kf2vr_world_gate_test)

  add_executable(kf2vr_head_aim_test tests/HeadAimTest.cpp HeadAim.cpp StereoViews.cpp)
  target_include_directories(kf2vr_head_aim_test PRIVATE . include ../xr/include)
  target_compile_definitions(kf2vr_head_aim_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_head_aim_test PRIVATE kf2vr_core)
  add_test(NAME native_head_aim COMMAND kf2vr_head_aim_test)

  add_executable(kf2vr_script_field_test tests/ScriptFieldTest.cpp)
  target_include_directories(kf2vr_script_field_test PRIVATE .)
  target_compile_definitions(kf2vr_script_field_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  add_test(NAME native_script_fields COMMAND kf2vr_script_field_test)

  add_executable(kf2vr_vm_callback_filter_test tests/VmCallbackFilterTest.cpp)
  target_include_directories(kf2vr_vm_callback_filter_test PRIVATE .)
  add_test(NAME native_vm_callback_filter COMMAND kf2vr_vm_callback_filter_test)

  add_executable(kf2vr_weapon_aim_test tests/WeaponAimStackTest.cpp)
  target_include_directories(kf2vr_weapon_aim_test PRIVATE . include)
  add_test(NAME native_weapon_aim COMMAND kf2vr_weapon_aim_test)

  add_executable(kf2vr_rpg_backblast_test tests/RPGBackBlastTest.cpp)
  target_include_directories(kf2vr_rpg_backblast_test PRIVATE . include)
  target_compile_definitions(kf2vr_rpg_backblast_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_rpg_backblast_test PRIVATE kf2vr_core)
  add_test(NAME native_rpg_backblast COMMAND kf2vr_rpg_backblast_test)

  add_executable(kf2vr_foreground_depth_test tests/ForegroundDepthTest.cpp)
  target_include_directories(kf2vr_foreground_depth_test PRIVATE .)
  target_compile_definitions(kf2vr_foreground_depth_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_foreground_depth_test PRIVATE d3d11 d3dcompiler)
  add_test(NAME native_foreground_depth COMMAND kf2vr_foreground_depth_test)

  add_executable(kf2vr_hud_alpha_test tests/HudTextAlphaTest.cpp)
  target_include_directories(kf2vr_hud_alpha_test PRIVATE .)
  target_compile_definitions(kf2vr_hud_alpha_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_hud_alpha_test PRIVATE d3d11 d3dcompiler)
  add_test(NAME native_hud_text_alpha COMMAND kf2vr_hud_alpha_test)

  add_executable(kf2vr_portal_capture_test ../portal/tests/PortalCapturePolicyTest.cpp)
  target_include_directories(kf2vr_portal_capture_test PRIVATE ../portal)
  target_compile_features(kf2vr_portal_capture_test PRIVATE cxx_std_20)
  add_test(NAME native_portal_capture COMMAND kf2vr_portal_capture_test)

endif()

if(BUILD_TESTING)
  add_executable(kf2vr_promo_event_test tests/PromoEventStateTest.cpp)
  target_include_directories(kf2vr_promo_event_test PRIVATE .)
  add_test(NAME native_promo_event_state COMMAND kf2vr_promo_event_test)
  add_executable(kf2vr_motion_clip_test tests/MotionClipTest.cpp)
  target_include_directories(kf2vr_motion_clip_test PRIVATE . ../xr/include ../vrcore/include)
  add_test(NAME native_motion_clip COMMAND kf2vr_motion_clip_test)
  if(WIN32)
    add_executable(kf2vr_motion_session_test tests/MotionSessionTest.cpp)
    target_include_directories(kf2vr_motion_session_test PRIVATE . ../xr/include ../vrcore/include)
    target_compile_definitions(kf2vr_motion_session_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    if(MSVC)
      target_compile_options(kf2vr_motion_session_test PRIVATE /EHsc)
    endif()
    add_test(NAME native_motion_session COMMAND kf2vr_motion_session_test)
  endif()
endif()

# CPU-only experimental policy. Does not enter a shipping binary or launcher.
option(KF2VR_BREACHER_EXPERIMENT "Build isolated Breacher state experiment" OFF)
if(BUILD_TESTING AND KF2VR_BREACHER_EXPERIMENT)
  add_executable(kf2vr_breacher_cascade_test tests/BreacherCascadeTest.cpp)
  target_compile_features(kf2vr_breacher_cascade_test PRIVATE cxx_std_20)
  add_test(NAME native_breacher_cascade COMMAND kf2vr_breacher_cascade_test)
endif()

if(BUILD_TESTING)
  add_executable(kf2vr_game_build_test tests/GameBuildTest.cpp)
  target_include_directories(kf2vr_game_build_test PRIVATE include)
  add_test(NAME native_game_build COMMAND kf2vr_game_build_test)
endif()

if(BUILD_TESTING AND WIN32)
  add_executable(kf2vr_epic_session_test tests/EpicSessionTest.cpp)
  target_include_directories(kf2vr_epic_session_test PRIVATE .)
  target_compile_definitions(kf2vr_epic_session_test PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_epic_session_test PRIVATE advapi32)
  add_test(NAME native_epic_session COMMAND kf2vr_epic_session_test)
  # Offline pipe client only. Invoked by the Python broker tests, never a game.
  add_executable(kf2vr_epic_session_client tests/EpicSessionClient.cpp)
  target_include_directories(kf2vr_epic_session_client PRIVATE .)
  target_compile_definitions(kf2vr_epic_session_client PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(kf2vr_epic_session_client PRIVATE advapi32)
endif()
