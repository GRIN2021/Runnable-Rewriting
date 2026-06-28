/// \file main.cpp
/// \brief This file takes care of handling command-line parameters and loading
/// the appropriate flavour of libtinycode-*.so

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

extern "C" {
#include <dlfcn.h>
#include <libgen.h>
#include <unistd.h>
}

// LLVM includes
#include "llvm/ADT/ArrayRef.h"
#include "llvm/InitializePasses.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Object/Binary.h"
#include "llvm/Object/ELF.h"
#include "llvm/PassRegistry.h"
#include "llvm/Support/raw_ostream.h"

// Local libraries includes
#include "runnable/Support/CommandLine.h"
#include "runnable/Support/Debug.h"
#include "runnable/Support/Statistics.h"
#include "runnable/Support/runnable.h"

// Local includes
#include "BinaryFile.h"
#include "CodeGenerator.h"
#include "ParallelOptions.h"
#include "PTCInterface.h"

PTCInterface ptc = {}; ///< The interface with the PTC library.
RunnablePTCAbiMetadataInfo RunnablePTCAbiMetadata = {};

using namespace llvm::cl;

using std::string;

// TODO: drop short aliases

namespace {

static void initializeLegacyPasses() {
  llvm::PassRegistry &Registry = *llvm::PassRegistry::getPassRegistry();
  llvm::initializeCore(Registry);
  llvm::initializeAnalysis(Registry);
  llvm::initializeTransformUtils(Registry);
  llvm::initializeScalarOpts(Registry);
}

#define DESCRIPTION desc("virtual address of the entry point where to start")
opt<unsigned long long> EntryPointAddress("entry",
                                          DESCRIPTION,
                                          value_desc("address"),
                                          cat(MainCategory));
#undef DESCRIPTION
alias A1("e",
         desc("Alias for -entry"),
         aliasopt(EntryPointAddress),
         cat(MainCategory));

#define DESCRIPTION desc("base address where dynamic objects should be loaded")
opt<unsigned long long> BaseAddress("base",
                                    DESCRIPTION,
                                    value_desc("address"),
                                    cat(MainCategory),
                                    init(0x50000000));
#undef DESCRIPTION

#define DESCRIPTION desc("Alias for -base")
alias A2("B", DESCRIPTION, aliasopt(BaseAddress), cat(MainCategory));
#undef DESCRIPTION

opt<string> InputPath(Positional, Required, desc("<input path>"));
opt<string> OutputPath(Positional, Required, desc("<output path>"));

opt<string> ExecutableArgs("exe-args", value_desc("arguments"), cat(MainCategory));

opt<bool> DynamicParallel("dynamic-parallel",
                          desc("enable dynamic branch-driven parallel lift"),
                          cat(MainCategory),
                          init(false));
opt<unsigned> ParallelWorkers("parallel-workers",
                              desc("maximum number of worker subprocesses"),
                              cat(MainCategory),
                              init(1));
opt<bool> ParallelWorkerMode("parallel-worker-mode",
                             desc("internal worker subprocess mode"),
                             cat(MainCategory),
                             init(false));
opt<unsigned long long> ParallelSeedPC("parallel-seed-pc",
                                       desc("worker seed PC"),
                                       cat(MainCategory),
                                       init(0));
opt<string> ParallelFragmentDir("parallel-fragment-dir",
                                desc("fragment output directory"),
                                cat(MainCategory));
opt<bool> KeepWorkerFragments("keep-worker-fragments",
                              desc("preserve worker fragment files after merge (for debugging)"),
                              cat(MainCategory),
                              init(false));

} // namespace

static std::string LibTinycodePath;
static std::string LibHelpersPath;
static std::string EarlyLinkedPath;

// When LibraryPointer is destroyed, the destructor calls
// LibraryDestructor::operator()(LibraryPointer::get()).
// The problem is that LibraryDestructor::operator() does not take arguments,
// while the destructor tries to pass a void * argument, so it does not match.
// However, LibraryDestructor is an alias for
// std::intgral_constant<decltype(&dlclose), &dlclose >, which has an implicit
// conversion operator to value_type, which unwraps the &dlclose from the
// std::integral_constant, making it callable.
using LibraryDestructor = std::integral_constant<int (*)(void *) noexcept,
                                                 &dlclose>;
using LibraryPointer = std::unique_ptr<void, LibraryDestructor>;
using PTCGetAbiMetadataPtr = const char *(*)();

static std::string trimMetadataField(std::string Field) {
  while (!Field.empty()
         && (Field.back() == '\r' || Field.back() == ' '
             || Field.back() == '\t'))
    Field.pop_back();

  size_t Start = 0;
  while (Start < Field.size()
         && (Field[Start] == ' ' || Field[Start] == '\t'
             || Field[Start] == '\r'))
    Start++;

  return Field.substr(Start);
}

static std::string lowerAscii(std::string Value) {
  for (char &Character : Value) {
    if (Character >= 'A' && Character <= 'Z')
      Character = static_cast<char>(Character - 'A' + 'a');
  }
  return Value;
}

