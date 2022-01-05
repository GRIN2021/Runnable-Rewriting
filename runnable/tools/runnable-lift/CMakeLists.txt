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

install(TARGETS runnable-lift
  RUNTIME DESTINATION bin)
