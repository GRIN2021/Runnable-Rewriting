#ifndef PTCINTERFACE_H
#define PTCINTERFACE_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <memory>
#include <string>
#include <type_traits>
#include <utility>

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
