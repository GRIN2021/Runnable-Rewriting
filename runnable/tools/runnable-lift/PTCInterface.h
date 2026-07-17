#ifndef PTCINTERFACE_H
#define PTCINTERFACE_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <algorithm>
#include <memory>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

// LLVM includes
#include "llvm/ADT/Twine.h"
#include "llvm/Support/raw_ostream.h"

// Local libraries includes
#include "runnable/Support/runnable.h"

// Local includes
#define USE_DYNAMIC_PTC
#include "ptc.h"

template<void (*T)(PTCInstructionList *)>
using PTCDestructorWrapper = std::integral_constant<decltype(T), T>;

using PTCDestructor = PTCDestructorWrapper<&ptc_instruction_list_free>;

using PTCInstructionListPtr = std::unique_ptr<PTCInstructionList,
                                              PTCDestructor>;

extern PTCInterface ptc;

struct RunnablePTCAbiMetadataInfo {
  bool Present = false;
  bool HasAbiVersion = false;
  unsigned AbiVersion = 0;
  bool HasStubKind = false;
  std::string StubKind;
  bool HasRealTranslation = false;
  bool RealTranslation = true;
  bool HasVectorSchema = false;
  bool VectorSchema = true;
  std::string Raw;
};

extern RunnablePTCAbiMetadataInfo RunnablePTCAbiMetadata;

namespace ptc_compat {

inline bool isPTCAbiV2() {
  return RunnablePTCAbiMetadata.HasAbiVersion
         && RunnablePTCAbiMetadata.AbiVersion >= 2;
}

inline const char *getConditionName(PTCInterface &Interface,
                                    PTCCondition Condition) {
  if (!isPTCAbiV2() && Interface.get_condition_name != nullptr)
    return Interface.get_condition_name(Condition);

  switch (Condition) {
  case PTC_COND_NEVER:
    return "never";
  case PTC_COND_ALWAYS:
    return "always";
  case PTC_COND_EQ:
    return "eq";
  case PTC_COND_NE:
    return "ne";
  case PTC_COND_LT:
    return "lt";
  case PTC_COND_GE:
    return "ge";
  case PTC_COND_LE:
    return "le";
  case PTC_COND_GT:
    return "gt";
  case PTC_COND_LTU:
    return "ltu";
  case PTC_COND_GEU:
    return "geu";
  case PTC_COND_LEU:
    return "leu";
  case PTC_COND_GTU:
    return "gtu";
  }

  return nullptr;
}

inline bool looksLikeRawTCGTempArg(PTCInstructionArg Arg,
                                   const PTCInstructionList &Instructions) {
  if (Arg < Instructions.total_temps)
    return false;

  // Modern sidecar args are raw TCGTemp pointers. Real immediates in this path
  // are usually small offsets or PC-sized constants, and are never inspected as
  // out/in temp operands.
  return Arg >= 4096;
}

struct RawTCGTempArgMap {
  bool Valid = false;
  uint64_t Base = 0;
  uint64_t Stride = 0;
  unsigned Hits = 0;
};

inline bool rawArgMapsToTemp(const RawTCGTempArgMap &Map,
                             const PTCInstructionList &Instructions,
                             PTCInstructionArg RawArg,
                             unsigned &TempId) {
  if (!Map.Valid)
    return false;
  if (RawArg < Map.Base)
    return false;

  uint64_t Delta = RawArg - Map.Base;
  if (Map.Stride == 0 || Delta % Map.Stride != 0)
    return false;

  uint64_t Index = Delta / Map.Stride;
  if (Index >= Instructions.total_temps)
    return false;

  TempId = static_cast<unsigned>(Index);
  return true;
}

inline RawTCGTempArgMap
inferRawTCGTempArgMap(const PTCInstructionList &Instructions,
                      const std::vector<PTCInstructionArg> &RawArgs) {
  RawTCGTempArgMap Best;
  if (RawArgs.size() < 2 || Instructions.total_temps == 0)
    return Best;

  std::vector<PTCInstructionArg> UniqueArgs = RawArgs;
  std::sort(UniqueArgs.begin(), UniqueArgs.end());
  UniqueArgs.erase(std::unique(UniqueArgs.begin(), UniqueArgs.end()),
                   UniqueArgs.end());

  for (uint64_t Stride = 8; Stride <= 256; Stride += 8) {
    for (PTCInstructionArg Anchor : UniqueArgs) {
      for (unsigned AnchorId = 0; AnchorId < Instructions.total_temps;
           AnchorId++) {
        uint64_t Offset = Stride * AnchorId;
        if (Anchor < Offset)
          continue;

        uint64_t Base = Anchor - Offset;
        unsigned Hits = 0;
        for (PTCInstructionArg Candidate : UniqueArgs) {
          unsigned TempId = 0;
          RawTCGTempArgMap Probe;
          Probe.Valid = true;
          Probe.Base = Base;
          Probe.Stride = Stride;
          if (rawArgMapsToTemp(Probe, Instructions, Candidate, TempId))
            Hits++;
        }

        if (Hits > Best.Hits) {
          Best.Valid = true;
          Best.Base = Base;
          Best.Stride = Stride;
          Best.Hits = Hits;
        }
      }
    }
  }

  if (Best.Hits < 2)
    Best.Valid = false;
  return Best;
}

inline bool normalizePTCV2InstructionList(PTCInterface &Interface,
                                          PTCInstructionList *Instructions) {
  if (!isPTCAbiV2())
    return true;
  if (Instructions == nullptr
      || Instructions->instructions == nullptr
      || Instructions->arguments == nullptr
      || Instructions->temps == nullptr
      || Instructions->instruction_count == 0
      || Instructions->total_temps == 0)
    return true;

  std::vector<PTCInstructionArg> RawTempArgs;
  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    PTCInstruction &Instruction = Instructions->instructions[I];
    PTCOpcodeDef *Def = ptc_instruction_opcode_def(&Interface, &Instruction);
    if (Def == nullptr || Instruction.args == nullptr)
      continue;

    if (Instruction.opc == PTC_INSTRUCTION_op_call)
      continue;

    unsigned TempArgCount = Def->nb_oargs + Def->nb_iargs;
    for (unsigned ArgIndex = 0; ArgIndex < TempArgCount; ArgIndex++) {
      PTCInstructionArg Arg = Instruction.args[ArgIndex];
      if (looksLikeRawTCGTempArg(Arg, *Instructions))
        RawTempArgs.push_back(Arg);
    }
  }

