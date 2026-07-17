#ifndef CODEGENERATOR_H
#define CODEGENERATOR_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <vector>

// LLVM includes
#include "llvm/ADT/ArrayRef.h"

// Local libraries includes
#include "runnable/Support/runnable.h"

// Local includes
#include "BinaryFile.h"
#include "ParallelOptions.h"

// Forward declarations
namespace llvm {

class LLVMContext;
class Function;
class GlobalVariable;
class Module;
class Value;
class StructType;
class DataLayout;

namespace object {
class ObjectFile;
};

}; // namespace llvm

class DebugHelper;

struct ParallelWorkerState {
  int Pid = -1;
  uint64_t SeedPC = 0;
  std::string OutputPath;
  int ExitCode = -1;
  bool Finished = false;
};

/// Translator from binary code to LLVM IR.
class CodeGenerator {
public:
  /// Create a new code generator translating code from an architecture to
  /// another, writing the corresponding LLVM IR and other useful information to
  /// the specified paths.
  ///
  /// \param Binary reference to a BinaryFile object describing the input.
  /// \param Target target architecture.
  /// \param Output path where the generate LLVM IR must be saved.
  /// \param Helpers path of the LLVM IR file containing the QEMU helpers.
  CodeGenerator(BinaryFile &Binary,
                Architecture &Target,
                llvm::LLVMContext &TheContext,
                std::string Output,
                std::string Helpers,
                std::string EarlyLinked,
                const ParallelOptions &Options);

  ~CodeGenerator();

  /// \brief Creates an LLVM function for the code in the specified memory area.
  /// If debug information has been requested, the debug source files will be
  /// create in this phase.
  ///
  /// \param VirtualAddress the address from where the translation should start.
  void translate(uint64_t VirtualAddress);

  uint64_t CodeStartAddress;
  void embeddedData();
  std::map<uint64_t, size_t> EmbeddedData;
  std::map<uint64_t, size_t> &getEmbeddedData(void){
  	std::map<uint64_t, size_t> &EmbeddedData1 = EmbeddedData;
	return EmbeddedData1;
  }

  /// Serialize the generated LLVM IR to the specified output path.
  void serialize();
  std::string getPath(){return OutputPath;}

private:
  /// \brief Parse the ELF headers.
  /// Collect useful information such as the segments' boundaries, their
  /// permissions, the address of program headers and the like.
  /// From this information it produces the .li.csv file containing information
  /// useful for linking.
  /// This function parametric w.r.t. endianess and pointer size.
  ///
  /// \param TheBinary the LLVM ObjectFile representing the ELF file.
  /// \param LinkingInfo path where the .li.csv file should be created.
  template<typename T>
  void parseELF(llvm::object::ObjectFile *TheBinary, bool UseSections);

  /// \brief Import a helper function definition
  ///
  /// Queries the HelpersModule for a function and adds it to TheModule.
  ///
  /// \param Name name of the imported function
  llvm::Function *importHelperFunctionDeclaration(llvm::StringRef Name);

  std::string workerOutputPath(uint64_t SeedPC) const;
  void configureOutputArtifacts(const std::string &Output);
  void switchToWorkerOutput(uint64_t SeedPC);
  int runFreshBranchWorker(uint64_t SeedPC);
  void pollFinishedForkWorkers(bool Block);
  bool trySpawnBranchWorker(uint64_t SeedPC,
                            std::vector<std::tuple<uint64_t, llvm::BasicBlock *, uint64_t>> &BranchTargets);
  void activateBranchFrontierState();
  void waitForForkWorkers();
  void mergeForkWorkerFragments();

private:
  Architecture TargetArchitecture;
  llvm::LLVMContext &Context;
  std::unique_ptr<llvm::Module> TheModule;
  std::unique_ptr<llvm::Module> HelpersModule;
  std::unique_ptr<llvm::Module> EarlyLinkedModule;
  std::string HelpersPath;
  std::string EarlyLinkedPath;
  std::string OutputPath;
  std::unique_ptr<DebugHelper> Debug;
  BinaryFile &Binary;

  unsigned OriginalInstrMDKind;
  unsigned PTCInstrMDKind;
  unsigned DbgMDKind;

  std::string FunctionListPath;
  ParallelOptions ParallelConfig;
  std::vector<ParallelWorkerState> ParallelWorkers;
  std::set<uint64_t> ParallelSpawnedSeeds;
  uint64_t ParallelFrontierCandidates = 0;
  uint64_t PendingWorkerStateDrops = 0;
  // Register file snapshot taken right before forking a branch worker; the
  // forked child reads it (COW-inherited) and hands it to the fresh worker so
  // the seed block decodes with the coordinator's concrete register context.
  bool SeedRegsSnapshotValid = false;
  uint64_t SeedRegsSnapshot[16] = { 0 };
  uint64_t ParallelWorkersSpawned = 0;
  uint64_t ParallelWorkersSucceeded = 0;
  uint64_t ParallelWorkersFailed = 0;
};

#endif // CODEGENERATOR_H
