cmake_minimum_required(VERSION 3.22.1)
project(realtime_media_android LANGUAGES CXX)

add_library(realtime_media_android SHARED native_media_bridge.cpp)
target_compile_features(realtime_media_android PRIVATE cxx_std_17)
target_compile_options(realtime_media_android PRIVATE -Wall -Wextra -Werror)

find_library(log-lib log)
target_link_libraries(realtime_media_android PRIVATE ${log-lib} dl)
