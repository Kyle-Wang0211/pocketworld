cmake_minimum_required(VERSION 3.24)

project(pw_official_cpu_mvs LANGUAGES C CXX)

# This closure is deliberately standalone. It never downloads dependencies and
# it does not include COLMAP's top-level build (which would pull sparse feature,
# GUI, CUDA, and meshing targets into the graph).
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_FIND_PACKAGE_PREFER_CONFIG ON)

option(PW_OFFICIAL_CPU_MVS_BUILD_SMOKE "Build the native closure smoke test" ON)
set(PW_COLMAP_SOURCE_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../third_party/colmap-4.1.1"
    CACHE PATH "Frozen COLMAP 4.1.1 source tree")

if(NOT EXISTS "${PW_COLMAP_SOURCE_DIR}/COPYING.txt")
  message(FATAL_ERROR "PW_COLMAP_SOURCE_DIR is not the frozen vendored COLMAP tree")
endif()

find_package(Python3 COMPONENTS Interpreter REQUIRED)
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
          "${CMAKE_CURRENT_LIST_DIR}/verify_source_manifest.py"
          --source-root "${PW_COLMAP_SOURCE_DIR}"
          --manifest "${CMAKE_CURRENT_LIST_DIR}/SOURCE_SHA256SUMS.txt"
  RESULT_VARIABLE _pw_source_verify_result
  OUTPUT_VARIABLE _pw_source_verify_output
  ERROR_VARIABLE _pw_source_verify_error)
if(NOT _pw_source_verify_result EQUAL 0)
  message(FATAL_ERROR
    "Frozen official CPU MVS source verification failed:\n"
    "${_pw_source_verify_output}${_pw_source_verify_error}")
endif()

# Config packages may be supplied by a checked-in mobile dependency prefix or
# an already-installed host prefix. Network-aware package acquisition and
# package-manager bootstrap code are intentionally absent.
find_package(Eigen3 3.4 CONFIG REQUIRED)
find_package(Boost 1.80 REQUIRED)
find_package(glog 0.7.1 EXACT CONFIG REQUIRED)
find_package(OpenImageIO CONFIG REQUIRED)

set(PW_OFFICIAL_CPU_MVS_UPSTREAM_SOURCES
  # Dense workspace, model, maps, fusion and PLY I/O.
  src/colmap/mvs/consistency_graph.cc
  src/colmap/mvs/depth_map.cc
  src/colmap/mvs/fusion.cc
  src/colmap/mvs/image.cc
  src/colmap/mvs/mat.cc
  src/colmap/mvs/model.cc
  src/colmap/mvs/normal_map.cc
  src/colmap/mvs/workspace.cc
  src/colmap/image/warp.cc
  src/colmap/sensor/bitmap.cc
  src/colmap/sensor/database.cc
  src/colmap/sensor/models.cc
  src/colmap/sensor/specs.cc
  src/colmap/util/base_controller.cc
  src/colmap/util/endian.cc
  src/colmap/util/file.cc
  src/colmap/util/logging.cc
  src/colmap/util/misc.cc
  src/colmap/util/oiio_utils.cc
  src/colmap/util/ply.cc
  src/colmap/util/string.cc
  src/colmap/util/threading.cc
  src/colmap/util/timer.cc
  # COLMAP sparse-model serialization required by mvs::Model::ReadFromCOLMAP.
  # These are data-model/I/O objects, not feature extraction or matching.
  src/colmap/geometry/essential_matrix.cc
  src/colmap/geometry/normalization.cc
  src/colmap/geometry/pose.cc
  src/colmap/geometry/rigid3.cc
  src/colmap/geometry/sim3.cc
  src/colmap/geometry/triangulation.cc
  src/colmap/scene/camera.cc
  src/colmap/scene/frame.cc
  src/colmap/scene/image.cc
  src/colmap/scene/point2d.cc
  src/colmap/scene/point3d.cc
  src/colmap/scene/projection.cc
  src/colmap/scene/reconstruction.cc
  src/colmap/scene/reconstruction_io.cc
  src/colmap/scene/reconstruction_io_binary.cc
  src/colmap/scene/reconstruction_io_text.cc
  src/colmap/scene/reconstruction_io_utils.cc
  src/colmap/scene/rig.cc
  src/colmap/scene/track.cc
  src/colmap/sensor/rig.cc
  # Official VLFeat image convolution used by colmap/image/warp.cc. No SIFT,
  # descriptor, detector, or sparse-feature object is included.
  src/thirdparty/VLFeat/generic.c
  src/thirdparty/VLFeat/host.c
  src/thirdparty/VLFeat/imopv.c
  src/thirdparty/VLFeat/random.c
)

