cmake_minimum_required(VERSION 3.20)
project(dharmaguard_core_engine VERSION 1.0.0 LANGUAGES CXX)

# C++ Standard
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Compiler flags for performance and security
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -march=native -mtune=native")
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0 -fsanitize=address -fsanitize=undefined")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic -Werror")

# Find required packages
find_package(Boost 1.80 REQUIRED COMPONENTS 
    program_options 
    asio 
    system 
    thread
    filesystem
    json
)
find_package(TBB REQUIRED)
find_package(Protobuf REQUIRED)
find_package(gRPC REQUIRED)
find_package(PostgreSQL REQUIRED)
find_package(Redis++ REQUIRED)
find_package(spdlog REQUIRED)
find_package(benchmark REQUIRED)
find_package(GTest REQUIRED)

# Include directories
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
include_directories(${Boost_INCLUDE_DIRS})
include_directories(${Protobuf_INCLUDE_DIRS})

# Generate protobuf and gRPC files
set(PROTO_FILES
    protos/surveillance.proto
    protos/trade.proto
    protos/alert.proto
)

foreach(PROTO_FILE ${PROTO_FILES})
    get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
    set(PROTO_SRCS "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc")
    set(PROTO_HDRS "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h")
    set(GRPC_SRCS "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.grpc.pb.cc")
    set(GRPC_HDRS "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.grpc.pb.h")
    
    add_custom_command(
        OUTPUT "${PROTO_SRCS}" "${PROTO_HDRS}" "${GRPC_SRCS}" "${GRPC_HDRS}"
        COMMAND protobuf::protoc
        ARGS --grpc_out "${CMAKE_CURRENT_BINARY_DIR}"
             --cpp_out "${CMAKE_CURRENT_BINARY_DIR}"
             -I "${CMAKE_CURRENT_SOURCE_DIR}"
             --plugin=protoc-gen-grpc="${gRPC_CPP_PLUGIN_EXECUTABLE}"
             "${PROTO_FILE}"
        DEPENDS "${PROTO_FILE}"
    )
    
    list(APPEND ALL_PROTO_SRCS ${PROTO_SRCS})
    list(APPEND ALL_PROTO_HDRS ${PROTO_HDRS})
    list(APPEND ALL_GRPC_SRCS ${GRPC_SRCS})
    list(APPEND ALL_GRPC_HDRS ${GRPC_HDRS})
endforeach()

# Core surveillance engine library
set(CORE_ENGINE_SOURCES
    src/surveillance/trade_pattern_detector.cpp
    src/surveillance/anomaly_detector.cpp
    src/surveillance/risk_manager.cpp
    src/surveillance/event_processor.cpp
    src/surveillance/audit_logger.cpp
    src/surveillance/blockchain_integration.cpp
    src/surveillance/pump_dump_detector.cpp
    src/surveillance/layering_detector.cpp
    src/surveillance/wash_trading_detector.cpp
    src/surveillance/insider_trading_detector.cpp
    src/surveillance/front_running_detector.cpp
    src/database/postgres_connection.cpp
    src/database/redis_connection.cpp
    src/messaging/kafka_producer.cpp
    src/messaging/kafka_consumer.cpp
    src/utils/logger.cpp
    src/utils/config_manager.cpp
    src/utils/metrics_collector.cpp
    src/grpc/surveillance_service.cpp
    ${ALL_PROTO_SRCS}
    ${ALL_GRPC_SRCS}
)

add_library(dharmaguard_core SHARED ${CORE_ENGINE_SOURCES})

target_link_libraries(dharmaguard_core
    PUBLIC
        ${Boost_LIBRARIES}
        TBB::tbb
        protobuf::libprotobuf
        gRPC::grpc++
        gRPC::grpc++_reflection
        PostgreSQL::PostgreSQL
        redis++::redis++
        spdlog::spdlog
)

target_compile_definitions(dharmaguard_core PRIVATE
    BOOST_ASIO_ENABLE_HANDLER_TRACKING
    SPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_INFO
)

# Main executable
add_executable(dharmaguard_engine 
    src/main.cpp
)

target_link_libraries(dharmaguard_engine 
    PRIVATE dharmaguard_core
)

# Performance benchmarks
add_executable(performance_benchmarks
    benchmarks/trade_processing_benchmark.cpp
    benchmarks/pattern_detection_benchmark.cpp
    benchmarks/memory_benchmark.cpp
)

target_link_libraries(performance_benchmarks 
    PRIVATE 
        dharmaguard_core 
        benchmark::benchmark
        benchmark::benchmark_main
)

# Unit tests
enable_testing()

set(TEST_SOURCES
    tests/unit/test_trade_pattern_detector.cpp
    tests/unit/test_anomaly_detector.cpp
    tests/unit/test_risk_manager.cpp
    tests/unit/test_event_processor.cpp
    tests/unit/test_database_connections.cpp
)

add_executable(unit_tests ${TEST_SOURCES})

target_link_libraries(unit_tests
    PRIVATE
        dharmaguard_core
        GTest::gtest
        GTest::gtest_main
        GTest::gmock
)

add_test(NAME UnitTests COMMAND unit_tests)

# Integration tests
add_executable(integration_tests
    tests/integration/test_full_pipeline.cpp
    tests/integration/test_grpc_service.cpp
)

target_link_libraries(integration_tests
    PRIVATE
        dharmaguard_core
        GTest::gtest
        GTest::gtest_main
)

add_test(NAME IntegrationTests COMMAND integration_tests)

# Install targets
install(TARGETS dharmaguard_engine dharmaguard_core
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(DIRECTORY include/ DESTINATION include)

# CPack configuration for packaging
set(CPACK_PACKAGE_NAME "dharmaguard-core-engine")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_DESCRIPTION "DharmaGuard High-Performance Surveillance Engine")
set(CPACK_GENERATOR "DEB;RPM;TGZ")
include(CPack)
