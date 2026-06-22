#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

set(PREGENERATED_ABIDATAFLOWS ""
  CACHE FILEPATH
  "Optional path to a pre-generated ABIDataFlows.h.")

if(NOT PREGENERATED_ABIDATAFLOWS)
  execute_process(COMMAND python3 -c "import pygraphviz"
    RESULT_VARIABLE HAS_PYGRAPHVIZ
    OUTPUT_VARIABLE PYGRAPHVIZ_OUTPUT
    ERROR_VARIABLE PYGRAPHVIZ_OUTPUT)

  if(NOT HAS_PYGRAPHVIZ EQUAL "0")
    # Don't drop the whitespaces
    message(FATAL_ERROR "  
  Cannot find the pygraphviz module and PREGENERATED_ABIDATAFLOWS is not set.
  ABIDataFlows.h cannot be generated.
  Please try one of the following commands:
  
  Debian/Ubuntu:
    apt-get install python3-pygraphviz
  
  Fedora/Red Hat/CentOS:
    yum install python3-pygraphviz
  
  pip (current user only):
    pip3 install --user pygraphviz
  
  In case of successful installation, the following command should succeed with no output:
    python3 -c 'import pygraphviz'")
  endif()
elseif(NOT EXISTS "${PREGENERATED_ABIDATAFLOWS}")
  message(FATAL_ERROR
    "PREGENERATED_ABIDATAFLOWS does not exist: ${PREGENERATED_ABIDATAFLOWS}")
endif()

# Generate classes for the ABI data flow analyses
set(ABIDATAFLOWS_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/ABIDataFlows-header.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/ABIDataFlows-footer.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/DeadRegisterArgumentsOfFunction.dot"
  "${CMAKE_CURRENT_SOURCE_DIR}/DeadReturnValuesOfFunctionCall.dot"
  "${CMAKE_CURRENT_SOURCE_DIR}/RegisterArgumentsOfFunctionCall.dot"
  "${CMAKE_CURRENT_SOURCE_DIR}/UsedArgumentsOfFunction.dot"
  "${CMAKE_CURRENT_SOURCE_DIR}/UsedReturnValuesOfFunctionCall.dot"
  "${CMAKE_CURRENT_SOURCE_DIR}/UsedReturnValuesOfFunction.dot")
if(PREGENERATED_ABIDATAFLOWS)
  add_custom_command(OUTPUT ABIDataFlows.h
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${PREGENERATED_ABIDATAFLOWS}"
      "${CMAKE_CURRENT_BINARY_DIR}/ABIDataFlows.h"
    DEPENDS "${PREGENERATED_ABIDATAFLOWS}"
    VERBATIM)
else()
  add_custom_command(OUTPUT ABIDataFlows.h
    COMMAND "${CMAKE_SOURCE_DIR}/scripts/monotone-framework.py"
      --call-arcs ${ABIDATAFLOWS_SOURCES} > ABIDataFlows.h
    DEPENDS "${CMAKE_SOURCE_DIR}/scripts/monotone-framework.py"
             ${ABIDATAFLOWS_SOURCES}
    VERBATIM)
endif()
add_custom_target(abidataflows DEPENDS ABIDataFlows.h)

runnable_add_analyses_library_internal(runnableStackAnalysis
  ABIDetectionPass.cpp
  ABIIR.cpp
  Cache.cpp
  Element.cpp
  FunctionABI.cpp
  FunctionBoundariesDetectionPass.cpp
  FunctionsSummary.cpp
  IncoherentCallsAnalysis.cpp
  InterproceduralAnalysis.cpp
  Intraprocedural.cpp
  StackAnalysis.cpp)

target_link_libraries(runnableStackAnalysis
  runnableBasicAnalyses
  runnableSupport)

target_include_directories(runnableStackAnalysis
  PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}")

add_dependencies(runnableStackAnalysis abidataflows)
