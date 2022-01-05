#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

runnable_add_analyses_library_internal(runnableFunctionIsolation
  IsolateFunctions.cpp)

target_link_libraries(runnableFunctionIsolation
  runnableStackAnalysis
  runnableSupport)
