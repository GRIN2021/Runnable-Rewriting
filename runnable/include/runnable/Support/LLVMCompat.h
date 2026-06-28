#ifndef RUNNABLE_LLVMCOMPAT_H
#define RUNNABLE_LLVMCOMPAT_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

#include <cassert>

#include "llvm/Config/llvm-config.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Casting.h"

namespace llvm {
#if LLVM_VERSION_MAJOR >= 8
using TerminatorInst = Instruction;
#endif
} // namespace llvm

namespace runnable_llvm {

inline llvm::Value *getCalledOperand(llvm::CallInst *Call) {
#if LLVM_VERSION_MAJOR >= 8
  return Call->getCalledOperand();
#else
  return Call->getCalledValue();
#endif
}

inline const llvm::Value *getCalledOperand(const llvm::CallInst *Call) {
#if LLVM_VERSION_MAJOR >= 8
  return Call->getCalledOperand();
#else
  return Call->getCalledValue();
#endif
}

inline llvm::PointerType *getInt8PtrTy(llvm::LLVMContext &Context) {
#if LLVM_VERSION_MAJOR >= 15
  return llvm::PointerType::get(Context, 0);
#else
  return llvm::Type::getInt8PtrTy(Context);
#endif
}

inline llvm::Type *getGlobalValueType(llvm::GlobalVariable *GV) {
  return GV->getValueType();
}

inline const llvm::Type *getGlobalValueType(const llvm::GlobalVariable *GV) {
  return GV->getValueType();
}

#if LLVM_VERSION_MAJOR >= 9
inline llvm::Constant *getOrInsertFunction(llvm::Module &M,
                                           llvm::StringRef Name,
                                           llvm::FunctionType *Ty) {
  return llvm::cast<llvm::Constant>(M.getOrInsertFunction(Name, Ty).getCallee());
}

template<typename... Args>
inline llvm::Constant *getOrInsertFunction(llvm::Module &M,
                                           llvm::StringRef Name,
                                           Args... FunctionArgs) {
  return llvm::cast<llvm::Constant>(
    M.getOrInsertFunction(Name, FunctionArgs...).getCallee());
}
#else
inline llvm::Constant *getOrInsertFunction(llvm::Module &M,
                                           llvm::StringRef Name,
                                           llvm::FunctionType *Ty) {
  return M.getOrInsertFunction(Name, Ty);
}

template<typename... Args>
inline llvm::Constant *getOrInsertFunction(llvm::Module &M,
                                           llvm::StringRef Name,
                                           Args... FunctionArgs) {
  return M.getOrInsertFunction(Name, FunctionArgs...);
}
#endif

inline llvm::TerminatorInst *dynCastTerminator(llvm::Instruction *I) {
#if LLVM_VERSION_MAJOR >= 8
  return I != nullptr && I->isTerminator() ? I : nullptr;
#else
  return llvm::dyn_cast_or_null<llvm::TerminatorInst>(I);
#endif
}

inline const llvm::TerminatorInst *
dynCastTerminator(const llvm::Instruction *I) {
#if LLVM_VERSION_MAJOR >= 8
  return I != nullptr && I->isTerminator() ? I : nullptr;
#else
  return llvm::dyn_cast_or_null<llvm::TerminatorInst>(I);
#endif
}

inline bool isaTerminator(const llvm::Instruction *I) {
  return dynCastTerminator(I) != nullptr;
}

inline auto successors(llvm::TerminatorInst *T) {
#if LLVM_VERSION_MAJOR >= 8
  assert(T != nullptr && T->isTerminator());
  return llvm::successors(T);
#else
  return T->successors();
#endif
}

inline llvm::TerminatorInst *castTerminator(llvm::Instruction *I) {
  llvm::TerminatorInst *T = dynCastTerminator(I);
  assert(T != nullptr);
  return T;
}

inline const llvm::TerminatorInst *
castTerminator(const llvm::Instruction *I) {
  const llvm::TerminatorInst *T = dynCastTerminator(I);
  assert(T != nullptr);
  return T;
}

} // namespace runnable_llvm

#endif // RUNNABLE_LLVMCOMPAT_H
