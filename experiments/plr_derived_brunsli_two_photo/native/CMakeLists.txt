cmake_minimum_required(VERSION 3.20)

project(pw_brunsli_side_adapter LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT DEFINED BRUNSLI_SOURCE_DIR)
  message(FATAL_ERROR "BRUNSLI_SOURCE_DIR must point to a pinned checkout")
endif()

get_filename_component(BRUNSLI_SOURCE_DIR "${BRUNSLI_SOURCE_DIR}" REALPATH)
add_subdirectory("${BRUNSLI_SOURCE_DIR}" brunsli EXCLUDE_FROM_ALL)

find_library(SECURITY_FRAMEWORK Security REQUIRED)

add_executable(pw_brunsli_side_adapter brunsli_side_adapter.cc)
add_executable(pw_brunsli_training_extract brunsli_training_extract.cc)
target_include_directories(pw_brunsli_side_adapter PRIVATE
  "${BRUNSLI_SOURCE_DIR}"
  "${BRUNSLI_SOURCE_DIR}/c/include"
)
target_include_directories(pw_brunsli_training_extract PRIVATE
  "${BRUNSLI_SOURCE_DIR}"
  "${BRUNSLI_SOURCE_DIR}/c/include"
)
target_compile_options(pw_brunsli_side_adapter PRIVATE
  -Wall
  -Wextra
  -Werror
  -Wno-error=sign-compare
)
target_compile_options(pw_brunsli_training_extract PRIVATE
  -Wall
  -Wextra
  -Werror
  -Wno-error=sign-compare
)
target_link_libraries(pw_brunsli_side_adapter PRIVATE
  brunslienc-static
  brunslidec-static
  brunslicommon-static
  "${SECURITY_FRAMEWORK}"
)
target_link_libraries(pw_brunsli_training_extract PRIVATE
  brunslienc-static
  brunslicommon-static
  "${SECURITY_FRAMEWORK}"
)