  RawTCGTempArgMap Map = inferRawTCGTempArgMap(*Instructions, RawTempArgs);
  if (!Map.Valid)
    return true;

  unsigned NormalizedArgs = 0;
  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    PTCInstruction &Instruction = Instructions->instructions[I];
    PTCOpcodeDef *Def = ptc_instruction_opcode_def(&Interface, &Instruction);
    if (Def == nullptr || Instruction.args == nullptr)
      continue;

    if (Instruction.opc == PTC_INSTRUCTION_op_call) {
      if (Instruction.callo == 0 && Instruction.calli == 0 && Def->nb_cargs >= 2) {
        unsigned TempId = 0;
        if (rawArgMapsToTemp(Map, *Instructions, Instruction.args[0], TempId)) {
          Instruction.args[0] = TempId;
          Instruction.calli = 1;
          NormalizedArgs++;
        }
      }
      continue;
    }

    unsigned TempArgCount = Def->nb_oargs + Def->nb_iargs;
    for (unsigned ArgIndex = 0; ArgIndex < TempArgCount; ArgIndex++) {
      PTCInstructionArg Arg = Instruction.args[ArgIndex];
      if (Arg < Instructions->total_temps)
        continue;

      unsigned TempId = 0;
      if (!rawArgMapsToTemp(Map, *Instructions, Arg, TempId)) {
        llvm::errs() << "runnable-lift: failed to decode QEMU v2 raw TCGArg"
                     << " instruction_index=" << I
                     << " opcode=" << static_cast<unsigned>(Instruction.opc)
                     << " arg_index=" << ArgIndex
                     << " raw=0x" << llvm::Twine::utohexstr(Arg)
                     << " temp_base=0x" << llvm::Twine::utohexstr(Map.Base)
                     << " temp_stride=" << Map.Stride
                     << " total_temps=" << Instructions->total_temps << "\n";
        return false;
      }

      Instruction.args[ArgIndex] = TempId;
      NormalizedArgs++;
    }
  }

  if (NormalizedArgs != 0) {
    llvm::errs() << "runnable-lift: normalized QEMU v2 raw TCGArg temps"
                 << " base=0x" << llvm::Twine::utohexstr(Map.Base)
                 << " stride=" << Map.Stride
                 << " refs=" << NormalizedArgs
                 << " matched_unique=" << Map.Hits
                 << " total_temps=" << Instructions->total_temps << "\n";
  }

  return true;
}

