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
  bool KeepWorkerFragments = false;  // If true, preserve worker fragment files after merge
  unsigned WorkerCount = 1;
  uint64_t SeedPC = 0;
  // Concrete register file captured by the coordinator at the branch point,
  // restored in the worker before decoding the seed so interior seeds have a
  // valid register context (avoids undefined-pointer use-def -> illegalEntry).
  bool HasSeedRegs = false;
  uint64_t SeedRegs[16] = { 0 };
  std::string FragmentDir;
  std::string InputPath;
  std::string ExecutableArgs;
};

#endif // RUNNABLE_LIFT_PARALLELOPTIONS_H
