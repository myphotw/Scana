cmake_minimum_required(VERSION 3.22.1)
project(scana_qpdf LANGUAGES CXX)

add_library(qpdf SHARED IMPORTED)
set_target_properties(
    qpdf
    PROPERTIES IMPORTED_LOCATION
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/qpdf/prebuilt/${ANDROID_ABI}/libqpdf.so"
)

add_library(scana_qpdf SHARED qpdf_bridge.cpp)
target_compile_features(scana_qpdf PRIVATE cxx_std_20)
target_compile_options(scana_qpdf PRIVATE -fexceptions -frtti -Wall -Wextra -Werror)
target_link_libraries(scana_qpdf PRIVATE qpdf log)
