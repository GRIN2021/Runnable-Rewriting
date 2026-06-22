#ifndef PTCINTERFACE_H
#define PTCINTERFACE_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <memory>
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

namespace ptc_compat {

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
