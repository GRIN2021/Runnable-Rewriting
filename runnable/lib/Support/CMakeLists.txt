#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

add_library(runnableSupport SHARED
  Assert.cpp
  CommandLine.cpp
  Debug.cpp
  DebugHelper.cpp
  ExampleAnalysis.cpp
  IRHelpers.cpp
  Statistics.cpp)

target_include_directories(runnableSupport
  INTERFACE $<INSTALL_INTERFACE:include/>)

install(TARGETS runnableSupport
  EXPORT runnable
  LIBRARY DESTINATION lib)