static bool parseMetadataBool(const std::string &Value, bool &Result) {
  const std::string Lower = lowerAscii(Value);
  if (Lower == "true" || Lower == "1" || Lower == "yes") {
    Result = true;
    return true;
  }
  if (Lower == "false" || Lower == "0" || Lower == "no") {
    Result = false;
    return true;
  }
  return false;
}

static void parsePTCAbiMetadata(const char *Metadata) {
  RunnablePTCAbiMetadata = RunnablePTCAbiMetadataInfo();
  if (Metadata == nullptr)
    return;

  RunnablePTCAbiMetadata.Present = true;
  RunnablePTCAbiMetadata.Raw = Metadata;

  std::istringstream Lines(RunnablePTCAbiMetadata.Raw);
  std::string Line;
  while (std::getline(Lines, Line)) {
    const size_t Separator = Line.find('=');
    if (Separator == std::string::npos)
      continue;

    const std::string Key = trimMetadataField(Line.substr(0, Separator));
    const std::string Value = trimMetadataField(Line.substr(Separator + 1));
    if (Key == "abi_version") {
      char *End = nullptr;
      const unsigned long Parsed = std::strtoul(Value.c_str(), &End, 10);
      if (End != Value.c_str() && *End == '\0') {
        RunnablePTCAbiMetadata.HasAbiVersion = true;
        RunnablePTCAbiMetadata.AbiVersion = static_cast<unsigned>(Parsed);
      }
    } else if (Key == "stub_kind") {
      RunnablePTCAbiMetadata.HasStubKind = true;
      RunnablePTCAbiMetadata.StubKind = Value;
    } else if (Key == "real_translation") {
      bool Parsed = true;
      if (parseMetadataBool(Value, Parsed)) {
        RunnablePTCAbiMetadata.HasRealTranslation = true;
        RunnablePTCAbiMetadata.RealTranslation = Parsed;
      }
    } else if (Key == "vector_schema") {
      bool Parsed = true;
      if (parseMetadataBool(Value, Parsed)) {
        RunnablePTCAbiMetadata.HasVectorSchema = true;
        RunnablePTCAbiMetadata.VectorSchema = Parsed;
      }
    }
  }
}

static const char *findPTCAbiMetadata(void *LibraryHandle) {
  dlerror();
  const char *Metadata =
    reinterpret_cast<const char *>(dlsym(LibraryHandle, "ptc_abi_metadata"));
  const char *MetadataError = dlerror();
  if (MetadataError == nullptr && Metadata != nullptr)
    return Metadata;

  dlerror();
  PTCGetAbiMetadataPtr GetMetadata =
    reinterpret_cast<PTCGetAbiMetadataPtr>(
      dlsym(LibraryHandle, "ptc_get_abi_metadata"));
  const char *GetterError = dlerror();
  if (GetterError == nullptr && GetMetadata != nullptr)
    return GetMetadata();

  return nullptr;
}

static void printPTCAbiMetadata() {
  if (!RunnablePTCAbiMetadata.Present)
    return;

  llvm::errs() << "runnable-lift: PTC ABI metadata detected";
  llvm::errs() << " abi_version=";
  if (RunnablePTCAbiMetadata.HasAbiVersion)
    llvm::errs() << RunnablePTCAbiMetadata.AbiVersion;
  else
    llvm::errs() << "<unknown>";

  llvm::errs() << " stub_kind=";
  if (RunnablePTCAbiMetadata.HasStubKind)
    llvm::errs() << RunnablePTCAbiMetadata.StubKind;
  else
    llvm::errs() << "<unknown>";

  llvm::errs() << " real_translation=";
  if (RunnablePTCAbiMetadata.HasRealTranslation)
    llvm::errs() << (RunnablePTCAbiMetadata.RealTranslation ? "true" : "false");
  else
    llvm::errs() << "<unknown>";

  llvm::errs() << " vector_schema=";
  if (RunnablePTCAbiMetadata.HasVectorSchema)
    llvm::errs() << (RunnablePTCAbiMetadata.VectorSchema ? "true" : "false");
  else
    llvm::errs() << "<unknown>";
  llvm::errs() << "\n";

  if (RunnablePTCAbiMetadata.HasRealTranslation
      && !RunnablePTCAbiMetadata.RealTranslation) {
    llvm::errs() << "runnable-lift: PTC ABI metadata reports empty stub / "
                 << "real translation not migrated; continuing until legacy "
                 << "translation guards hit the unsupported boundary\n";
    return;
  }
}