file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/SOURCE_OBJECTS.txt"
     _pw_manifest_sources REGEX "^[^#].+")
if(NOT "${PW_OFFICIAL_CPU_MVS_UPSTREAM_SOURCES}" STREQUAL
       "${_pw_manifest_sources}")
  message(FATAL_ERROR
    "SOURCE_OBJECTS.txt and PW_OFFICIAL_CPU_MVS_UPSTREAM_SOURCES drifted")
endif()

set(_pw_forbidden_source_pattern
    "(cuda|sift|lsd|feature|matcher|meshing|mesh_simplification|texture_mapping|ui|opengl|qt)")
foreach(_pw_source IN LISTS PW_OFFICIAL_CPU_MVS_UPSTREAM_SOURCES)
  string(TOLOWER "${_pw_source}" _pw_source_lower)
  if(_pw_source_lower MATCHES "${_pw_forbidden_source_pattern}")
    message(FATAL_ERROR "Forbidden source in official CPU MVS closure: ${_pw_source}")
  endif()
  if(NOT EXISTS "${PW_COLMAP_SOURCE_DIR}/${_pw_source}")
    message(FATAL_ERROR "Frozen upstream source is missing: ${_pw_source}")
  endif()
  list(APPEND _pw_absolute_upstream_sources "${PW_COLMAP_SOURCE_DIR}/${_pw_source}")
endforeach()

add_library(pw_official_cpu_mvs_objects OBJECT
  ${_pw_absolute_upstream_sources}
)
target_include_directories(pw_official_cpu_mvs_objects
  PUBLIC "${PW_COLMAP_SOURCE_DIR}/src"
)
target_compile_definitions(pw_official_cpu_mvs_objects
  PUBLIC
    GLOG_USE_GLOG_EXPORT
    GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0
    GLOG_VERSION_MINOR=7
    VL_DISABLE_AVX
    VL_DISABLE_SSE2
    VL_DISABLE_OPENMP
)
target_link_libraries(pw_official_cpu_mvs_objects
  PUBLIC
    Eigen3::Eigen
    Boost::headers
    glog::glog
    OpenImageIO::OpenImageIO
)

add_library(pw_official_cpu_mvs STATIC
  $<TARGET_OBJECTS:pw_official_cpu_mvs_objects>
  src/official_cpu_mvs_bridge.cc
)
target_include_directories(pw_official_cpu_mvs
  PUBLIC
    "${CMAKE_CURRENT_LIST_DIR}/include"
    "${PW_COLMAP_SOURCE_DIR}/src"
)
target_compile_definitions(pw_official_cpu_mvs
  PUBLIC
    GLOG_USE_GLOG_EXPORT
    GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0
    GLOG_VERSION_MINOR=7
)
target_link_libraries(pw_official_cpu_mvs
  PUBLIC
    Eigen3::Eigen
    Boost::headers
    glog::glog
    OpenImageIO::OpenImageIO
)

if(PW_OFFICIAL_CPU_MVS_BUILD_SMOKE)
  enable_testing()
  add_executable(pw_official_cpu_mvs_smoke test/official_cpu_mvs_smoke.cc)
  # Whole-archive is intentional: the smoke link must resolve every object in
  # the closure, not merely the small bridge member selected by normal archive
  # extraction. CMake maps this feature to -force_load on Apple and the NDK
  # linker's --whole-archive form on Android.
  target_link_libraries(pw_official_cpu_mvs_smoke
    PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,pw_official_cpu_mvs>"
  )
  add_test(NAME pw_official_cpu_mvs_smoke COMMAND pw_official_cpu_mvs_smoke)
endif()
