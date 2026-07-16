#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

add_executable(runnable-lift
  BinaryFile.cpp
  CPUStateAccessAnalysisPass.cpp
  CodeGenerator.cpp
  ExternalJumpsHandler.cpp
  InstructionTranslator.cpp
  JumpTargetManager.cpp
  Main.cpp
  NoReturnAnalysis.cpp
  OSRA.cpp
  PTCDump.cpp
  SET.cpp
  SimplifyComparisonsPass.cpp
  VariableManager.cpp)

target_link_libraries(runnable-lift
  dl
  m
  runnableBasicAnalyses
  runnableReachingDefinitions
  runnableSupport
  ${LLVM_LIBRARIES})

add_custom_command(TARGET runnable-lift POST_BUILD VERBATIM
  COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:runnable-lift>" "${CMAKE_BINARY_DIR}/")

set(RUNNABLE_LIFT_RUNTIME_ARTIFACTS
  libtinycode-x86_64.so
  libtinycode-helpers-x86_64.ll
  early-linked-x86_64.ll)

foreach(RUNNABLE_LIFT_RUNTIME_ARTIFACT ${RUNNABLE_LIFT_RUNTIME_ARTIFACTS})
  set(RUNNABLE_LIFT_RUNTIME_ARTIFACT_PATH
      "${CMAKE_CURRENT_SOURCE_DIR}/${RUNNABLE_LIFT_RUNTIME_ARTIFACT}")
  if(EXISTS "${RUNNABLE_LIFT_RUNTIME_ARTIFACT_PATH}")
    add_custom_command(TARGET runnable-lift POST_BUILD VERBATIM
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              "${RUNNABLE_LIFT_RUNTIME_ARTIFACT_PATH}"
              "$<TARGET_FILE_DIR:runnable-lift>/${RUNNABLE_LIFT_RUNTIME_ARTIFACT}")
  endif()
endforeach()

install(TARGETS runnable-lift
  RUNTIME DESTINATION bin)