inline const char *getLoadStoreName(PTCInterface &Interface,
                                    PTCLoadStoreType Type) {
  if (Interface.get_load_store_name != nullptr)
    return Interface.get_load_store_name(Type);

  switch (Type) {
  case PTC_MO_UB:
    return "ub";
  case PTC_MO_SB:
    return "sb";
  case PTC_MO_LEUW:
    return "leuw";
  case PTC_MO_LESW:
    return "lesw";
  case PTC_MO_LEUL:
    return "leul";
  case PTC_MO_LESL:
    return "lesl";
  case PTC_MO_LEQ:
    return "leq";
  case PTC_MO_BEUW:
    return "beuw";
  case PTC_MO_BESW:
    return "besw";
  case PTC_MO_BEUL:
    return "beul";
  case PTC_MO_BESL:
    return "besl";
  case PTC_MO_BEQ:
    return "beq";
  default:
    return nullptr;
  }
}

inline PTCLoadStoreArg parseLoadStoreArg(PTCInterface &Interface,
                                         PTCInstructionArg Arg) {
  if (Interface.parse_load_store_arg != nullptr)
    return Interface.parse_load_store_arg(Arg);

  PTCLoadStoreArg Result = {};
  unsigned EncodedArg = static_cast<unsigned>(Arg);

  if (RunnablePTCAbiMetadata.HasAbiVersion
      && RunnablePTCAbiMetadata.AbiVersion >= 2) {
    constexpr unsigned MMUIndexBits = 5;
    constexpr unsigned MMUIndexMask = (1u << MMUIndexBits) - 1;
    constexpr unsigned V2MOSizeMask = 0x07;
    constexpr unsigned V2MOSign = 0x08;
    constexpr unsigned V2MOBSwap = 0x10;
    constexpr unsigned V2MOAlignShift = 5;
    constexpr unsigned V2MOAlignMask = 0x7u << V2MOAlignShift;
    constexpr unsigned V2MOAlign = V2MOAlignMask;
    constexpr unsigned V2MOAlignTLBOnly = 1u << 8;
    constexpr unsigned V2MOAtomMask = 0x7u << 9;

    unsigned RawOp = EncodedArg >> MMUIndexBits;
    Result.raw_op = RawOp;
    Result.mmu_index = EncodedArg & MMUIndexMask;

    unsigned UnexpectedBits =
      RawOp & ~(V2MOSizeMask | V2MOSign | V2MOBSwap | V2MOAlignMask
                | V2MOAlignTLBOnly | V2MOAtomMask);
    unsigned LegacyType = RawOp & V2MOSizeMask;

    if (RawOp & V2MOSign)
      LegacyType |= PTC_MO_SIGN;
    if (RawOp & V2MOBSwap)
      LegacyType |= PTC_MO_BSWAP;

    if (UnexpectedBits != 0 || (RawOp & V2MOSizeMask) > PTC_MO_64) {
      Result.access_type = PTC_MEMORY_ACCESS_UNKNOWN;
      return Result;
    }

    if (RawOp & V2MOAlignMask) {
      Result.access_type = (RawOp & V2MOAlignMask) == V2MOAlign ?
                           PTC_MEMORY_ACCESS_ALIGNED :
                           PTC_MEMORY_ACCESS_UNALIGNED;
    } else {
      Result.access_type = PTC_MEMORY_ACCESS_NORMAL;
    }

    Result.type = static_cast<PTCLoadStoreType>(LegacyType);
    return Result;
  }

  constexpr unsigned LegacyMMUIndexBits = 4;
  constexpr unsigned LegacyMMUIndexMask = (1u << LegacyMMUIndexBits) - 1;
  constexpr unsigned LegacyMOAlignMask = 16;
  constexpr unsigned LegacyMOAlign = 16;
  constexpr unsigned LegacyAllowedMask =
    LegacyMOAlignMask | static_cast<unsigned>(PTC_MO_BSWAP)
    | static_cast<unsigned>(PTC_MO_SSIZE);
  constexpr unsigned LegacyTypeMask =
    static_cast<unsigned>(PTC_MO_BSWAP)
    | static_cast<unsigned>(PTC_MO_SSIZE);

  Result.raw_op = EncodedArg >> LegacyMMUIndexBits;
  Result.mmu_index = EncodedArg & LegacyMMUIndexMask;
  if (Result.raw_op & ~LegacyAllowedMask) {
    Result.access_type = PTC_MEMORY_ACCESS_UNKNOWN;
  } else if (Result.raw_op & LegacyMOAlignMask) {
    Result.access_type = (Result.raw_op & LegacyMOAlignMask) == LegacyMOAlign ?
                         PTC_MEMORY_ACCESS_ALIGNED :
                         PTC_MEMORY_ACCESS_UNALIGNED;
  } else {
    Result.access_type = PTC_MEMORY_ACCESS_NORMAL;
  }
  Result.type = static_cast<PTCLoadStoreType>(Result.raw_op & LegacyTypeMask);
  return Result;
}

