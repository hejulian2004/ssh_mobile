cmake_minimum_required(VERSION 3.15)
project(screen_share_native_probes LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(OWNER "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(FLUTTER_EPHEMERAL_DIR "${REPO}/apps/ssh_mobile_full/windows/flutter/ephemeral"
  CACHE PATH "Ephemeral directory from a Windows Flutter build")
if(NOT EXISTS "${FLUTTER_EPHEMERAL_DIR}/flutter_texture_registrar.h")
  message(FATAL_ERROR "Build the Windows Flutter app before configuring probes")
endif()
add_executable(encoder_probe
  hardware_h264_encoder_probe.cpp
  "${OWNER}/windows/windows_h264_encoder.cpp"
  "${OWNER}/windows/windows_video_processor.cpp")
target_include_directories(encoder_probe PRIVATE "${OWNER}/windows"
  "${FLUTTER_EPHEMERAL_DIR}" "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include")
target_compile_definitions(encoder_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(encoder_probe PRIVATE /EHsc /W4 /utf-8)
target_link_libraries(encoder_probe PRIVATE
  d3d11 dxgi dxguid mfplat mfreadwrite mfuuid ole32 oleaut32 windowsapp)

add_executable(decoder_probe
  hardware_h264_decoder_probe.cpp
  "${OWNER}/windows/windows_capture.cpp"
  "${OWNER}/windows/windows_capture_state.cpp"
  "${OWNER}/windows/windows_h264_decoder.cpp"
  "${OWNER}/windows/windows_h264_encoder.cpp"
  "${OWNER}/windows/windows_video_processor.cpp"
  "${OWNER}/windows/windows_media_channel.cpp")
target_include_directories(decoder_probe PRIVATE "${OWNER}/windows"
  "${FLUTTER_EPHEMERAL_DIR}" "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include")
target_compile_definitions(decoder_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(decoder_probe PRIVATE /EHsc /W4 /utf-8)
target_link_libraries(decoder_probe PRIVATE
  d3d11 dxgi dxguid mfplat mfreadwrite mfuuid ole32 oleaut32 windowsapp)
