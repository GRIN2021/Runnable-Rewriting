#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

add_library(runnableFunctionCallIdentification
  STATIC
  FunctionCallIdentification.cpp)
target_link_libraries(runnableFunctionCallIdentification
  runnableSupport)
install(TARGETS runnableFunctionCallIdentification
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib)