template<typename T>
auto queueDepthImpl(T &Interface, int)
  -> decltype(Interface.queueDepth(), uint32_t()) {
  if (Interface.queueDepth == nullptr)
    return 0;
  return Interface.queueDepth();
}

template<typename T>
uint32_t queueDepthImpl(T &, long) {
  return 0;
}

inline uint32_t queueDepth(PTCInterface &Interface) {
  return queueDepthImpl(Interface, 0);
}

template<typename T>
auto dropCPUStateImpl(T &Interface, int)
  -> decltype(Interface.dropCPUState(), uint32_t()) {
  if (Interface.dropCPUState == nullptr)
    return 0;
  return Interface.dropCPUState();
}

template<typename T>
uint32_t dropCPUStateImpl(T &, long) {
  return 0;
}

inline uint32_t dropCPUState(PTCInterface &Interface) {
  return dropCPUStateImpl(Interface, 0);
}

template<typename T>
auto deleteCPULINEStateImpl(T &Interface, int)
  -> decltype(Interface.deletCPULINEState(), uint32_t()) {
  if (Interface.deletCPULINEState == nullptr)
    return 0;
  return Interface.deletCPULINEState();
}

template<typename T>
uint32_t deleteCPULINEStateImpl(T &, long) {
  return 0;
}

inline uint32_t deleteCPULINEState(PTCInterface &Interface) {
  return deleteCPULINEStateImpl(Interface, 0);
}

template<typename T>
auto storeCPUStateImpl(T &Interface, int)
  -> decltype(Interface.storeCPUState(), uint32_t()) {
  if (Interface.storeCPUState == nullptr)
    return 0;
  return Interface.storeCPUState();
}

template<typename T>
uint32_t storeCPUStateImpl(T &, long) {
  return 0;
}

inline uint32_t storeCPUState(PTCInterface &Interface) {
  return storeCPUStateImpl(Interface, 0);
}

template<typename T>
auto supportsQueueDepthImpl(int)
  -> decltype(std::declval<T &>().queueDepth(), std::true_type()) {
  return std::true_type();
}

template<typename T>
std::false_type supportsQueueDepthImpl(long) {
  return std::false_type();
}

inline bool supportsQueueDepth() {
  return decltype(supportsQueueDepthImpl<PTCInterface>(0))::value;
}

template<typename T>
auto supportsDropCPUStateImpl(int)
  -> decltype(std::declval<T &>().dropCPUState(), std::true_type()) {
  return std::true_type();
}

template<typename T>
std::false_type supportsDropCPUStateImpl(long) {
  return std::false_type();
}

inline bool supportsDropCPUState() {
  return decltype(supportsDropCPUStateImpl<PTCInterface>(0))::value;
}

template<typename T>
auto hasStoreCPUStateImpl(T &Interface, int)
  -> decltype(Interface.storeCPUState, bool()) {
  return Interface.storeCPUState != nullptr;
}

template<typename T>
bool hasStoreCPUStateImpl(T &, long) {
  return false;
}

inline bool hasStoreCPUState(PTCInterface &Interface) {
  return hasStoreCPUStateImpl(Interface, 0);
}

template<typename T>
auto hasDropCPUStateImpl(T &Interface, int)
  -> decltype(Interface.dropCPUState, bool()) {
  return Interface.dropCPUState != nullptr;
}

template<typename T>
bool hasDropCPUStateImpl(T &, long) {
  return false;
}

inline bool hasDropCPUState(PTCInterface &Interface) {
  return hasDropCPUStateImpl(Interface, 0);
}

} // namespace ptc_compat

#define RAX 97120 
#define RCX 99120
#define RDX 100120
#define RBX 98120
#define RSP 115112
#define RBP 98112
#define RSI 115105
#define RDI 100105
#define R8  56000
#define R9  57000
#define R10 49048
#define R11 49049
#define R12 49050
#define R13 49051
#define R14 49052
#define R15 49053

#define R_EAX 0
#define R_ECX 1
#define R_EDX 2
#define R_EBX 3
#define R_ESP 4
#define R_EBP 5
#define R_ESI 6
#define R_EDI 7
#define R_8 8
#define R_9 9
#define R_10 10
#define R_11 11
#define R_12 12
#define R_13 13
#define R_14 14
#define R_15 15
#define REGS 16
#define UndefineOP 20

#endif // PTCINTERFACE_H
