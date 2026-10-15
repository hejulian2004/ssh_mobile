cmake_minimum_required(VERSION 3.14)
project(window_fullscreen_test LANGUAGES CXX)
add_executable(window_fullscreen_test
  window_fullscreen_test.cpp
  ../../windows/runner/window_fullscreen.cpp)
target_compile_features(window_fullscreen_test PRIVATE cxx_std_17)
target_compile_definitions(window_fullscreen_test PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(window_fullscreen_test PRIVATE /W4 /WX /EHsc)
target_link_libraries(window_fullscreen_test PRIVATE user32)
