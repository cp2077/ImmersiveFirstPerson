cmake_minimum_required(VERSION 3.21)

project(ImmersiveFirstPersonNative LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(RED4EXT_SDK_PATH "" CACHE PATH "Path to the RED4ext.SDK source tree")
if(NOT RED4EXT_SDK_PATH OR NOT EXISTS "${RED4EXT_SDK_PATH}/CMakeLists.txt")
    message(FATAL_ERROR "Set RED4EXT_SDK_PATH to a RED4ext.SDK checkout.")
endif()

set(RED4EXT_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(RED4EXT_INSTALL OFF CACHE BOOL "" FORCE)
set(RED4EXT_USE_PCH OFF CACHE BOOL "" FORCE)
add_subdirectory("${RED4EXT_SDK_PATH}" "${CMAKE_BINARY_DIR}/red4ext-sdk" EXCLUDE_FROM_ALL)

add_library(ImmersiveFirstPerson SHARED src/Main.cpp)
target_link_libraries(ImmersiveFirstPerson PRIVATE RED4ext::SDK)
target_compile_definitions(ImmersiveFirstPerson PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)

if(MSVC)
    target_compile_options(ImmersiveFirstPerson PRIVATE /W4 /permissive-)
endif()

set_target_properties(ImmersiveFirstPerson PROPERTIES
    PREFIX ""
    OUTPUT_NAME "ImmersiveFirstPerson"
)
