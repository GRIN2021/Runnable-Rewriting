#
# This file is distributed under the MIT License. See LICENSE.md for details.
#

runnable_add_analyses_library_internal(runnableDump
  CollectCFG.cpp
  CollectNoreturn.cpp)

target_link_libraries(runnableDump
  runnableSupport)
