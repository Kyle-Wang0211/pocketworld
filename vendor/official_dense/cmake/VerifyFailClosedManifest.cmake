if(NOT DEFINED MANIFEST_PATH OR NOT EXISTS "${MANIFEST_PATH}")
  message(FATAL_ERROR "official dense shader manifest was not generated")
endif()

file(READ "${MANIFEST_PATH}" _pw_dense_manifest)
string(JSON _pw_dense_overall_ready ERROR_VARIABLE _pw_dense_json_error
       GET "${_pw_dense_manifest}" overall_ready)
if(_pw_dense_json_error)
  message(FATAL_ERROR
          "cannot read overall_ready from official dense shader manifest")
endif()
if(_pw_dense_overall_ready)
  message(FATAL_ERROR
          "unverified shader manifest must not report overall_ready=true")
endif()

