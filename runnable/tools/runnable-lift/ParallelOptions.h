#ifndef RUNNABLE_LIFT_PARALLELOPTIONS_H
#define RUNNABLE_LIFT_PARALLELOPTIONS_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <cstdint>
#include <string>

struct ParallelOptions {
  bool DynamicParallel = false;
  bool WorkerMode = false;
  unsigned WorkerCount = 1;
  uint64_t SeedPC = 0;
  std::string FragmentDir;
  std::string InputPath;
  std::string ExecutableArgs;
};

#endif // RUNNABLE_LIFT_PARALLELOPTIONS_H
