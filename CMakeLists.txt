cmake_minimum_required(VERSION 3.15)
project(anonymizer_task CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(RDKAFKA REQUIRED rdkafka++)

find_package(CURL REQUIRED)
find_package(spdlog REQUIRED)
find_package(CapnProto REQUIRED)

include_directories(
  ${RDKAFKA_INCLUDE_DIRS}
  ${CURL_INCLUDE_DIRS}
)

capnp_generate_cpp(CAPNP_SRCS CAPNP_HDRS http_log.capnp)

add_executable(anonymizer
  src/anonymizer.cpp
  src/util.cpp
  ${CAPNP_SRCS}
  ${CAPNP_HDRS}
)

target_link_libraries(anonymizer
  ${RDKAFKA_LIBRARIES}
  CURL::libcurl
  spdlog::spdlog
  CapnProto::capnp
  CapnProto::kj
)

target_include_directories(anonymizer
  PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/generated
)

if (MSVC)
  target_compile_definitions(anonymizer PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

include(CTest)
if (BUILD_TESTING)
  add_executable(test_util
    tests/test_util.cpp
    src/util.cpp
  )
  target_include_directories(test_util PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
  add_test(NAME test_util COMMAND test_util)

  add_executable(test_capnp
    tests/test_capnp.cpp
    ${CAPNP_SRCS}
    ${CAPNP_HDRS}
  )
  target_include_directories(test_capnp PRIVATE ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_BINARY_DIR}/src)
  target_link_libraries(test_capnp CapnProto::capnp CapnProto::kj)
  add_test(NAME test_capnp COMMAND test_capnp)
endif()

