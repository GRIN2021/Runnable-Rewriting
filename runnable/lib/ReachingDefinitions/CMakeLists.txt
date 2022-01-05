#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

add_library(runnableReachingDefinitions
  STATIC
  ReachingDefinitionsPass.cpp)
target_link_libraries(runnableReachingDefinitions
  runnableFunctionCallIdentification
  runnableStackAnalysis
  runnableSupport)
install(TARGETS runnableReachingDefinitions
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib)