static void findFiles(const char *Architecture) {
  // TODO: make this optional
  char *FullPath = realpath("/proc/self/exe", nullptr);
  runnable_assert(FullPath != nullptr);
  std::string Directory(dirname(FullPath));
  free(FullPath);

  // TODO: add other search paths?
  std::vector<std::string> SearchPaths;
  size_t LastSlash = Directory.find_last_of('/');
  if (LastSlash != std::string::npos) {
    std::string Prefix = Directory.substr(0, LastSlash);
    SearchPaths.push_back(Prefix + "/lib");
    SearchPaths.push_back(Prefix + "/share/runnable");
  }
#ifdef INSTALL_PATH
  SearchPaths.push_back(std::string(INSTALL_PATH) + "/lib");
  SearchPaths.push_back(std::string(INSTALL_PATH) + "/share/runnable");
#endif
  SearchPaths.push_back(Directory);
#ifdef QEMU_INSTALL_PATH
  SearchPaths.push_back(std::string(QEMU_INSTALL_PATH) + "/lib");
#endif

  bool LibtinycodeFound = false;
  bool EarlyLinkedFound = false;
  for (auto &Path : SearchPaths) {

    if (not LibtinycodeFound) {
      std::stringstream LibraryPath;
      LibraryPath << Path << "/libtinycode-" << Architecture << ".so";
      std::stringstream HelpersPath;
      HelpersPath << Path << "/libtinycode-helpers-" << Architecture << ".ll";
      if (access(LibraryPath.str().c_str(), F_OK) != -1
          && access(HelpersPath.str().c_str(), F_OK) != -1) {
        LibTinycodePath = LibraryPath.str();
        LibHelpersPath = HelpersPath.str();
        LibtinycodeFound = true;
      }
    }

    if (not EarlyLinkedFound) {
      std::stringstream TestPath;
      TestPath << Path << "/early-linked-" << Architecture << ".ll";
      if (access(TestPath.str().c_str(), F_OK) != -1) {
        EarlyLinkedPath = TestPath.str();
        EarlyLinkedFound = true;
      }
    }
  }

  runnable_assert(LibtinycodeFound, "Couldn't find libtinycode and the helpers");
  runnable_assert(EarlyLinkedFound, "Couldn't find early-linked.ll");
}

/// Given an architecture name, loads the appropriate version of the PTC
/// library, and initializes the PTC interface.
///
/// \param Architecture the name of the architecture, e.g. "arm".
/// \param PTCLibrary a reference to the library handler.
///
/// \return EXIT_SUCCESS if the library has been successfully loaded.
static int loadPTCLibrary(LibraryPointer &PTCLibrary) {
  ptc_load_ptr_t ptc_load = nullptr;
  void *LibraryHandle = nullptr;

  // Look for the library in the system's paths
  LibraryHandle = dlopen(LibTinycodePath.c_str(), RTLD_LAZY);

  if (LibraryHandle == nullptr) {
    fprintf(stderr, "Couldn't load the PTC library: %s\n", dlerror());
    return EXIT_FAILURE;
  }

  // The library has been loaded, initialize the pointer, the caller will take
  // care of dlclose it from now on
  PTCLibrary.reset(LibraryHandle);

  parsePTCAbiMetadata(findPTCAbiMetadata(LibraryHandle));
  printPTCAbiMetadata();
  if (RunnablePTCAbiMetadata.HasRealTranslation
      && !RunnablePTCAbiMetadata.RealTranslation) {
    fprintf(stderr,
            "runnable-lift: refusing QEMU V2 empty-stub library: real_translation=false\n");
    return EXIT_FAILURE;
  }

  // Obtain the address of the ptc_load entry point
  ptc_load = reinterpret_cast<ptc_load_ptr_t>(dlsym(LibraryHandle, "ptc_load"));

  if (ptc_load == nullptr) {
    fprintf(stderr, "Couldn't find ptc_load: %s\n", dlerror());
    return EXIT_FAILURE;
  }

  llvm::errs()<<ExecutableArgs<<"\n";
  // Initialize the ptc interface
  if (ptc_load(LibraryHandle, &ptc, InputPath.c_str(), ExecutableArgs.c_str()) != 0) {
    fprintf(stderr, "Couldn't find PTC functions.\n");
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int main(int argc, const char *argv[]) {
  initializeLegacyPasses();
  HideUnrelatedOptions({ &MainCategory });
  ParseCommandLineOptions(argc, argv);
  installStatistics();

  BinaryFile TheBinary(InputPath, BaseAddress);

  findFiles(TheBinary.architecture().name());

  // Load the appropriate libtyncode version
  LibraryPointer PTCLibrary;
  if (loadPTCLibrary(PTCLibrary) != EXIT_SUCCESS)
    return EXIT_FAILURE;

  // Translate everything
  Architecture TargetArchitecture;
  llvm::LLVMContext RevambGlobalContext;
  ParallelOptions Options;
  Options.DynamicParallel = DynamicParallel;
  Options.WorkerMode = ParallelWorkerMode;
  Options.WorkerCount = ParallelWorkers;
  Options.SeedPC = ParallelSeedPC;
  Options.FragmentDir = ParallelFragmentDir;
  Options.InputPath = InputPath;
  Options.ExecutableArgs = ExecutableArgs;
  Options.KeepWorkerFragments = KeepWorkerFragments;
  CodeGenerator Generator(TheBinary,
                          TargetArchitecture,
                          RevambGlobalContext,
                          std::string(OutputPath),
                          LibHelpersPath,
                          EarlyLinkedPath,
                          Options);

  Generator.translate(EntryPointAddress);
  Generator.serialize();

  return EXIT_SUCCESS;
}
