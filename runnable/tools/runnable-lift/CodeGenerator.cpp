/// \file codegenerator.cpp
/// \brief This file handles the whole translation process from the input
///        assembly to LLVM IR.

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <cerrno>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <memory>
#include <queue>
#include <set>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include <exception>

// Boost includes
#include <boost/icl/interval_map.hpp>
#include <boost/icl/right_open_interval.hpp>
#include <boost/type_traits/is_same.hpp>

// LLVM includes
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/ExecutionEngine/RuntimeDyld.h"
#include "llvm/IR/AssemblyAnnotationWriter.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/DiagnosticPrinter.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Linker/Linker.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_os_ostream.h"
#include "llvm/Transforms/Scalar.h"
#include "llvm/Transforms/Utils.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/Cloning.h"
#if LLVM_VERSION_MAJOR >= 10
#include "llvm/Support/Alignment.h"
#endif

// Local libraries includes
#include "runnable/Support/CommandLine.h"
#include "runnable/Support/Debug.h"
#include "runnable/Support/DebugHelper.h"
#include "runnable/Support/runnable.h"

// Local includes
#include "CodeGenerator.h"
#include "ExternalJumpsHandler.h"
#include "InstructionTranslator.h"
#include "JumpTargetManager.h"
#include "PTCInterface.h"
#include "VariableManager.h"

using namespace llvm;

using std::make_pair;
using std::string;

namespace {

constexpr size_t QEMUV2LargeRootSROAInstructionThreshold = 75000;

static std::string hexValue(uint64_t Value) {
  std::ostringstream Stream;
  Stream << std::hex << Value;
  return Stream.str();
}

static size_t countInstructions(const Function &F) {
  size_t Count = 0;
  for (const BasicBlock &BB : F)
    Count += BB.size();
  return Count;
}

static size_t countAllocas(const Function &F) {
  size_t Count = 0;
  for (const BasicBlock &BB : F) {
    for (const Instruction &I : BB) {
      if (isa<AllocaInst>(I))
        Count++;
    }
  }
  return Count;
}

static std::chrono::steady_clock::time_point
startLiftPhaseTimer(const char *Name) {
  errs() << "runnable-lift: phase " << Name << " start\n";
  return std::chrono::steady_clock::now();
}

static void finishLiftPhaseTimer(const char *Name,
                                 std::chrono::steady_clock::time_point Start) {
  auto End = std::chrono::steady_clock::now();
  std::chrono::duration<double> Elapsed = End - Start;
  errs() << "runnable-lift: phase " << Name << " done seconds="
         << Elapsed.count() << "\n";
}

static void setGlobalAlignment(GlobalVariable *Variable, uint64_t Alignment) {
#if LLVM_VERSION_MAJOR >= 10
  Variable->setAlignment(Align(Alignment));
#else
  Variable->setAlignment(Alignment);
#endif
}

static LoadInst *createLoad(Type *LoadedType, Value *Pointer,
                            const Twine &Name,
                            Instruction *InsertBefore) {
#if LLVM_VERSION_MAJOR >= 15
  return new LoadInst(LoadedType, Pointer, Name, InsertBefore);
#else
  (void) LoadedType;
  return new LoadInst(Pointer, Name, InsertBefore);
#endif
}

static LoadInst *createBuilderLoad(IRBuilder<> &Builder,
                                   Type *LoadedType,
                                   Value *Pointer,
                                   const Twine &Name = "") {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateLoad(LoadedType, Pointer, Name);
#else
  (void) LoadedType;
  return Builder.CreateLoad(Pointer, Name);
#endif
}

static CallInst *createNoArgCall(IRBuilder<> &Builder,
                                 FunctionType *FunctionTy,
                                 Value *Callee) {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateCall(FunctionTy, Callee, ArrayRef<Value *>());
#else
  (void) FunctionTy;
  return Builder.CreateCall(Callee);
#endif
}

static CallInst *createFunctionCall(IRBuilder<> &Builder,
                                    FunctionType *FunctionTy,
                                    Value *Callee,
                                    ArrayRef<Value *> Args) {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateCall(FunctionTy, Callee, Args);
#else
  (void) FunctionTy;
  return Builder.CreateCall(Callee, Args);
#endif
}

static bool defineQEMURecheckingSingleStepHelper(Module &M) {
  if (M.getFunction("helper_rechecking_single_step") != nullptr)
    return false;

  Function *SingleStep = M.getFunction("helper_single_step");
  if (SingleStep == nullptr || SingleStep->isDeclaration())
    return false;

  FunctionType *SingleStepTy = SingleStep->getFunctionType();
  if (!SingleStepTy->getReturnType()->isVoidTy()
      || SingleStepTy->getNumParams() != 1)
    return false;

  Type *EnvType = SingleStepTy->getParamType(0);
  StructType *CPUStateType =
#if LLVM_VERSION_MAJOR >= 18
    StructType::getTypeByName(M.getContext(), "struct.CPUX86State");
#else
    M.getTypeByName("struct.CPUX86State");
#endif
#if LLVM_VERSION_MAJOR < 15
  if (CPUStateType == nullptr) {
    if (auto *EnvPointerType = dyn_cast<PointerType>(EnvType))
      CPUStateType = dyn_cast<StructType>(EnvPointerType->getElementType());
  }
#endif
  if (CPUStateType == nullptr || CPUStateType->getNumElements() <= 2)
    return false;

  Type *EflagsType = CPUStateType->getElementType(2);
  auto *EflagsIntType = dyn_cast<IntegerType>(EflagsType);
  if (EflagsIntType == nullptr)
    return false;

  LLVMContext &Context = M.getContext();
  std::vector<Type *> HelperArgs = { EnvType };
  FunctionType *HelperTy =
    FunctionType::get(Type::getVoidTy(Context), HelperArgs, false);
  auto *Helper = Function::Create(HelperTy,
                                  GlobalValue::ExternalLinkage,
                                  "helper_rechecking_single_step",
                                  &M);

  auto *Entry = BasicBlock::Create(Context, "entry", Helper);
  auto *Raise = BasicBlock::Create(Context, "single_step", Helper);
  auto *Done = BasicBlock::Create(Context, "done", Helper);

  Argument *Env = &*Helper->arg_begin();
  IRBuilder<> Builder(Entry);
  Value *EflagsPtr =
    Builder.CreateStructGEP(CPUStateType, Env, 2, "eflags.ptr");
  Value *Eflags = createBuilderLoad(Builder, EflagsType, EflagsPtr, "eflags");
  Value *TrapFlag =
    Builder.CreateAnd(Eflags, ConstantInt::get(EflagsIntType, 0x100),
                      "trap_flag");
  Value *TrapFlagSet =
    Builder.CreateICmpNE(TrapFlag, ConstantInt::get(EflagsIntType, 0),
                         "trap_flag_set");
  Builder.CreateCondBr(TrapFlagSet, Raise, Done);

  Builder.SetInsertPoint(Raise);
  std::vector<Value *> SingleStepArgs = { Env };
  createFunctionCall(Builder, SingleStepTy, SingleStep, SingleStepArgs);
  Builder.CreateUnreachable();

  Builder.SetInsertPoint(Done);
  Builder.CreateRetVoid();

  errs() << "runnable-lift: added QEMU v2 helper definition"
         << " helper_rechecking_single_step\n";
  return true;
}

static bool defineQEMUCCComputeNZHelper(Module &M) {
  Function *Existing = M.getFunction("helper_cc_compute_nz");
  if (Existing != nullptr && !Existing->isDeclaration())
    return false;

  LLVMContext &Context = M.getContext();
  Type *Int64Ty = Type::getInt64Ty(Context);
  Type *Int32Ty = Type::getInt32Ty(Context);
  std::vector<Type *> HelperArgs = { Int64Ty, Int64Ty, Int32Ty };
  FunctionType *HelperTy =
    FunctionType::get(Int64Ty, HelperArgs, false);

  Function *Helper = Existing;
  if (Helper != nullptr) {
    if (Helper->getFunctionType() != HelperTy)
      return false;
  } else {
    Helper = Function::Create(HelperTy,
                              GlobalValue::ExternalLinkage,
                              "helper_cc_compute_nz",
                              &M);
  }

  auto *Entry = BasicBlock::Create(Context, "entry", Helper);
  auto *FromEflags = BasicBlock::Create(Context, "eflags", Helper);
  auto *FromResult = BasicBlock::Create(Context, "result", Helper);

  auto ArgIt = Helper->arg_begin();
  Value *Dst = &*ArgIt++;
  Value *Src1 = &*ArgIt++;
  Value *Op = &*ArgIt++;

  IRBuilder<> Builder(Entry);
  Value *HasEflags =
    Builder.CreateICmpULE(Op, ConstantInt::get(Int32Ty, 3),
                          "has_eflags");
  Builder.CreateCondBr(HasEflags, FromEflags, FromResult);

  Builder.SetInsertPoint(FromEflags);
  Value *NotSrc1 = Builder.CreateNot(Src1, "not_src1");
  Value *ZFlag = Builder.CreateAnd(NotSrc1, ConstantInt::get(Int64Ty, 0x40),
                                   "z_flag");
  Builder.CreateRet(ZFlag);

  Builder.SetInsertPoint(FromResult);
  Value *Size = Builder.CreateAnd(Op, ConstantInt::get(Int32Ty, 3), "size");
  Value *IsByte =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 0), "is_byte");
  Value *IsWord =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 1), "is_word");
  Value *IsLong =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 2), "is_long");
  Value *WordOrLarger =
    Builder.CreateSelect(IsWord,
                         ConstantInt::get(Int64Ty, 0xffff),
                         ConstantInt::getAllOnesValue(Int64Ty),
                         "word_or_larger_mask");
  Value *LongOrLarger =
    Builder.CreateSelect(IsLong,
                         ConstantInt::get(Int64Ty, 0xffffffffULL),
                         WordOrLarger,
                         "long_or_larger_mask");
  Value *Mask =
    Builder.CreateSelect(IsByte,
                         ConstantInt::get(Int64Ty, 0xff),
                         LongOrLarger,
                         "mask");
  Value *MaskedDst = Builder.CreateAnd(Dst, Mask, "masked_dst");
  Builder.CreateRet(MaskedDst);

  errs() << "runnable-lift: added QEMU v2 helper definition"
         << " helper_cc_compute_nz\n";
  return true;
}

static Value *createQEMUCCOpRangeCheck(IRBuilder<> &Builder,
                                       Value *Op,
                                       uint32_t Lower,
                                       uint32_t Upper,
                                       const Twine &Name) {
  auto *Int32Ty = Type::getInt32Ty(Builder.getContext());
  Value *AboveLower =
    Builder.CreateICmpUGE(Op, ConstantInt::get(Int32Ty, Lower),
                          Name + ".ge");
  Value *BelowUpper =
    Builder.CreateICmpULE(Op, ConstantInt::get(Int32Ty, Upper),
                          Name + ".le");
  return Builder.CreateAnd(AboveLower, BelowUpper, Name);
}

static Value *createQEMUCCOpSizeMask(IRBuilder<> &Builder, Value *Op) {
  auto &Context = Builder.getContext();
  auto *Int32Ty = Type::getInt32Ty(Context);
  auto *Int64Ty = Type::getInt64Ty(Context);

  Value *Size = Builder.CreateAnd(Op, ConstantInt::get(Int32Ty, 3),
                                  "cc_size");
  Value *IsByte =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 0),
                         "cc_size_byte");
  Value *IsWord =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 1),
                         "cc_size_word");
  Value *IsLong =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 2),
                         "cc_size_long");
  Value *WordOrQword =
    Builder.CreateSelect(IsWord,
                         ConstantInt::get(Int64Ty, 0xffff),
                         ConstantInt::getAllOnesValue(Int64Ty),
                         "cc_word_or_qword_mask");
  Value *LongOrLarger =
    Builder.CreateSelect(IsLong,
                         ConstantInt::get(Int64Ty, 0xffffffffULL),
                         WordOrQword,
                         "cc_long_or_larger_mask");
  return Builder.CreateSelect(IsByte,
                              ConstantInt::get(Int64Ty, 0xff),
                              LongOrLarger,
                              "cc_size_mask");
}

static Value *createQEMUCCOpSignFlag(IRBuilder<> &Builder,
                                     Value *MaskedDst,
                                     Value *Op) {
  auto &Context = Builder.getContext();
  auto *Int32Ty = Type::getInt32Ty(Context);
  auto *Int64Ty = Type::getInt64Ty(Context);

  Value *Size = Builder.CreateAnd(Op, ConstantInt::get(Int32Ty, 3),
                                  "cc_sign_size");
  Value *IsByte =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 0),
                         "cc_sign_byte");
  Value *IsWord =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 1),
                         "cc_sign_word");
  Value *IsLong =
    Builder.CreateICmpEQ(Size, ConstantInt::get(Int32Ty, 2),
                         "cc_sign_long");
  Value *WordOrQword =
    Builder.CreateSelect(IsWord,
                         ConstantInt::get(Int32Ty, 8),
                         ConstantInt::get(Int32Ty, 56),
                         "cc_word_or_qword_sign_shift");
  Value *LongOrLarger =
    Builder.CreateSelect(IsLong,
                         ConstantInt::get(Int32Ty, 24),
                         WordOrQword,
                         "cc_long_or_larger_sign_shift");
  Value *Shift =
    Builder.CreateSelect(IsByte,
                         ConstantInt::get(Int32Ty, 0),
                         LongOrLarger,
                         "cc_sign_shift");
  Value *Shift64 = Builder.CreateZExt(Shift, Int64Ty);
  Value *Shifted = Builder.CreateLShr(MaskedDst, Shift64, "cc_sign_shifted");
  return Builder.CreateAnd(Shifted, ConstantInt::get(Int64Ty, 0x80),
                           "cc_sign_flag");
}

static Value *createQEMUV2BLSIAllFlags(IRBuilder<> &Builder,
                                       Value *Dst,
                                       Value *Src1,
                                       Value *Op) {
  auto *Int64Ty = Type::getInt64Ty(Builder.getContext());
  Value *Mask = createQEMUCCOpSizeMask(Builder, Op);
  Value *MaskedDst = Builder.CreateAnd(Dst, Mask, "blsi_dst");
  Value *MaskedSrc1 = Builder.CreateAnd(Src1, Mask, "blsi_src1");
  Value *Src1NonZero =
    Builder.CreateICmpNE(MaskedSrc1, ConstantInt::get(Int64Ty, 0),
                         "blsi_src1_nonzero");
  Value *DstIsZero =
    Builder.CreateICmpEQ(MaskedDst, ConstantInt::get(Int64Ty, 0),
                         "blsi_dst_zero");
  Value *Carry =
    Builder.CreateSelect(Src1NonZero,
                         ConstantInt::get(Int64Ty, 1),
                         ConstantInt::get(Int64Ty, 0),
                         "blsi_carry");
  Value *Zero =
    Builder.CreateSelect(DstIsZero,
                         ConstantInt::get(Int64Ty, 0x40),
                         ConstantInt::get(Int64Ty, 0),
                         "blsi_zero");
  Value *Sign = createQEMUCCOpSignFlag(Builder, MaskedDst, Op);
  return Builder.CreateOr(Builder.CreateOr(Carry, Zero), Sign,
                          "blsi_all_flags");
}

static Value *createQEMUV2BLSICarry(IRBuilder<> &Builder,
                                    Value *Src1,
                                    Value *Op) {
  auto *Int64Ty = Type::getInt64Ty(Builder.getContext());
  Value *Mask = createQEMUCCOpSizeMask(Builder, Op);
  Value *MaskedSrc1 = Builder.CreateAnd(Src1, Mask, "blsi_c_src1");
  Value *Src1NonZero =
    Builder.CreateICmpNE(MaskedSrc1, ConstantInt::get(Int64Ty, 0),
                         "blsi_c_src1_nonzero");
  return Builder.CreateSelect(Src1NonZero,
                              ConstantInt::get(Int64Ty, 1),
                              ConstantInt::get(Int64Ty, 0),
                              "blsi_carry");
}

static __attribute__((unused)) Function *
createQEMUV2CCComputeAllWrapper(Module &M, Function *Legacy) {
  FunctionType *HelperTy = Legacy->getFunctionType();
  auto *Wrapper = Function::Create(HelperTy,
                                   GlobalValue::ExternalLinkage,
                                   "helper_cc_compute_all",
                                   &M);

  LLVMContext &Context = M.getContext();
  auto *Int32Ty = Type::getInt32Ty(Context);
  auto *Int64Ty = Type::getInt64Ty(Context);

  auto ArgIt = Wrapper->arg_begin();
  Value *Dst = &*ArgIt++;
  Value *Src1 = &*ArgIt++;
  Value *Src2 = &*ArgIt++;
  Value *Op = &*ArgIt++;

  auto *Entry = BasicBlock::Create(Context, "entry", Wrapper);
  auto *Eflags = BasicBlock::Create(Context, "eflags", Wrapper);
  auto *CheckADCX = BasicBlock::Create(Context, "check_adcx", Wrapper);
  auto *ADCX = BasicBlock::Create(Context, "adcx", Wrapper);
  auto *CheckADOX = BasicBlock::Create(Context, "check_adox", Wrapper);
  auto *ADOX = BasicBlock::Create(Context, "adox", Wrapper);
  auto *CheckADCOX = BasicBlock::Create(Context, "check_adcox", Wrapper);
  auto *ADCOX = BasicBlock::Create(Context, "adcox", Wrapper);
  auto *CheckLegacy = BasicBlock::Create(Context, "check_legacy", Wrapper);
  auto *LegacyBB = BasicBlock::Create(Context, "legacy", Wrapper);
  auto *CheckBLSI = BasicBlock::Create(Context, "check_blsi", Wrapper);
  auto *BLSI = BasicBlock::Create(Context, "blsi", Wrapper);
  auto *CheckPOPCNT = BasicBlock::Create(Context, "check_popcnt", Wrapper);
  auto *POPCNT = BasicBlock::Create(Context, "popcnt", Wrapper);
  auto *Default = BasicBlock::Create(Context, "default", Wrapper);

  IRBuilder<> Builder(Entry);
  Value *IsEflags =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 0), "is_eflags");
  Builder.CreateCondBr(IsEflags, Eflags, CheckADCX);

  Builder.SetInsertPoint(Eflags);
  Builder.CreateRet(Src1);

  Builder.SetInsertPoint(CheckADCX);
  Value *IsADCX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 1), "is_adcx");
  Builder.CreateCondBr(IsADCX, ADCX, CheckADOX);

  Builder.SetInsertPoint(ADCX);
  Value *ADCXRest =
    Builder.CreateAnd(Src1, ConstantInt::get(Int64Ty, ~uint64_t(1)),
                      "adcx_rest");
  Builder.CreateRet(Builder.CreateOr(ADCXRest, Dst, "adcx_flags"));

  Builder.SetInsertPoint(CheckADOX);
  Value *IsADOX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 2), "is_adox");
  Builder.CreateCondBr(IsADOX, ADOX, CheckADCOX);

  Builder.SetInsertPoint(ADOX);
  Value *ADOXRest =
    Builder.CreateAnd(Src1, ConstantInt::get(Int64Ty, ~uint64_t(0x800)),
                      "adox_rest");
  Value *ADOXOverflow =
    Builder.CreateMul(Src2, ConstantInt::get(Int64Ty, 0x800),
                      "adox_overflow");
  Builder.CreateRet(Builder.CreateOr(ADOXRest, ADOXOverflow, "adox_flags"));

  Builder.SetInsertPoint(CheckADCOX);
  Value *IsADCOX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 3), "is_adcox");
  Builder.CreateCondBr(IsADCOX, ADCOX, CheckLegacy);

  Builder.SetInsertPoint(ADCOX);
  Value *ADCOXRest =
    Builder.CreateAnd(Src1, ConstantInt::get(Int64Ty, ~uint64_t(0x801)),
                      "adcox_rest");
  Value *ADCOXOverflow =
    Builder.CreateMul(Src2, ConstantInt::get(Int64Ty, 0x800),
                      "adcox_overflow");
  Value *ADCOXFlags =
    Builder.CreateOr(Builder.CreateOr(ADCOXRest, Dst), ADCOXOverflow,
                     "adcox_flags");
  Builder.CreateRet(ADCOXFlags);

  Builder.SetInsertPoint(CheckLegacy);
  Value *IsLegacy =
    createQEMUCCOpRangeCheck(Builder, Op, 4, 47, "is_legacy_cc_op");
  Builder.CreateCondBr(IsLegacy, LegacyBB, CheckBLSI);

  Builder.SetInsertPoint(LegacyBB);
  Value *LegacyOp =
    Builder.CreateSub(Op, ConstantInt::get(Int32Ty, 2), "legacy_cc_op");
  Builder.CreateRet(createFunctionCall(Builder,
                                       HelperTy,
                                       Legacy,
                                       { Dst, Src1, Src2, LegacyOp }));

  Builder.SetInsertPoint(CheckBLSI);
  Value *IsBLSI = createQEMUCCOpRangeCheck(Builder, Op, 48, 51,
                                           "is_blsi_cc_op");
  Builder.CreateCondBr(IsBLSI, BLSI, CheckPOPCNT);

  Builder.SetInsertPoint(BLSI);
  Builder.CreateRet(createQEMUV2BLSIAllFlags(Builder, Dst, Src1, Op));

  Builder.SetInsertPoint(CheckPOPCNT);
  Value *IsPOPCNT = createQEMUCCOpRangeCheck(Builder, Op, 52, 55,
                                             "is_popcnt_cc_op");
  Builder.CreateCondBr(IsPOPCNT, POPCNT, Default);

  Builder.SetInsertPoint(POPCNT);
  Value *DstIsZero =
    Builder.CreateICmpEQ(Dst, ConstantInt::get(Int64Ty, 0),
                         "popcnt_dst_zero");
  Builder.CreateRet(Builder.CreateSelect(DstIsZero,
                                         ConstantInt::get(Int64Ty, 0x40),
                                         ConstantInt::get(Int64Ty, 0),
                                         "popcnt_flags"));

  Builder.SetInsertPoint(Default);
  Builder.CreateRet(ConstantInt::get(Int64Ty, 0));

  return Wrapper;
}

static __attribute__((unused)) Function *
createQEMUV2CCComputeCWrapper(Module &M, Function *Legacy) {
  FunctionType *HelperTy = Legacy->getFunctionType();
  auto *Wrapper = Function::Create(HelperTy,
                                   GlobalValue::ExternalLinkage,
                                   "helper_cc_compute_c",
                                   &M);

  LLVMContext &Context = M.getContext();
  auto *Int32Ty = Type::getInt32Ty(Context);
  auto *Int64Ty = Type::getInt64Ty(Context);

  auto ArgIt = Wrapper->arg_begin();
  Value *Dst = &*ArgIt++;
  Value *Src1 = &*ArgIt++;
  Value *Src2 = &*ArgIt++;
  Value *Op = &*ArgIt++;

  auto *Entry = BasicBlock::Create(Context, "entry", Wrapper);
  auto *Src1Carry = BasicBlock::Create(Context, "src1_carry", Wrapper);
  auto *CheckDstCarry = BasicBlock::Create(Context, "check_dst_carry",
                                           Wrapper);
  auto *DstCarry = BasicBlock::Create(Context, "dst_carry", Wrapper);
  auto *CheckLegacy = BasicBlock::Create(Context, "check_legacy", Wrapper);
  auto *LegacyBB = BasicBlock::Create(Context, "legacy", Wrapper);
  auto *CheckBLSI = BasicBlock::Create(Context, "check_blsi", Wrapper);
  auto *BLSI = BasicBlock::Create(Context, "blsi", Wrapper);
  auto *Zero = BasicBlock::Create(Context, "zero", Wrapper);

  IRBuilder<> Builder(Entry);
  Value *IsEflags =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 0), "is_eflags");
  Value *IsADOX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 2), "is_adox");
  Builder.CreateCondBr(Builder.CreateOr(IsEflags, IsADOX,
                                        "src1_carry_op"),
                       Src1Carry,
                       CheckDstCarry);

  Builder.SetInsertPoint(Src1Carry);
  Builder.CreateRet(Builder.CreateAnd(Src1, ConstantInt::get(Int64Ty, 1),
                                      "src1_carry"));

  Builder.SetInsertPoint(CheckDstCarry);
  Value *IsADCX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 1), "is_adcx");
  Value *IsADCOX =
    Builder.CreateICmpEQ(Op, ConstantInt::get(Int32Ty, 3), "is_adcox");
  Builder.CreateCondBr(Builder.CreateOr(IsADCX, IsADCOX,
                                        "dst_carry_op"),
                       DstCarry,
                       CheckLegacy);

  Builder.SetInsertPoint(DstCarry);
  Builder.CreateRet(Dst);

  Builder.SetInsertPoint(CheckLegacy);
  Value *IsLegacy =
    createQEMUCCOpRangeCheck(Builder, Op, 4, 47, "is_legacy_cc_op");
  Builder.CreateCondBr(IsLegacy, LegacyBB, CheckBLSI);

  Builder.SetInsertPoint(LegacyBB);
  Value *LegacyOp =
    Builder.CreateSub(Op, ConstantInt::get(Int32Ty, 2), "legacy_cc_op");
  Builder.CreateRet(createFunctionCall(Builder,
                                       HelperTy,
                                       Legacy,
                                       { Dst, Src1, Src2, LegacyOp }));

  Builder.SetInsertPoint(CheckBLSI);
  Value *IsBLSI = createQEMUCCOpRangeCheck(Builder, Op, 48, 51,
                                           "is_blsi_cc_op");
  Builder.CreateCondBr(IsBLSI, BLSI, Zero);

  Builder.SetInsertPoint(BLSI);
  Builder.CreateRet(createQEMUV2BLSICarry(Builder, Src1, Op));

  Builder.SetInsertPoint(Zero);
  Builder.CreateRet(ConstantInt::get(Int64Ty, 0));

  return Wrapper;
}

static __attribute__((unused)) void
redirectQEMUV2CCLegacyCalls(Function *Legacy, Function *Wrapper) {
  std::vector<CallInst *> Calls;
  for (User *TheUser : Legacy->users()) {
    auto *Call = dyn_cast<CallInst>(TheUser);
    if (Call == nullptr || Call->getFunction() == Wrapper)
      continue;
    Calls.push_back(Call);
  }

  for (CallInst *Call : Calls)
    Call->setCalledFunction(Wrapper);
}

static bool mapLegacyX86CCOpToQEMUV2(uint64_t LegacyOp,
                                     uint64_t &QEMUV2Op) {
  if (LegacyOp == 1) {
    QEMUV2Op = 0;
    return true;
  }

  if (LegacyOp >= 2 && LegacyOp <= 45) {
    QEMUV2Op = LegacyOp + 2;
    return true;
  }

  if (LegacyOp >= 46 && LegacyOp <= 48) {
    QEMUV2Op = LegacyOp - 45;
    return true;
  }

  return false;
}

static bool remapLegacyX86CCOpSwitches(Function *Helper) {
  bool Changed = false;
  auto *Int32Ty = Type::getInt32Ty(Helper->getContext());

  for (BasicBlock &BB : *Helper) {
    for (Instruction &I : BB) {
      auto *Switch = dyn_cast<SwitchInst>(&I);
      if (Switch == nullptr)
        continue;

      std::vector<std::pair<uint64_t, BasicBlock *>> NewCases;
      std::set<uint64_t> SeenCases;
      for (auto Case = Switch->case_begin(); Case != Switch->case_end();
           ++Case) {
        uint64_t NewOp = 0;
        if (!mapLegacyX86CCOpToQEMUV2(Case->getCaseValue()->getZExtValue(),
                                      NewOp))
          continue;
        if (!SeenCases.insert(NewOp).second)
          continue;
        NewCases.push_back({ NewOp, Case->getCaseSuccessor() });
      }

      while (Switch->case_begin() != Switch->case_end())
        Switch->removeCase(Switch->case_begin());

      for (auto &Entry : NewCases) {
        Switch->addCase(ConstantInt::get(Int32Ty, Entry.first),
                        Entry.second);
      }

      Changed = true;
    }
  }

  return Changed;
}

static bool defineQEMUV2X86CCComputeCompatHelpers(Module &M) {
  if (!ptc_compat::isPTCAbiV2())
    return false;

  LLVMContext &Context = M.getContext();
  Type *Int64Ty = Type::getInt64Ty(Context);
  Type *Int32Ty = Type::getInt32Ty(Context);
  FunctionType *ExpectedTy =
    FunctionType::get(Int64Ty, { Int64Ty, Int64Ty, Int64Ty, Int32Ty },
                      false);

  Function *All = M.getFunction("helper_cc_compute_all");
  Function *Carry = M.getFunction("helper_cc_compute_c");
  if (All == nullptr || Carry == nullptr
      || All->isDeclaration() || Carry->isDeclaration()
      || All->getFunctionType() != ExpectedTy
      || Carry->getFunctionType() != ExpectedTy)
    return false;

  bool Changed = remapLegacyX86CCOpSwitches(All);
  Changed |= remapLegacyX86CCOpSwitches(Carry);
  if (!Changed)
    return false;

  errs() << "runnable-lift: remapped QEMU v2 x86_64 condition-code helpers"
         << " for QEMU10 CC_OP enum compatibility\n";
  return true;
}

static GlobalVariable *getOrCreateI32GlobalDefinition(Module &M,
                                                      StringRef Name) {
  Type *Int32Ty = Type::getInt32Ty(M.getContext());
  Constant *Zero = ConstantInt::get(Int32Ty, 0);

  if (GlobalVariable *GV = M.getNamedGlobal(Name)) {
    runnable_assert(GV->getValueType() == Int32Ty);
    GV->setConstant(false);
    if (GV->isDeclaration())
      GV->setInitializer(Zero);
    return GV;
  }

  return new GlobalVariable(M,
                            Int32Ty,
                            false,
                            GlobalValue::ExternalLinkage,
                            Zero,
                            Name);
}

struct EffectivePTCOffsets {
  intptr_t PC;
  intptr_t SP;
};

static EffectivePTCOffsets getEffectivePTCOffsets(const Architecture &Arch) {
  EffectivePTCOffsets Result = { ptc.pc, ptc.sp };

  if (ptc_compat::isPTCAbiV2()
      && Arch.type() == Triple::x86_64
      && Result.PC == 0
      && Result.SP == 0) {
    // QEMU v2 sidecar builds currently leave the legacy PTC pc/sp offset
    // fields unset. For x86-64 CPUX86State, regs[16] starts at env+0 and eip
    // follows it at env+128.
    Result.PC = 128;
    Result.SP = static_cast<intptr_t>(R_ESP) * 8;
    errs() << "runnable-lift: using QEMU v2 x86_64 CPUState offset fallback"
           << " pc=" << Result.PC
           << " sp=" << Result.SP << "\n";
  }

  return Result;
}

static intptr_t
getEffectiveExceptionIndexOffset(const Architecture &Arch,
                                 const VariableManager &Variables) {
  intptr_t Result = ptc.exception_index;

  if (ptc_compat::isPTCAbiV2()
      && Arch.type() == Triple::x86_64
      && Result == 0) {
    // QEMU v2 sidecar builds can leave the legacy exception_index offset
    // unset. The linked x86_64 linux-user helpers write CPUState::exception_index
    // before entering cpu_loop; map that CPUState field to the same CSV global
    // that CpuLoopFunctionPass makes cpu_loop read.
    static constexpr intptr_t CPUStateExceptionIndexOffset = 44;
    Result = CPUStateExceptionIndexOffset
             - static_cast<intptr_t>(Variables.envOffset());
    errs() << "runnable-lift: using QEMU v2 x86_64 CPUState "
           << "exception_index offset fallback exception_index="
           << Result << "\n";
  }

  return Result;
}

static int getEffectiveSyscallExceptionCode(const Architecture &Arch) {
  if (ptc_compat::isPTCAbiV2() && Arch.type() == Triple::x86_64)
    return 0x101;
  return 0x100;
}

static void promoteQEMUV2HelperAllocas(Module &M) {
  legacy::PassManager HelperPM;
  HelperPM.add(createPromoteMemoryToRegisterPass());
  HelperPM.run(M);
}

static uint64_t canonicalizePTCDebugPC(uint64_t RawPC,
                                       const BinaryFile &Binary) {
  if (Binary.getAddressData(RawPC))
    return RawPC;

  const uint64_t Base = Binary.baseAddress();
  if (Base == 0 || RawPC >= Base)
    return RawPC;

  uint64_t RelocatedPC = RawPC + Base;
  if (!Binary.getAddressData(RelocatedPC))
    return RawPC;

  return RelocatedPC;
}

static void replacePlaceholder(std::string &Target,
                               StringRef Search,
                               StringRef Replacement) {
  size_t Position = Target.find(Search.str());
  runnable_assert(Position != std::string::npos);
  Target.replace(Position, Search.size(), Replacement.str());
}

static __attribute__((unused)) void
emitSerializeAndJumpToPC(IRBuilder<> &Builder,
                         Module &M,
                         const Architecture &Arch,
                         Value *PCReg) {
  Type *RegisterType = cast<GlobalVariable>(PCReg)->getValueType();
  auto *AsmFunctionType =
    FunctionType::get(Type::getVoidTy(M.getContext()),
                      { RegisterType->getPointerTo() },
                      false);

  for (const ABIRegister &Register : Arch.abiRegisters()) {
    GlobalVariable *CSV = M.getGlobalVariable(Register.qemuName());
    if (CSV == nullptr)
      continue;

    std::string AsmString = Arch.writeRegisterAsm().str();
    replacePlaceholder(AsmString, "REGISTER", Register.name());
    std::stringstream ConstraintString;
    ConstraintString << "*m,~{" << Register.name().str()
                     << "},~{dirflag},~{fpsr},~{flags}";
    InlineAsm *Asm = InlineAsm::get(AsmFunctionType,
                                    AsmString,
                                    ConstraintString.str(),
                                    true,
                                    InlineAsm::AsmDialect::AD_ATT);
    Builder.CreateCall(Asm, CSV);
  }

  InlineAsm *JumpAsm = InlineAsm::get(AsmFunctionType,
                                      Arch.jumpAsm(),
                                      "*m,~{dirflag},~{fpsr},~{flags}",
                                      true,
                                      InlineAsm::AsmDialect::AD_ATT);
  Builder.CreateCall(JumpAsm, PCReg);
  Builder.CreateUnreachable();
}

static void printPTCAbiMetadataBoundary() {
  const bool EmptyStub = RunnablePTCAbiMetadata.HasStubKind
                         && RunnablePTCAbiMetadata.StubKind == "empty_stub";
  const bool RealTranslationMissing =
    RunnablePTCAbiMetadata.HasRealTranslation
    && !RunnablePTCAbiMetadata.RealTranslation;

  if (!RunnablePTCAbiMetadata.Present
      || (!EmptyStub && !RealTranslationMissing))
    return;

  errs() << "runnable-lift: PTC ABI metadata confirms empty stub / "
         << "real translation not migrated";
  if (RunnablePTCAbiMetadata.HasAbiVersion)
    errs() << " abi_version=" << RunnablePTCAbiMetadata.AbiVersion;
  if (RunnablePTCAbiMetadata.HasStubKind)
    errs() << " stub_kind=" << RunnablePTCAbiMetadata.StubKind;
  if (RunnablePTCAbiMetadata.HasRealTranslation)
    errs() << " real_translation="
           << (RunnablePTCAbiMetadata.RealTranslation ? "true" : "false");
  if (RunnablePTCAbiMetadata.HasVectorSchema)
    errs() << " vector_schema="
           << (RunnablePTCAbiMetadata.VectorSchema ? "true" : "false");
  errs() << "\n";
}

static bool shouldSerializePTCTranslate() {
  return RunnablePTCAbiMetadata.HasAbiVersion
         && RunnablePTCAbiMetadata.AbiVersion >= 2
         && RunnablePTCAbiMetadata.HasRealTranslation
         && RunnablePTCAbiMetadata.RealTranslation;
}

class ScopedPTCTranslateLock {
public:
  explicit ScopedPTCTranslateLock(bool Enabled) {
    if (!Enabled)
      return;

    FD = open("/tmp/runnable-lift-qemu-v2-sidecar.lock",
              O_CREAT | O_RDWR,
              0600);
    if (FD < 0) {
      errs() << "runnable-lift: warning: failed to open QEMU v2 sidecar lock\n";
      return;
    }

    while (flock(FD, LOCK_EX) != 0) {
      if (errno == EINTR)
        continue;
      errs() << "runnable-lift: warning: failed to acquire QEMU v2 sidecar lock\n";
      close(FD);
      FD = -1;
      return;
    }
    Locked = true;
  }

  ~ScopedPTCTranslateLock() {
    if (FD < 0)
      return;
    if (Locked)
      flock(FD, LOCK_UN);
    close(FD);
  }

  ScopedPTCTranslateLock(const ScopedPTCTranslateLock &) = delete;
  ScopedPTCTranslateLock &operator=(const ScopedPTCTranslateLock &) = delete;

private:
  int FD = -1;
  bool Locked = false;
};

static bool isEmptyPTCInstructionList(size_t ConsumedSize,
                                      const PTCInstructionList *Instructions) {
  return ConsumedSize == 0
         || Instructions == nullptr
         || Instructions->instruction_count == 0
         || Instructions->instructions == nullptr;
}

static bool findFirstDebugPC(const PTCInstructionList *Instructions,
                             uint64_t &PC) {
  if (Instructions == nullptr || Instructions->instructions == nullptr)
    return false;

  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    const PTCInstruction &Instruction = Instructions->instructions[I];
    if (Instruction.opc == PTC_INSTRUCTION_op_debug_insn_start) {
      PC = Instruction.args[0];
      return true;
    }
  }

  return false;
}

static bool getConstTempValue(const PTCInstructionList *Instructions,
                              PTCInstructionArg TempId,
                              uint64_t &Value) {
  if (Instructions == nullptr || Instructions->temps == nullptr)
    return false;
  if (TempId >= Instructions->total_temps)
    return false;

  const PTCTemp &Temp = Instructions->temps[TempId];
  if (Temp.val_type != PTC_TEMP_VAL_CONST) {
    if (!ptc_compat::isPTCAbiV2()
        || TempId < Instructions->global_temps
        || !Temp.temp_allocated
        || Temp.fixed_reg)
      return false;
  }

  Value = Temp.val;
  return true;
}

static void invalidatePTCOutputs(const PTCInstructionList *Instructions,
                                 PTCInstruction &Instruction,
                                 std::vector<std::pair<bool, uint64_t>> &Consts) {
  unsigned OutCount = ptc_instruction_out_arg_count(&ptc, &Instruction);
  for (unsigned I = 0; I < OutCount; I++) {
    PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, I);
    if (Out < Instructions->total_temps)
      Consts[Out].first = false;
  }
}

static bool getKnownPTCTempValue(const PTCInstructionList *Instructions,
                                 const std::vector<std::pair<bool, uint64_t>> &Consts,
                                 PTCInstructionArg TempId,
                                 uint64_t &Value) {
  if (Instructions == nullptr || TempId >= Instructions->total_temps)
    return false;
  if (!Consts[TempId].first)
    return false;

  Value = Consts[TempId].second;
  return true;
}

static bool getQEMUV2GPRIndex(StringRef Name, unsigned &Index) {
  struct RegisterBinding {
    const char *Name;
    unsigned Index;
  };

  static const RegisterBinding Bindings[] = {
    { "rax", R_EAX }, { "rcx", R_ECX }, { "rdx", R_EDX },
    { "rbx", R_EBX }, { "rsp", R_ESP }, { "rbp", R_EBP },
    { "rsi", R_ESI }, { "rdi", R_EDI }, { "r8", R_8 },
    { "r9", R_9 }, { "r10", R_10 }, { "r11", R_11 },
    { "r12", R_12 }, { "r13", R_13 }, { "r14", R_14 },
    { "r15", R_15 },
    { "eax", R_EAX }, { "ecx", R_ECX }, { "edx", R_EDX },
    { "ebx", R_EBX }, { "esp", R_ESP }, { "ebp", R_EBP },
    { "esi", R_ESI }, { "edi", R_EDI },
  };

  for (const RegisterBinding &Binding : Bindings) {
    if (Name == Binding.Name) {
      Index = Binding.Index;
      return true;
    }
  }

  return false;
}

static bool getQEMUV2RuntimeGPRValue(StringRef Name, uint64_t &Value) {
  if (!ptc_compat::isPTCAbiV2() || ptc.regs == nullptr)
    return false;

  unsigned Index = 0;
  if (!getQEMUV2GPRIndex(Name, Index))
    return false;

  Value = ptc.regs[Index];
  return true;
}

static bool getQEMUV2RuntimeGlobalTempValue(const PTCInstructionList *Instructions,
                                            PTCInstructionArg TempId,
                                            uint64_t &Value) {
  if (!ptc_compat::isPTCAbiV2()
      || Instructions == nullptr
      || Instructions->temps == nullptr
      || TempId >= Instructions->total_temps
      || TempId >= Instructions->global_temps)
    return false;

  const PTCTemp &Temp = Instructions->temps[TempId];
  StringRef Name(Temp.name != nullptr ? Temp.name : "");
  return getQEMUV2RuntimeGPRValue(Name, Value);
}

static bool getQEMUV2GPRTempIndex(const PTCInstructionList *Instructions,
                                  PTCInstructionArg TempId,
                                  unsigned &Index) {
  if (!ptc_compat::isPTCAbiV2()
      || Instructions == nullptr
      || Instructions->temps == nullptr
      || TempId >= Instructions->total_temps
      || TempId >= Instructions->global_temps)
    return false;

  const PTCTemp &Temp = Instructions->temps[TempId];
  StringRef Name(Temp.name != nullptr ? Temp.name : "");
  return getQEMUV2GPRIndex(Name, Index);
}

struct QEMUV2KnownValue {
  bool Known = false;
  uint64_t Value = 0;
  bool MemoryDerived = false;
  bool IsConstant = false;
  bool HasAddressBaseId = false;
  uint64_t AddressBaseId = 0;
  bool HasAddressFieldOffset = false;
  uint64_t AddressFieldOffset = 0;
  bool HasScaledIndex = false;
  uint64_t ScaledIndexScale = 0;
  bool HasJumpTableBase = false;
  uint64_t JumpTableBase = 0;
  uint64_t JumpTableStride = 0;
  bool HasMemorySource = false;
  uint64_t MemorySourceAddress = 0;
  bool HasMemorySourceFieldOffset = false;
  uint64_t MemorySourceFieldOffset = 0;
  bool HasMemorySourceJumpTableBase = false;
  uint64_t MemorySourceJumpTableBase = 0;
  uint64_t MemorySourceJumpTableStride = 0;
  unsigned MemoryLoadBytes = 0;
};

using QEMUV2ConcreteFunctionPointerWrites = std::map<uint64_t, uint64_t>;
using QEMUV2SymbolicFunctionPointerWrites =
  std::map<std::pair<uint64_t, uint64_t>, uint64_t>;

static bool hasQEMUV2TrackedShape(const QEMUV2KnownValue &Value) {
  return Value.Known
         || Value.MemoryDerived
         || Value.IsConstant
         || Value.HasAddressBaseId
         || Value.HasAddressFieldOffset
         || Value.HasScaledIndex
         || Value.HasJumpTableBase
         || Value.HasMemorySource
         || Value.HasMemorySourceFieldOffset
         || Value.HasMemorySourceJumpTableBase;
}

static QEMUV2KnownValue makeQEMUV2Constant(uint64_t Value) {
  QEMUV2KnownValue Result;
  Result.Known = true;
  Result.Value = Value;
  Result.IsConstant = true;
  return Result;
}

static QEMUV2KnownValue makeQEMUV2Known(uint64_t Value) {
  QEMUV2KnownValue Result;
  Result.Known = true;
  Result.Value = Value;
  return Result;
}

static void seedQEMUV2TempConstants(const PTCInstructionList *Instructions,
                                    std::vector<std::pair<bool, uint64_t>> &Consts) {
  if (Instructions == nullptr)
    return;

  Consts.assign(Instructions->total_temps, std::make_pair(false, 0));
  for (unsigned I = 0; I < Instructions->total_temps; I++) {
    uint64_t Value = 0;
    if (getConstTempValue(Instructions, I, Value))
      Consts[I] = std::make_pair(true, Value);
  }
}

static void updateQEMUV2TempConstants(const PTCInstructionList *Instructions,
                                      PTCInstruction &Instruction,
                                      std::vector<std::pair<bool, uint64_t>> &Consts) {
  switch (Instruction.opc) {
  case PTC_INSTRUCTION_op_movi_i32:
  case PTC_INSTRUCTION_op_movi_i64: {
    PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
    if (Out < Instructions->total_temps) {
      uint64_t Value = ptc_instruction_const_arg(&ptc, &Instruction, 0);
      Consts[Out] = std::make_pair(true, Value);
    }
    return;
  }
  case PTC_INSTRUCTION_op_mov_i32:
  case PTC_INSTRUCTION_op_mov_i64: {
    PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
    PTCInstructionArg In = ptc_instruction_in_arg(&ptc, &Instruction, 0);
    if (Out >= Instructions->total_temps)
      return;

    uint64_t Value = 0;
    if (getKnownPTCTempValue(Instructions, Consts, In, Value))
      Consts[Out] = std::make_pair(true, Value);
    else
      Consts[Out].first = false;
    return;
  }
  case PTC_INSTRUCTION_op_debug_insn_start:
  case PTC_INSTRUCTION_op_discard:
  case PTC_INSTRUCTION_op_qemu_st_i32:
  case PTC_INSTRUCTION_op_qemu_st_i64:
  case PTC_INSTRUCTION_op_call:
  case PTC_INSTRUCTION_op_br:
  case PTC_INSTRUCTION_op_brcond_i32:
  case PTC_INSTRUCTION_op_brcond_i64:
  case PTC_INSTRUCTION_op_exit_tb:
  case PTC_INSTRUCTION_op_goto_tb:
  case PTC_INSTRUCTION_op_set_label:
    return;
  default:
    invalidatePTCOutputs(Instructions, Instruction, Consts);
    return;
  }
}

static uint64_t qemuV2MaskBits(unsigned Bits) {
  if (Bits >= 64)
    return ~0ULL;
  return (1ULL << Bits) - 1;
}

static uint64_t qemuV2Truncate(uint64_t Value, unsigned Bits) {
  return Value & qemuV2MaskBits(Bits);
}

static uint64_t qemuV2SignExtend(uint64_t Value, unsigned Bits) {
  uint64_t Mask = qemuV2MaskBits(Bits);
  uint64_t Sign = 1ULL << (Bits - 1);
  Value &= Mask;
  return (Value ^ Sign) - Sign;
}

static bool qemuV2OpcodeIsI32(PTCOpcode Opcode) {
  switch (Opcode) {
  case PTC_INSTRUCTION_op_movi_i32:
  case PTC_INSTRUCTION_op_mov_i32:
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_xor_i32:
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_sar_i32:
  case PTC_INSTRUCTION_op_ext8s_i32:
  case PTC_INSTRUCTION_op_ext16s_i32:
  case PTC_INSTRUCTION_op_ext8u_i32:
  case PTC_INSTRUCTION_op_ext16u_i32:
  case PTC_INSTRUCTION_op_qemu_ld_i32:
  case PTC_INSTRUCTION_op_deposit_i32:
    return true;
  default:
    return false;
  }
}

static bool qemuV2ApplyExt(PTCOpcode Opcode, uint64_t Input, uint64_t &Result) {
  unsigned SourceBits = 0;
  bool Signed = false;
  switch (Opcode) {
  case PTC_INSTRUCTION_op_ext8s_i32:
  case PTC_INSTRUCTION_op_ext8s_i64:
    SourceBits = 8;
    Signed = true;
    break;
  case PTC_INSTRUCTION_op_ext8u_i32:
  case PTC_INSTRUCTION_op_ext8u_i64:
    SourceBits = 8;
    break;
  case PTC_INSTRUCTION_op_ext16s_i32:
  case PTC_INSTRUCTION_op_ext16s_i64:
    SourceBits = 16;
    Signed = true;
    break;
  case PTC_INSTRUCTION_op_ext16u_i32:
  case PTC_INSTRUCTION_op_ext16u_i64:
    SourceBits = 16;
    break;
  case PTC_INSTRUCTION_op_ext32s_i64:
    SourceBits = 32;
    Signed = true;
    break;
  case PTC_INSTRUCTION_op_ext32u_i64:
    SourceBits = 32;
    break;
  default:
    return false;
  }

  Result = Signed ? qemuV2SignExtend(Input, SourceBits)
                  : qemuV2Truncate(Input, SourceBits);
  if (qemuV2OpcodeIsI32(Opcode))
    Result = qemuV2Truncate(Result, 32);
  return true;
}

static bool qemuV2ApplyBinary(PTCOpcode Opcode,
                              uint64_t LHS,
                              uint64_t RHS,
                              uint64_t &Result) {
  unsigned Bits = qemuV2OpcodeIsI32(Opcode) ? 32 : 64;
  uint64_t Mask = qemuV2MaskBits(Bits);
  LHS &= Mask;
  RHS &= Mask;

  switch (Opcode) {
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_add_i64:
    Result = LHS + RHS;
    break;
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_sub_i64:
    Result = LHS - RHS;
    break;
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_mul_i64:
    Result = LHS * RHS;
    break;
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_and_i64:
    Result = LHS & RHS;
    break;
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_or_i64:
    Result = LHS | RHS;
    break;
  case PTC_INSTRUCTION_op_xor_i32:
  case PTC_INSTRUCTION_op_xor_i64:
    Result = LHS ^ RHS;
    break;
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shl_i64:
    Result = LHS << (RHS & (Bits - 1));
    break;
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_shr_i64:
    Result = LHS >> (RHS & (Bits - 1));
    break;
  case PTC_INSTRUCTION_op_sar_i32:
    Result = static_cast<uint32_t>(
      static_cast<int32_t>(LHS) >> (RHS & 31));
    break;
  case PTC_INSTRUCTION_op_sar_i64:
    Result = static_cast<uint64_t>(
      static_cast<int64_t>(LHS) >> (RHS & 63));
    break;
  default:
    return false;
  }

  Result &= Mask;
  return true;
}

static bool qemuV2ApplyDeposit(PTCOpcode Opcode,
                               uint64_t Base,
                               uint64_t Insert,
                               unsigned Position,
                               unsigned Length,
                               uint64_t &Result) {
  unsigned Bits = qemuV2OpcodeIsI32(Opcode) ? 32 : 64;
  if (Position >= Bits || Length > Bits || Position + Length > Bits)
    return false;

  uint64_t FieldMask =
    Length == 64 ? ~0ULL : ((1ULL << Length) - 1);
  uint64_t Mask = qemuV2MaskBits(Bits);
  uint64_t ShiftedMask = (FieldMask << Position) & Mask;
  Result = (Base & ~ShiftedMask) | ((Insert & FieldMask) << Position);
  Result &= Mask;
  return true;
}

static bool getQEMUV2MemoryAccessSize(PTCLoadStoreType Type,
                                       unsigned &Size,
                                       unsigned &Bits) {
  switch (ptc_get_memory_access_size(Type)) {
  case PTC_MO_8:
    Size = 1;
    Bits = 8;
    return true;
  case PTC_MO_16:
    Size = 2;
    Bits = 16;
    return true;
  case PTC_MO_32:
    Size = 4;
    Bits = 32;
    return true;
  case PTC_MO_64:
    Size = 8;
    Bits = 64;
    return true;
  default:
    return false;
  }
}

static bool readQEMUV2ConcreteGuestLoad(const BinaryFile &Binary,
                                        uint64_t Address,
                                        PTCLoadStoreType Type,
                                        uint64_t &Value,
                                        unsigned &Bits) {
  unsigned Size = 0;
  if (!getQEMUV2MemoryAccessSize(Type, Size, Bits))
    return false;

  BinaryFile::Endianess Endian = BinaryFile::OriginalEndianess;
  if ((static_cast<unsigned>(Type) & static_cast<unsigned>(PTC_MO_BSWAP)) != 0) {
    Endian = Binary.architecture().isLittleEndian() ? BinaryFile::BigEndian
                                                    : BinaryFile::LittleEndian;
  }

  Optional<uint64_t> Read = Binary.readRawValue(Address, Size, Endian);
  if (!Read)
    return false;

  Value = qemuV2Truncate(*Read, Bits);
  if ((static_cast<unsigned>(Type) & static_cast<unsigned>(PTC_MO_SIGN)) != 0
      && Bits < 64)
    Value = qemuV2SignExtend(Value, Bits);
  return true;
}

static bool isValidQEMUV2IndirectTarget(uint64_t TargetPC,
                                        uint64_t SourcePC,
                                        JumpTargetManager &JumpTargets);

static bool addQEMUV2UniqueTarget(std::vector<uint64_t> &Targets,
                                  uint64_t Target) {
  if (std::find(Targets.begin(), Targets.end(), Target) != Targets.end())
    return false;
  Targets.push_back(Target);
  return true;
}

static bool readQEMUX86Byte(const BinaryFile &Binary,
                            uint64_t Address,
                            uint8_t &Byte) {
  Optional<uint64_t> Read = Binary.readRawValue(Address, 1);
  if (!Read)
    return false;
  Byte = static_cast<uint8_t>(*Read);
  return true;
}

static bool readQEMUX86U32(const BinaryFile &Binary,
                           uint64_t Address,
                           uint32_t &Value) {
  Optional<uint64_t> Read = Binary.readRawValue(Address, 4,
                                                BinaryFile::LittleEndian);
  if (!Read)
    return false;
  Value = static_cast<uint32_t>(*Read);
  return true;
}

static bool parseQEMUX86Scale8Disp32JumpTable(const BinaryFile &Binary,
                                              uint64_t SourcePC,
                                              uint64_t TableBase,
                                              unsigned &IndexReg) {
  if (Binary.architecture().type() != Triple::x86_64
      || !Binary.architecture().isLittleEndian())
    return false;

  uint64_t PC = SourcePC;
  uint8_t Byte = 0;
  if (!readQEMUX86Byte(Binary, PC, Byte))
    return false;

  uint8_t REX = 0;
  if (0x40 <= Byte && Byte <= 0x4f) {
    REX = Byte;
    PC++;
    if (!readQEMUX86Byte(Binary, PC, Byte))
      return false;
  }

  uint8_t ModRM = 0;
  uint8_t SIB = 0;
  uint32_t Disp32 = 0;
  if (Byte != 0xff
      || !readQEMUX86Byte(Binary, PC + 1, ModRM)
      || ModRM != 0x24
      || !readQEMUX86Byte(Binary, PC + 2, SIB)
      || !readQEMUX86U32(Binary, PC + 3, Disp32))
    return false;

  unsigned Scale = SIB >> 6;
  unsigned Index = (SIB >> 3) & 0x7;
  unsigned Base = SIB & 0x7;
  if (Scale != 3 || Index == 4 || Base != 5)
    return false;

  uint64_t DisplacementAddress =
    static_cast<uint64_t>(static_cast<int64_t>(
      static_cast<int32_t>(Disp32)));
  if (DisplacementAddress != TableBase)
    return false;

  IndexReg = Index | ((REX & 0x2) ? 8 : 0);
  return true;
}

static bool hasQEMUX86UnsignedAboveBranch(const BinaryFile &Binary,
                                          uint64_t Begin,
                                          uint64_t End) {
  for (uint64_t PC = Begin; PC < End; PC++) {
    uint8_t Byte = 0;
    if (!readQEMUX86Byte(Binary, PC, Byte))
      continue;
    if (Byte == 0x77)
      return true;
    if (Byte == 0x0f) {
      uint8_t Next = 0;
      if (readQEMUX86Byte(Binary, PC + 1, Next) && Next == 0x87)
        return true;
    }
  }
  return false;
}

static bool parseQEMUX86CmpRegImmBound(const BinaryFile &Binary,
                                       uint64_t PC,
                                       unsigned IndexReg,
                                       uint64_t End,
                                       uint64_t &CmpEnd,
                                       uint64_t &EntryCount) {
  uint8_t Byte = 0;
  if (!readQEMUX86Byte(Binary, PC, Byte))
    return false;

  uint8_t REX = 0;
  uint64_t OpcodePC = PC;
  if (0x40 <= Byte && Byte <= 0x4f) {
    REX = Byte;
    OpcodePC++;
    if (!readQEMUX86Byte(Binary, OpcodePC, Byte))
      return false;
  }

  auto MatchModRMReg = [&](uint8_t ModRM) {
    unsigned Mod = ModRM >> 6;
    unsigned Reg = (ModRM >> 3) & 0x7;
    unsigned RM = ModRM & 0x7;
    unsigned FullRM = RM | ((REX & 0x1) ? 8 : 0);
    return Mod == 3 && Reg == 7 && FullRM == IndexReg;
  };

  if (Byte == 0x83) {
    if (OpcodePC + 2 >= End)
      return false;
    uint8_t ModRM = 0;
    uint8_t Imm = 0;
    if (!readQEMUX86Byte(Binary, OpcodePC + 1, ModRM)
        || !MatchModRMReg(ModRM)
        || !readQEMUX86Byte(Binary, OpcodePC + 2, Imm))
      return false;
    int8_t SignedImm = static_cast<int8_t>(Imm);
    if (SignedImm < 0)
      return false;
    CmpEnd = OpcodePC + 3;
    EntryCount = static_cast<uint64_t>(SignedImm) + 1;
    return EntryCount != 0;
  }

  if (Byte == 0x81) {
    if (OpcodePC + 5 >= End)
      return false;
    uint8_t ModRM = 0;
    uint32_t Imm = 0;
    if (!readQEMUX86Byte(Binary, OpcodePC + 1, ModRM)
        || !MatchModRMReg(ModRM)
        || !readQEMUX86U32(Binary, OpcodePC + 2, Imm))
      return false;
    int32_t SignedImm = static_cast<int32_t>(Imm);
    if (SignedImm < 0)
      return false;
    CmpEnd = OpcodePC + 6;
    EntryCount = static_cast<uint64_t>(SignedImm) + 1;
    return EntryCount != 0;
  }

  if (Byte == 0x3d && IndexReg == 0) {
    if (OpcodePC + 4 >= End)
      return false;
    uint32_t Imm = 0;
    if (!readQEMUX86U32(Binary, OpcodePC + 1, Imm))
      return false;
    int32_t SignedImm = static_cast<int32_t>(Imm);
    if (SignedImm < 0)
      return false;
    CmpEnd = OpcodePC + 5;
    EntryCount = static_cast<uint64_t>(SignedImm) + 1;
    return EntryCount != 0;
  }

  return false;
}

static bool inferQEMUX86JumpTableEntryCount(const BinaryFile &Binary,
                                            uint64_t SourcePC,
                                            uint64_t TableBase,
                                            uint64_t &EntryCount) {
  unsigned IndexReg = 0;
  if (!parseQEMUX86Scale8Disp32JumpTable(Binary,
                                         SourcePC,
                                         TableBase,
                                         IndexReg))
    return false;

  const uint64_t WindowSize = 256;
  uint64_t WindowStart = SourcePC > WindowSize ? SourcePC - WindowSize : 0;
  bool Found = false;
  uint64_t Best = 0;
  for (uint64_t PC = WindowStart; PC < SourcePC; PC++) {
    uint64_t CmpEnd = 0;
    uint64_t CandidateCount = 0;
    if (!parseQEMUX86CmpRegImmBound(Binary,
                                    PC,
                                    IndexReg,
                                    SourcePC,
                                    CmpEnd,
                                    CandidateCount))
      continue;
    if (!hasQEMUX86UnsignedAboveBranch(Binary, CmpEnd, SourcePC))
      continue;
    Found = true;
    Best = CandidateCount;
  }

  if (!Found)
    return false;
  EntryCount = Best;
  return true;
}

static void collectQEMUV2JumpTableIndirectTargets(
  const BinaryFile &Binary,
  uint64_t TableBase,
  uint64_t Stride,
  unsigned LoadBytes,
  uint64_t SourcePC,
  JumpTargetManager &JumpTargets,
  std::vector<uint64_t> &Targets) {
  unsigned PointerBytes = Binary.architecture().pointerSize() / 8;
  if (PointerBytes == 0 || LoadBytes != PointerBytes)
    return;
  if (Stride != PointerBytes || Stride == 0)
    return;

  const SegmentInfo *TableSegment = nullptr;
  for (const SegmentInfo &Segment : Binary.segments()) {
    if (Segment.contains(TableBase, LoadBytes)) {
      TableSegment = &Segment;
      break;
    }
  }
  if (TableSegment == nullptr
      || !TableSegment->IsReadable
      || TableSegment->IsWriteable)
    return;

  bool InReadOnlyDataRange =
    Binary.rodataStartAddr != 0
    && Binary.ehframeEndAddr != 0
    && Binary.rodataStartAddr <= TableBase
    && TableBase < Binary.ehframeEndAddr;
  if (TableSegment->IsExecutable && !InReadOnlyDataRange)
    return;

  // Some static x86 binaries place .rodata jump tables in the same read/execute
  // PT_LOAD as .text. Treat the table as data if the base has backing bytes and
  // has not already been identified as a code frontier; every entry is still
  // validated as an executable target below.
  if (JumpTargets.isJumpTarget(TableBase))
    return;
  if (!Binary.readRawValue(TableBase, PointerBytes))
    return;

  const size_t DefaultMaxEntries = 64;
  uint64_t InferredEntryCount = 0;
  size_t MaxEntries = DefaultMaxEntries;
  if (inferQEMUX86JumpTableEntryCount(Binary,
                                      SourcePC,
                                      TableBase,
                                      InferredEntryCount))
    MaxEntries = std::min<uint64_t>(InferredEntryCount, DefaultMaxEntries);
  unsigned ConsecutiveInvalid = 0;
  for (size_t Entry = 0;
       Entry < MaxEntries && ConsecutiveInvalid < 4;
       Entry++) {
    uint64_t CandidateAddress = TableBase + Entry * Stride;
    if (!TableSegment->contains(CandidateAddress, LoadBytes))
      break;

    Optional<uint64_t> Read =
      Binary.readRawValue(CandidateAddress, PointerBytes);
    if (!Read)
      break;

    uint64_t CandidatePC = *Read;
    if (!isValidQEMUV2IndirectTarget(CandidatePC, SourcePC, JumpTargets)) {
      ConsecutiveInvalid++;
      continue;
    }

    ConsecutiveInvalid = 0;
    addQEMUV2UniqueTarget(Targets, CandidatePC);
  }
}

static void collectQEMUV2DataFieldIndirectTargets(
  const BinaryFile &Binary,
  uint64_t LoadAddress,
  uint64_t FieldOffset,
  unsigned LoadBytes,
  uint64_t SourcePC,
  JumpTargetManager &JumpTargets,
  std::vector<uint64_t> &Targets) {
  unsigned PointerBytes = Binary.architecture().pointerSize() / 8;
  if (PointerBytes == 0 || LoadBytes != PointerBytes)
    return;
  if (FieldOffset > 0x1000 || LoadAddress < FieldOffset)
    return;

  const SegmentInfo *SourceSegment = nullptr;
  for (const SegmentInfo &Segment : Binary.segments()) {
    if (Segment.contains(LoadAddress, LoadBytes)) {
      SourceSegment = &Segment;
      break;
    }
  }
  if (SourceSegment == nullptr
      || !SourceSegment->IsReadable
      || !SourceSegment->IsWriteable
      || SourceSegment->IsExecutable)
    return;

  uint64_t SourceBase = LoadAddress - FieldOffset;
  if (!SourceSegment->contains(SourceBase))
    return;

  const size_t MaxTargets = 32;
  for (size_t Offset = 0;
       Offset + PointerBytes <= SourceSegment->Data.size()
       && Targets.size() < MaxTargets;
       Offset++) {
    uint64_t CandidateAddress = SourceSegment->StartVirtualAddress + Offset;
    if ((CandidateAddress % PointerBytes) != 0)
      continue;
    if (CandidateAddress < FieldOffset)
      continue;

    uint64_t CandidateBase = CandidateAddress - FieldOffset;
    if (!SourceSegment->contains(CandidateBase))
      continue;
    if ((CandidateBase % PointerBytes) != 0)
      continue;

    Optional<uint64_t> Read =
      Binary.readRawValue(CandidateAddress, PointerBytes);
    if (!Read)
      continue;

    uint64_t CandidatePC = *Read;
    if (!isValidQEMUV2IndirectTarget(CandidatePC, SourcePC, JumpTargets))
      continue;

    addQEMUV2UniqueTarget(Targets, CandidatePC);
  }
}

static bool isQEMUV2PCTemp(const PTCInstructionList *Instructions,
                           PTCInstructionArg TempId);

static bool isValidQEMUV2IndirectTarget(uint64_t TargetPC,
                                        uint64_t SourcePC,
                                        JumpTargetManager &JumpTargets);

static bool updateQEMUV2CSVConstantState(
  const PTCInstructionList *Instructions,
  std::vector<QEMUV2KnownValue> &KnownGPRs,
  QEMUV2ConcreteFunctionPointerWrites &ConcreteFunctionPointerWrites,
  QEMUV2SymbolicFunctionPointerWrites &SymbolicFunctionPointerWrites,
  uint64_t VirtualAddress,
  JumpTargetManager &JumpTargets,
  uint64_t &IndirectTargetPC,
  bool &IndirectTargetFromMemory,
  std::vector<uint64_t> &AdditionalDataFieldTargets,
  std::vector<uint64_t> &AdditionalJumpTableTargets,
  std::vector<uint64_t> &AdditionalFunctionPointerStoreTargets) {
  if (!ptc_compat::isPTCAbiV2()
      || Instructions == nullptr
      || Instructions->instructions == nullptr
      || Instructions->temps == nullptr)
    return false;

  std::vector<QEMUV2KnownValue> Values(Instructions->total_temps);
  for (unsigned I = 0; I < Instructions->total_temps; I++) {
    unsigned GPRIndex = 0;
    uint64_t ConstValue = 0;
    if (getQEMUV2GPRTempIndex(Instructions, I, GPRIndex)) {
      if (GPRIndex < KnownGPRs.size()
          && hasQEMUV2TrackedShape(KnownGPRs[GPRIndex])) {
        Values[I] = KnownGPRs[GPRIndex];
      } else {
        QEMUV2KnownValue Base;
        Base.HasAddressBaseId = true;
        Base.AddressBaseId = static_cast<uint64_t>(GPRIndex) + 1;
        Values[I] = Base;
      }
    } else if (getConstTempValue(Instructions, I, ConstValue)) {
      Values[I] = makeQEMUV2Constant(ConstValue);
    }
  }

  bool FoundTarget = false;
  bool FoundTargetFromMemory = false;
  uint64_t Candidate = 0;
  auto Invalidate = [&](PTCInstructionArg Out) {
    if (Out >= Values.size())
      return;
    Values[Out] = {};
    unsigned GPRIndex = 0;
    if (getQEMUV2GPRTempIndex(Instructions, Out, GPRIndex)
        && GPRIndex < KnownGPRs.size())
      KnownGPRs[GPRIndex] = {};
  };

  auto RememberPCTarget = [&](PTCInstructionArg Out,
                              const QEMUV2KnownValue &Value) {
    if (!isQEMUV2PCTemp(Instructions, Out))
      return;

    if (Value.MemoryDerived
        && Value.HasMemorySourceJumpTableBase) {
      collectQEMUV2JumpTableIndirectTargets(
        JumpTargets.binary(),
        Value.MemorySourceJumpTableBase,
        Value.MemorySourceJumpTableStride,
        Value.MemoryLoadBytes,
        VirtualAddress,
        JumpTargets,
        AdditionalJumpTableTargets);
    }

    if (!Value.Known
        || !isValidQEMUV2IndirectTarget(Value.Value,
                                        VirtualAddress,
                                        JumpTargets))
      return;

    Candidate = Value.Value;
    FoundTargetFromMemory = Value.MemoryDerived;
    FoundTarget = true;

    if (Value.MemoryDerived
        && Value.HasMemorySource
        && Value.HasMemorySourceFieldOffset) {
      collectQEMUV2DataFieldIndirectTargets(
        JumpTargets.binary(),
        Value.MemorySourceAddress,
        Value.MemorySourceFieldOffset,
        Value.MemoryLoadBytes,
        VirtualAddress,
        JumpTargets,
        AdditionalDataFieldTargets);
    }

    if (Value.MemoryDerived
        && Value.HasMemorySource
        && Value.HasMemorySourceJumpTableBase) {
      collectQEMUV2JumpTableIndirectTargets(
        JumpTargets.binary(),
        Value.MemorySourceJumpTableBase,
        Value.MemorySourceJumpTableStride,
        Value.MemoryLoadBytes,
        VirtualAddress,
        JumpTargets,
        AdditionalJumpTableTargets);
    }
  };

  auto SetValue = [&](PTCInstructionArg Out,
                      QEMUV2KnownValue Value,
                      unsigned Bits,
                      bool UpdateGPR = true) {
    if (Out >= Values.size())
      return;
    Value.Value = qemuV2Truncate(Value.Value, Bits);
    Values[Out] = Value;

    unsigned GPRIndex = 0;
    if (UpdateGPR
        && getQEMUV2GPRTempIndex(Instructions, Out, GPRIndex)
        && GPRIndex < KnownGPRs.size()) {
      if (hasQEMUV2TrackedShape(Values[Out]))
        KnownGPRs[GPRIndex] = Values[Out];
      else
        KnownGPRs[GPRIndex] = {};
    }

    RememberPCTarget(Out, Values[Out]);
  };

  auto Assign = [&](PTCInstructionArg Out,
                    uint64_t Value,
                    unsigned Bits,
                    bool MemoryDerived = false,
                    bool UpdateGPR = true,
                    bool IsConstant = false) {
    QEMUV2KnownValue Known = makeQEMUV2Known(Value);
    Known.MemoryDerived = MemoryDerived;
    Known.IsConstant = IsConstant;
    SetValue(Out, Known, Bits, UpdateGPR);
  };

  auto Get = [&](PTCInstructionArg In, uint64_t &Value) {
    if (In >= Values.size() || !Values[In].Known)
      return false;
    Value = Values[In].Value;
    return true;
  };

  auto GetKnown = [&](PTCInstructionArg In, QEMUV2KnownValue &Value) {
    if (In >= Values.size() || !Values[In].Known)
      return false;
    Value = Values[In];
    return true;
  };

  auto GetTracked = [&](PTCInstructionArg In, QEMUV2KnownValue &Value) {
    if (In >= Values.size())
      return false;
    Value = Values[In];
    return true;
  };

  auto InvalidateOutputs = [&](PTCInstruction &Instruction) {
    unsigned OutCount = ptc_instruction_out_arg_count(&ptc, &Instruction);
    for (unsigned I = 0; I < OutCount; I++)
      Invalidate(ptc_instruction_out_arg(&ptc, &Instruction, I));
  };

  unsigned PointerBytes = JumpTargets.binary().architecture().pointerSize() / 8;

  auto GetSymbolicFieldKey =
    [&](const QEMUV2KnownValue &Address,
        std::pair<uint64_t, uint64_t> &Key) {
      if (!Address.HasAddressBaseId)
        return false;
      uint64_t Offset = Address.HasAddressFieldOffset ?
                        Address.AddressFieldOffset : 0;
      if (Offset > 0x1000)
        return false;
      Key = std::make_pair(Address.AddressBaseId, Offset);
      return true;
    };

  auto ForgetShadowedFunctionPointer = [&](const QEMUV2KnownValue &Address) {
    if (Address.Known)
      ConcreteFunctionPointerWrites.erase(Address.Value);
    std::pair<uint64_t, uint64_t> Key;
    if (GetSymbolicFieldKey(Address, Key))
      SymbolicFunctionPointerWrites.erase(Key);
  };

  auto RememberShadowedFunctionPointer =
    [&](const QEMUV2KnownValue &Address, uint64_t TargetPC) {
      if (Address.Known)
        ConcreteFunctionPointerWrites[Address.Value] = TargetPC;
      std::pair<uint64_t, uint64_t> Key;
      if (GetSymbolicFieldKey(Address, Key))
        SymbolicFunctionPointerWrites[Key] = TargetPC;
    };

  auto ReadShadowedFunctionPointer =
    [&](const QEMUV2KnownValue &Address, uint64_t &TargetPC) {
      if (Address.Known) {
        auto It = ConcreteFunctionPointerWrites.find(Address.Value);
        if (It != ConcreteFunctionPointerWrites.end()) {
          TargetPC = It->second;
          return true;
        }
      }
      std::pair<uint64_t, uint64_t> Key;
      if (!GetSymbolicFieldKey(Address, Key))
        return false;
      auto It = SymbolicFunctionPointerWrites.find(Key);
      if (It == SymbolicFunctionPointerWrites.end())
        return false;
      TargetPC = It->second;
      return true;
    };

  auto IsLikelyFunctionPointerStoreAddress =
    [&](const QEMUV2KnownValue &Address) {
      if (Address.HasAddressBaseId
          && Address.HasAddressFieldOffset
          && Address.AddressFieldOffset <= 0x1000) {
        // Do not turn ordinary call stack pushes into indirect-call frontiers.
        return Address.AddressBaseId != static_cast<uint64_t>(R_ESP) + 1;
      }

      if (!Address.Known)
        return false;
      if (!JumpTargets.isDataSegmAddr(Address.Value))
        return false;
      for (const SegmentInfo &Segment : JumpTargets.binary().segments()) {
        if (Segment.contains(Address.Value, PointerBytes))
          return Segment.IsReadable && Segment.IsWriteable
                 && !Segment.IsExecutable;
      }
      return false;
    };

  auto PropagateAddressFieldOffset = [&](PTCOpcode Opcode,
                                         const QEMUV2KnownValue &LHS,
                                         const QEMUV2KnownValue &RHS,
                                         QEMUV2KnownValue &Out) {
    auto SetFromBaseAndOffset = [&](const QEMUV2KnownValue &Base,
                                    const QEMUV2KnownValue &Offset,
                                    bool Subtract) {
      if (!Offset.IsConstant || Base.IsConstant || Offset.Value > 0x1000)
        return false;
      uint64_t BaseOffset = Base.HasAddressFieldOffset ?
                            Base.AddressFieldOffset : 0;
      if (Subtract) {
        if (Offset.Value > BaseOffset)
          return false;
        Out.AddressFieldOffset = BaseOffset - Offset.Value;
      } else {
        if (BaseOffset + Offset.Value > 0x1000)
          return false;
        Out.AddressFieldOffset = BaseOffset + Offset.Value;
      }
      Out.HasAddressBaseId = Base.HasAddressBaseId;
      Out.AddressBaseId = Base.AddressBaseId;
      Out.HasAddressFieldOffset = true;
      return true;
    };

    switch (Opcode) {
    case PTC_INSTRUCTION_op_add_i32:
    case PTC_INSTRUCTION_op_add_i64:
      if (SetFromBaseAndOffset(LHS, RHS, false))
        return;
      SetFromBaseAndOffset(RHS, LHS, false);
      return;
    case PTC_INSTRUCTION_op_sub_i32:
    case PTC_INSTRUCTION_op_sub_i64:
      SetFromBaseAndOffset(LHS, RHS, true);
      return;
    default:
      return;
    }
  };

  auto PropagateJumpTableAddress = [&](PTCOpcode Opcode,
                                       const QEMUV2KnownValue &LHS,
                                       const QEMUV2KnownValue &RHS,
                                       QEMUV2KnownValue &Out) {
    auto SetJumpTable = [&](const QEMUV2KnownValue &Base,
                            const QEMUV2KnownValue &Index) {
      if (!Base.IsConstant || !Index.HasScaledIndex)
        return false;
      if (!JumpTargets.binary().getAddressData(Base.Value))
        return false;
      Out.HasJumpTableBase = true;
      Out.JumpTableBase = Base.Value;
      Out.JumpTableStride = Index.ScaledIndexScale;
      return true;
    };

    switch (Opcode) {
    case PTC_INSTRUCTION_op_shl_i32:
    case PTC_INSTRUCTION_op_shl_i64:
      if (RHS.IsConstant
          && RHS.Value < 16) {
        Out.HasScaledIndex = true;
        Out.ScaledIndexScale = 1ULL << RHS.Value;
      }
      return;
    case PTC_INSTRUCTION_op_add_i32:
    case PTC_INSTRUCTION_op_add_i64:
      if (SetJumpTable(LHS, RHS))
        return;
      SetJumpTable(RHS, LHS);
      return;
    default:
      return;
    }
  };

  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    PTCInstruction &Instruction = Instructions->instructions[I];
    PTCOpcode Opcode = Instruction.opc;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_movi_i32:
    case PTC_INSTRUCTION_op_movi_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      uint64_t Value = ptc_instruction_const_arg(&ptc, &Instruction, 0);
      Assign(Out, Value, qemuV2OpcodeIsI32(Opcode) ? 32 : 64,
             false, true, true);
      break;
    }
    case PTC_INSTRUCTION_op_mov_i32:
    case PTC_INSTRUCTION_op_mov_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg In = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      QEMUV2KnownValue Value;
      if (GetTracked(In, Value) && hasQEMUV2TrackedShape(Value))
        SetValue(Out,
                 Value,
                 qemuV2OpcodeIsI32(Opcode) ? 32 : 64);
      else
        Invalidate(Out);
      break;
    }
    case PTC_INSTRUCTION_op_ext8s_i32:
    case PTC_INSTRUCTION_op_ext16s_i32:
    case PTC_INSTRUCTION_op_ext8u_i32:
    case PTC_INSTRUCTION_op_ext16u_i32:
    case PTC_INSTRUCTION_op_ext8s_i64:
    case PTC_INSTRUCTION_op_ext16s_i64:
    case PTC_INSTRUCTION_op_ext32s_i64:
    case PTC_INSTRUCTION_op_ext8u_i64:
    case PTC_INSTRUCTION_op_ext16u_i64:
    case PTC_INSTRUCTION_op_ext32u_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg In = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      QEMUV2KnownValue Input;
      uint64_t Result = 0;
      if (GetKnown(In, Input) && qemuV2ApplyExt(Opcode, Input.Value, Result)) {
        QEMUV2KnownValue OutValue = makeQEMUV2Known(Result);
        OutValue.MemoryDerived = Input.MemoryDerived;
        OutValue.IsConstant = Input.IsConstant;
        SetValue(Out, OutValue, qemuV2OpcodeIsI32(Opcode) ? 32 : 64);
      } else {
        Invalidate(Out);
      }
      break;
    }
    case PTC_INSTRUCTION_op_add_i32:
    case PTC_INSTRUCTION_op_sub_i32:
    case PTC_INSTRUCTION_op_mul_i32:
    case PTC_INSTRUCTION_op_and_i32:
    case PTC_INSTRUCTION_op_or_i32:
    case PTC_INSTRUCTION_op_xor_i32:
    case PTC_INSTRUCTION_op_shl_i32:
    case PTC_INSTRUCTION_op_shr_i32:
    case PTC_INSTRUCTION_op_sar_i32:
    case PTC_INSTRUCTION_op_add_i64:
    case PTC_INSTRUCTION_op_sub_i64:
    case PTC_INSTRUCTION_op_mul_i64:
    case PTC_INSTRUCTION_op_and_i64:
    case PTC_INSTRUCTION_op_or_i64:
    case PTC_INSTRUCTION_op_xor_i64:
    case PTC_INSTRUCTION_op_shl_i64:
    case PTC_INSTRUCTION_op_shr_i64:
    case PTC_INSTRUCTION_op_sar_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg LHSArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      PTCInstructionArg RHSArg = ptc_instruction_in_arg(&ptc, &Instruction, 1);
      QEMUV2KnownValue LHS;
      QEMUV2KnownValue RHS;
      uint64_t Result = 0;
      if (GetTracked(LHSArg, LHS) && GetTracked(RHSArg, RHS)) {
        QEMUV2KnownValue OutValue;
        if (LHS.Known && RHS.Known
            && qemuV2ApplyBinary(Opcode, LHS.Value, RHS.Value, Result)) {
          OutValue = makeQEMUV2Known(Result);
          OutValue.MemoryDerived = LHS.MemoryDerived || RHS.MemoryDerived;
          OutValue.IsConstant = LHS.IsConstant && RHS.IsConstant;
        }
        PropagateAddressFieldOffset(Opcode, LHS, RHS, OutValue);
        PropagateJumpTableAddress(Opcode, LHS, RHS, OutValue);
        if (!hasQEMUV2TrackedShape(OutValue)) {
          Invalidate(Out);
          break;
        }
        SetValue(Out,
                 OutValue,
                 qemuV2OpcodeIsI32(Opcode) ? 32 : 64);
      } else {
        Invalidate(Out);
      }
      break;
    }
    case PTC_INSTRUCTION_op_deposit_i32:
    case PTC_INSTRUCTION_op_deposit_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg BaseArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      PTCInstructionArg InsertArg = ptc_instruction_in_arg(&ptc, &Instruction, 1);
      uint64_t Base = 0;
      uint64_t Insert = 0;
      uint64_t Result = 0;
      unsigned Position = ptc_instruction_const_arg(&ptc, &Instruction, 0);
      unsigned Length = ptc_instruction_const_arg(&ptc, &Instruction, 1);
      if (Get(BaseArg, Base) && Get(InsertArg, Insert)
          && qemuV2ApplyDeposit(Opcode, Base, Insert, Position, Length, Result))
        Assign(Out, Result, qemuV2OpcodeIsI32(Opcode) ? 32 : 64);
      else
        Invalidate(Out);
      break;
    }
    case PTC_INSTRUCTION_op_qemu_ld_i32:
    case PTC_INSTRUCTION_op_qemu_ld_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg AddressArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      uint64_t Address = 0;
      uint64_t LoadedValue = 0;
      unsigned LoadedBits = 0;
      unsigned LoadedBytes = 0;
      PTCLoadStoreArg MemoryAccess =
        ptc_compat::parseLoadStoreArg(ptc,
                                      ptc_instruction_const_arg(&ptc,
                                                               &Instruction,
                                                               0));
      QEMUV2KnownValue AddressValue;
      bool HasMemoryAccess =
        MemoryAccess.access_type != PTC_MEMORY_ACCESS_UNKNOWN
        && GetTracked(AddressArg, AddressValue)
        && getQEMUV2MemoryAccessSize(MemoryAccess.type,
                                     LoadedBytes,
                                     LoadedBits);
      bool LoadedFromShadow = false;
      if (HasMemoryAccess
          && PointerBytes != 0
          && LoadedBytes == PointerBytes
          && ReadShadowedFunctionPointer(AddressValue, LoadedValue)) {
        LoadedBits = LoadedBytes * 8;
        LoadedFromShadow = true;
      }

      if (LoadedFromShadow) {
        unsigned ResultBits = qemuV2OpcodeIsI32(Opcode) ? 32 : 64;
        QEMUV2KnownValue OutValue = makeQEMUV2Known(LoadedValue);
        OutValue.MemoryDerived = true;
        OutValue.HasMemorySource = AddressValue.Known;
        OutValue.MemorySourceAddress = AddressValue.Value;
        OutValue.HasMemorySourceFieldOffset =
          AddressValue.HasAddressFieldOffset;
        OutValue.MemorySourceFieldOffset =
          AddressValue.AddressFieldOffset;
        OutValue.MemoryLoadBytes = LoadedBytes;
        SetValue(Out, OutValue, ResultBits, false);
      } else if (HasMemoryAccess
          && AddressValue.Known
          && (Address = AddressValue.Value, true)
          && readQEMUV2ConcreteGuestLoad(JumpTargets.binary(),
                                         Address,
                                         MemoryAccess.type,
                                         LoadedValue,
                                         LoadedBits)) {
        unsigned ResultBits = qemuV2OpcodeIsI32(Opcode) ? 32 : 64;
        QEMUV2KnownValue OutValue = makeQEMUV2Known(LoadedValue);
        OutValue.MemoryDerived = true;
        OutValue.HasMemorySource = true;
        OutValue.MemorySourceAddress = Address;
        OutValue.HasMemorySourceFieldOffset =
          AddressValue.HasAddressFieldOffset;
        OutValue.MemorySourceFieldOffset =
          AddressValue.AddressFieldOffset;
        OutValue.HasMemorySourceJumpTableBase =
          AddressValue.HasJumpTableBase;
        OutValue.MemorySourceJumpTableBase =
          AddressValue.JumpTableBase;
        OutValue.MemorySourceJumpTableStride =
          AddressValue.JumpTableStride;
        OutValue.MemoryLoadBytes = LoadedBytes;
        SetValue(Out, OutValue, ResultBits, false);
      } else if (HasMemoryAccess && AddressValue.HasJumpTableBase) {
        unsigned ResultBits = qemuV2OpcodeIsI32(Opcode) ? 32 : 64;
        QEMUV2KnownValue OutValue;
        OutValue.MemoryDerived = true;
        OutValue.HasMemorySource = AddressValue.Known;
        OutValue.MemorySourceAddress = AddressValue.Value;
        OutValue.HasMemorySourceJumpTableBase = true;
        OutValue.MemorySourceJumpTableBase = AddressValue.JumpTableBase;
        OutValue.MemorySourceJumpTableStride = AddressValue.JumpTableStride;
        OutValue.MemoryLoadBytes = LoadedBytes;
        SetValue(Out, OutValue, ResultBits, false);
      } else {
        Invalidate(Out);
      }
      break;
    }
    case PTC_INSTRUCTION_op_qemu_st_i32:
    case PTC_INSTRUCTION_op_qemu_st_i64: {
      if (ptc_instruction_in_arg_count(&ptc, &Instruction) < 2)
        break;
      PTCInstructionArg ValueArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      PTCInstructionArg AddressArg = ptc_instruction_in_arg(&ptc, &Instruction, 1);
      PTCLoadStoreArg MemoryAccess =
        ptc_compat::parseLoadStoreArg(ptc,
                                      ptc_instruction_const_arg(&ptc,
                                                               &Instruction,
                                                               0));
      unsigned StoreBytes = 0;
      unsigned StoreBits = 0;
      QEMUV2KnownValue AddressValue;
      QEMUV2KnownValue StoredValue;
      if (MemoryAccess.access_type != PTC_MEMORY_ACCESS_UNKNOWN
          && PointerBytes != 0
          && GetTracked(AddressArg, AddressValue)
          && getQEMUV2MemoryAccessSize(MemoryAccess.type,
                                       StoreBytes,
                                       StoreBits)
          && StoreBytes == PointerBytes) {
        if (GetTracked(ValueArg, StoredValue)
            && StoredValue.Known
            && isValidQEMUV2IndirectTarget(StoredValue.Value,
                                           VirtualAddress,
                                           JumpTargets)) {
          RememberShadowedFunctionPointer(AddressValue, StoredValue.Value);
          if (IsLikelyFunctionPointerStoreAddress(AddressValue))
            addQEMUV2UniqueTarget(AdditionalFunctionPointerStoreTargets,
                                  StoredValue.Value);
        } else {
          ForgetShadowedFunctionPointer(AddressValue);
        }
      }
      break;
    }
    case PTC_INSTRUCTION_op_debug_insn_start:
    case PTC_INSTRUCTION_op_discard:
    case PTC_INSTRUCTION_op_call:
    case PTC_INSTRUCTION_op_br:
    case PTC_INSTRUCTION_op_brcond_i32:
    case PTC_INSTRUCTION_op_brcond_i64:
    case PTC_INSTRUCTION_op_exit_tb:
    case PTC_INSTRUCTION_op_goto_tb:
    case PTC_INSTRUCTION_op_set_label:
      break;
    default:
      InvalidateOutputs(Instruction);
      break;
    }
  }

  if (!FoundTarget)
    return false;

  IndirectTargetPC = Candidate;
  IndirectTargetFromMemory = FoundTargetFromMemory;
  return true;
}

static bool isQEMUV2PCTemp(const PTCInstructionList *Instructions,
                           PTCInstructionArg TempId) {
  if (!ptc_compat::isPTCAbiV2()
      || Instructions == nullptr
      || Instructions->temps == nullptr
      || TempId >= Instructions->total_temps)
    return false;

  const PTCTemp &Temp = Instructions->temps[TempId];
  StringRef Name(Temp.name != nullptr ? Temp.name : "");
  return Name == "pc" || Name == "eip" || Name == "rip";
}

static bool extractQEMUV2IndirectTargetPC(const PTCInstructionList *Instructions,
                                          uint64_t VirtualAddress,
                                          JumpTargetManager &JumpTargets,
                                          uint64_t &TargetPC) {
  if (!ptc_compat::isPTCAbiV2())
    return false;
  if (Instructions == nullptr || Instructions->instructions == nullptr)
    return false;

  struct TrackedValue {
    bool Known = false;
    uint64_t Value = 0;
    bool RuntimeGPRDerived = false;
    bool MemoryDerived = false;
  };

  std::vector<TrackedValue> Values(Instructions->total_temps);
  for (unsigned I = 0; I < Instructions->total_temps; I++) {
    uint64_t Value = 0;
    if (getQEMUV2RuntimeGlobalTempValue(Instructions, I, Value)) {
      Values[I] = { true, Value, true, false };
    } else if (getConstTempValue(Instructions, I, Value)) {
      Values[I] = { true, Value, false, false };
    }
  }

  auto InvalidateOutputs = [&](PTCInstruction &Instruction) {
    unsigned OutCount = ptc_instruction_out_arg_count(&ptc, &Instruction);
    for (unsigned I = 0; I < OutCount; I++) {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, I);
      if (Out < Values.size())
        Values[Out] = {};
    }
  };

  bool Found = false;
  uint64_t Candidate = 0;
  auto MaybeRecordTarget = [&](PTCInstructionArg Out, const TrackedValue &Value) {
    if (isQEMUV2PCTemp(Instructions, Out)
        && Value.Known
        && (Value.RuntimeGPRDerived || Value.MemoryDerived)
        && isValidQEMUV2IndirectTarget(Value.Value, VirtualAddress, JumpTargets)) {
      Candidate = Value.Value;
      Found = true;
    }
  };

  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    PTCInstruction &Instruction = Instructions->instructions[I];
    switch (Instruction.opc) {
    case PTC_INSTRUCTION_op_movi_i32:
    case PTC_INSTRUCTION_op_movi_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      if (Out < Values.size())
        Values[Out] = { true,
                        ptc_instruction_const_arg(&ptc, &Instruction, 0),
                        false,
                        false };
      break;
    }
    case PTC_INSTRUCTION_op_mov_i32:
    case PTC_INSTRUCTION_op_mov_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg In = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      if (Out < Values.size()) {
        if (In < Values.size() && Values[In].Known) {
          Values[Out] = Values[In];
          MaybeRecordTarget(Out, Values[Out]);
        } else {
          Values[Out] = {};
        }
      }
      break;
    }
    case PTC_INSTRUCTION_op_add_i32:
    case PTC_INSTRUCTION_op_sub_i32:
    case PTC_INSTRUCTION_op_mul_i32:
    case PTC_INSTRUCTION_op_and_i32:
    case PTC_INSTRUCTION_op_or_i32:
    case PTC_INSTRUCTION_op_xor_i32:
    case PTC_INSTRUCTION_op_shl_i32:
    case PTC_INSTRUCTION_op_shr_i32:
    case PTC_INSTRUCTION_op_sar_i32:
    case PTC_INSTRUCTION_op_add_i64:
    case PTC_INSTRUCTION_op_sub_i64:
    case PTC_INSTRUCTION_op_mul_i64:
    case PTC_INSTRUCTION_op_and_i64:
    case PTC_INSTRUCTION_op_or_i64:
    case PTC_INSTRUCTION_op_xor_i64:
    case PTC_INSTRUCTION_op_shl_i64:
    case PTC_INSTRUCTION_op_shr_i64:
    case PTC_INSTRUCTION_op_sar_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg LHSArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      PTCInstructionArg RHSArg = ptc_instruction_in_arg(&ptc, &Instruction, 1);
      if (Out >= Values.size())
        break;

      if (LHSArg < Values.size() && RHSArg < Values.size()
          && Values[LHSArg].Known && Values[RHSArg].Known) {
        uint64_t Result = 0;
        if (qemuV2ApplyBinary(Instruction.opc,
                              Values[LHSArg].Value,
                              Values[RHSArg].Value,
                              Result)) {
          unsigned Bits = qemuV2OpcodeIsI32(Instruction.opc) ? 32 : 64;
          Values[Out] = {
            true,
            qemuV2Truncate(Result, Bits),
            Values[LHSArg].RuntimeGPRDerived || Values[RHSArg].RuntimeGPRDerived,
            Values[LHSArg].MemoryDerived || Values[RHSArg].MemoryDerived
          };
          MaybeRecordTarget(Out, Values[Out]);
          break;
        }
      }

      Values[Out] = {};
      break;
    }
    case PTC_INSTRUCTION_op_qemu_ld_i32:
    case PTC_INSTRUCTION_op_qemu_ld_i64: {
      PTCInstructionArg Out = ptc_instruction_out_arg(&ptc, &Instruction, 0);
      PTCInstructionArg AddressArg = ptc_instruction_in_arg(&ptc, &Instruction, 0);
      if (Out >= Values.size())
        break;

      uint64_t LoadedValue = 0;
      unsigned LoadedBits = 0;
      PTCLoadStoreArg MemoryAccess =
        ptc_compat::parseLoadStoreArg(ptc,
                                      ptc_instruction_const_arg(&ptc,
                                                               &Instruction,
                                                               0));
      if (AddressArg < Values.size()
          && Values[AddressArg].Known
          && MemoryAccess.access_type != PTC_MEMORY_ACCESS_UNKNOWN
          && readQEMUV2ConcreteGuestLoad(JumpTargets.binary(),
                                         Values[AddressArg].Value,
                                         MemoryAccess.type,
                                         LoadedValue,
                                         LoadedBits)) {
        unsigned Bits = qemuV2OpcodeIsI32(Instruction.opc) ? 32 : 64;
        Values[Out] = { true, qemuV2Truncate(LoadedValue, Bits), false, true };
        MaybeRecordTarget(Out, Values[Out]);
      } else {
        Values[Out] = {};
      }
      break;
    }
    case PTC_INSTRUCTION_op_debug_insn_start:
    case PTC_INSTRUCTION_op_discard:
    case PTC_INSTRUCTION_op_qemu_st_i32:
    case PTC_INSTRUCTION_op_qemu_st_i64:
    case PTC_INSTRUCTION_op_call:
    case PTC_INSTRUCTION_op_br:
    case PTC_INSTRUCTION_op_brcond_i32:
    case PTC_INSTRUCTION_op_brcond_i64:
    case PTC_INSTRUCTION_op_exit_tb:
    case PTC_INSTRUCTION_op_goto_tb:
    case PTC_INSTRUCTION_op_set_label:
      break;
    default:
      InvalidateOutputs(Instruction);
      break;
    }
  }

  if (!Found)
    return false;

  TargetPC = Candidate;
  return true;
}

static bool isValidQEMUV2IndirectTarget(uint64_t TargetPC,
                                        uint64_t SourcePC,
                                        JumpTargetManager &JumpTargets) {
  return TargetPC != 0
         && TargetPC != SourcePC
         && JumpTargets.isPC(TargetPC)
         && !JumpTargets.isOutOfAddrRange(TargetPC);
}

static bool extractQEMUV2DirectCallReturnPC(const PTCInstructionList *Instructions,
                                            uint64_t VirtualAddress,
                                            uint64_t DynamicVirtualAddress,
                                            JumpTargetManager &JumpTargets,
                                            uint64_t &ReturnPC) {
  if (!ptc_compat::isPTCAbiV2())
    return false;
  if (Instructions == nullptr || Instructions->instructions == nullptr)
    return false;

  bool Found = false;
  uint64_t Best = 0;
  std::vector<std::pair<bool, uint64_t>> KnownTemps;
  seedQEMUV2TempConstants(Instructions, KnownTemps);

  for (unsigned I = 0; I < Instructions->instruction_count; I++) {
    PTCInstruction &Instruction = Instructions->instructions[I];
    if (Instruction.opc != PTC_INSTRUCTION_op_qemu_st_i32
        && Instruction.opc != PTC_INSTRUCTION_op_qemu_st_i64) {
      updateQEMUV2TempConstants(Instructions, Instruction, KnownTemps);
      continue;
    }
    if (ptc_instruction_in_arg_count(&ptc, &Instruction) == 0)
      continue;

    uint64_t Candidate = 0;
    PTCInstructionArg StoredValue =
      ptc_instruction_in_arg(&ptc, &Instruction, 0);
    if (!getConstTempValue(Instructions, StoredValue, Candidate)
        && !getKnownPTCTempValue(Instructions,
                                 KnownTemps,
                                 StoredValue,
                                 Candidate))
      continue;

    if (Candidate <= VirtualAddress)
      continue;
    if (DynamicVirtualAddress != 0 && Candidate == DynamicVirtualAddress)
      continue;
    if (!JumpTargets.isPC(Candidate)
        || JumpTargets.isOutOfAddrRange(Candidate))
      continue;

    if (!Found || Candidate < Best) {
      Found = true;
      Best = Candidate;
    }

    updateQEMUV2TempConstants(Instructions, Instruction, KnownTemps);
  }

  if (!Found)
    return false;

  ReturnPC = Best;
  return true;
}

static size_t translatePTCBlock(uint64_t VirtualAddress,
                                const BinaryFile &Binary,
                                PTCInstructionList *Instructions,
                                uint64_t *DynamicVirtualAddress) {
  const bool Serialize = shouldSerializePTCTranslate();
  ScopedPTCTranslateLock Lock(Serialize);
  const unsigned MaxAttempts = Serialize ? 4 : 1;
  size_t ConsumedSize = 0;

  for (unsigned Attempt = 0; Attempt < MaxAttempts; Attempt++) {
    if (Attempt != 0) {
      ptc_instruction_list_free(Instructions);
      std::memset(Instructions, 0, sizeof(*Instructions));
      if (DynamicVirtualAddress != nullptr)
        *DynamicVirtualAddress = 0;
      usleep(250000u * Attempt);
    }

    ConsumedSize =
      ptc.translate(VirtualAddress, 1, Instructions, DynamicVirtualAddress);

    if (!isEmptyPTCInstructionList(ConsumedSize, Instructions)) {
      uint64_t FirstDebugPC = 0;
      uint64_t CanonicalFirstDebugPC = 0;
      const bool HasFirstDebugPC = findFirstDebugPC(Instructions, FirstDebugPC);
      if (HasFirstDebugPC)
        CanonicalFirstDebugPC = canonicalizePTCDebugPC(FirstDebugPC, Binary);

      if (!Serialize
          || !HasFirstDebugPC
          || CanonicalFirstDebugPC == VirtualAddress) {
        if (Serialize && FirstDebugPC != 0
            && CanonicalFirstDebugPC != FirstDebugPC) {
          errs() << "runnable-lift: accepted QEMU v2 PTC relocated debug pc"
                 << " requested_pc=0x" << Twine::utohexstr(VirtualAddress)
                 << " first_debug_pc=0x" << Twine::utohexstr(FirstDebugPC)
                 << " canonical_first_debug_pc=0x"
                 << Twine::utohexstr(CanonicalFirstDebugPC)
                 << "\n";
        }
        return ConsumedSize;
      }

      errs() << "runnable-lift: rejected QEMU v2 PTC returned-pc divergence"
             << " requested_pc=0x" << Twine::utohexstr(VirtualAddress)
             << " first_debug_pc=0x" << Twine::utohexstr(FirstDebugPC)
             << "\n";
      ptc_instruction_list_free(Instructions);
      std::memset(Instructions, 0, sizeof(*Instructions));
      if (DynamicVirtualAddress != nullptr)
        *DynamicVirtualAddress = 0;
      return 0;
    }
    if (!Serialize)
      return ConsumedSize;

    if (Attempt + 1 < MaxAttempts)
      errs() << "runnable-lift: retrying transient QEMU v2 PTC payload pc=0x"
             << Twine::utohexstr(VirtualAddress)
             << " attempt=" << (Attempt + 2)
             << "/" << MaxAttempts << "\n";
  }

  return ConsumedSize;
}

static void failInvalidPTCInstructionList(uint64_t VirtualAddress,
                                          size_t ConsumedSize,
                                          uint64_t DynamicVirtualAddress,
                                          const PTCInstructionList &Instructions) {
  errs() << "runnable-lift: unsupported empty PTCInstructionList at pc=0x"
         << Twine::utohexstr(VirtualAddress)
         << " consumed-size=" << ConsumedSize
         << " dynamic-pc=0x" << Twine::utohexstr(DynamicVirtualAddress)
         << " instruction-count=" << Instructions.instruction_count
         << " instructions="
         << (Instructions.instructions == nullptr ? "null" : "non-null")
         << "\n";
  errs() << "runnable-lift: PTC returned no usable legacy instructions; "
         << "current QEMU v2 empty stubs are an unsupported boundary\n";
  printPTCAbiMetadataBoundary();
  std::exit(EXIT_FAILURE);
}

static void materializeEmptyBasicBlocks(Function *F) {
  if (F == nullptr)
    return;

  LLVMContext &Context = F->getContext();
  for (BasicBlock &BB : *F) {
    if (!BB.empty())
      continue;
    errs() << "runnable-lift: warning: materializing empty basic block "
           << BB.getName() << "\n";
    new UnreachableInst(Context, &BB);
  }
}

static void insertQEMUV2MemoryBarrierBefore(Instruction *InsertBefore) {
  LLVMContext &Context = InsertBefore->getContext();
  auto *BarrierTy = FunctionType::get(Type::getVoidTy(Context), false);
  auto *Barrier = InlineAsm::get(BarrierTy, "", "~{memory}", true);
  IRBuilder<> Builder(InsertBefore);
  createNoArgCall(Builder, BarrierTy, Barrier);
}

static bool isStoreToValue(StoreInst *Store, Value *Pointer) {
  if (Store == nullptr || Pointer == nullptr)
    return false;
  return Store->getPointerOperand()->stripPointerCasts()
         == Pointer->stripPointerCasts();
}

static unsigned redirectQEMUV2ConstantDispatcherBranches(
    Function *Root,
    JumpTargetManager &JumpTargets) {
  if (Root == nullptr || JumpTargets.dispatcher() == nullptr
      || JumpTargets.pcReg() == nullptr)
    return 0;

  std::map<uint64_t, BasicBlock *> TargetByPC;
  std::map<BasicBlock *, uint64_t> PCByHeadBlock;
  for (auto It = JumpTargets.begin(); It != JumpTargets.end(); ++It) {
    BasicBlock *Target = It->second.head();
    if (Target == nullptr || Target->empty())
      continue;

    TargetByPC[It->first] = Target;
    PCByHeadBlock[Target] = It->first;
  }

  BasicBlock *Dispatcher = JumpTargets.dispatcher();
  Value *PCReg = JumpTargets.pcReg();
  unsigned Redirected = 0;
  unsigned BranchArms = 0;
  unsigned LocalBackEdges = 0;

  for (BasicBlock &BB : *Root) {
    if (!JumpTargets.isTranslatedBB(&BB))
      continue;

    Instruction *Terminator = BB.getTerminator();
    if (Terminator == nullptr)
      continue;

    auto *Branch = dyn_cast<BranchInst>(Terminator);
    if (Branch == nullptr || !Branch->isUnconditional()
        || Branch->getSuccessor(0) != Dispatcher)
      continue;

    auto StoreIt = Branch->getIterator();
    if (StoreIt == BB.begin())
      continue;
    --StoreIt;

    auto *PCWrite = dyn_cast<StoreInst>(&*StoreIt);
    if (!isStoreToValue(PCWrite, PCReg))
      continue;

    auto TargetPC = JumpTargets.resolveConstantPCStoreValue(
        PCWrite->getValueOperand());
    if (!TargetPC)
      continue;

    auto TargetIt = TargetByPC.find(*TargetPC);
    if (TargetIt == TargetByPC.end())
      continue;

    BasicBlock *TargetBlock = TargetIt->second;
    if (TargetBlock == nullptr || TargetBlock->empty()
        || TargetBlock == Dispatcher)
      continue;

    bool IsBranchArm = BB.getName().contains("_L");
    bool IsLocalBackEdge = false;
    auto SourcePC = PCByHeadBlock.find(&BB);
    if (!IsBranchArm && SourcePC != PCByHeadBlock.end()
        && *TargetPC <= SourcePC->second
        && SourcePC->second - *TargetPC <= 0x1000)
      IsLocalBackEdge = true;

    if (IsLocalBackEdge)
      insertQEMUV2MemoryBarrierBefore(Branch);

    Branch->setSuccessor(0, TargetBlock);
    JumpTargets.newBranch();
    Redirected++;
    if (IsBranchArm)
      BranchArms++;
    else if (IsLocalBackEdge)
      LocalBackEdges++;
  }

  if (Redirected != 0) {
    errs() << "runnable-lift: redirected QEMU v2 constant dispatcher branches"
           << " total=" << Redirected
           << " branch_arms=" << BranchArms
           << " local_back_edges=" << LocalBackEdges << "\n";
  }

  return Redirected;
}

static bool fileExists(const std::string &Path) {
  return !Path.empty() && access(Path.c_str(), F_OK) == 0;
}

static std::string shellQuote(const std::string &Value) {
  std::string Result = "'";
  for (char C : Value) {
    if (C == '\'')
      Result += "'\\''";
    else
      Result += C;
  }
  Result += "'";
  return Result;
}

static std::string findRepoRootFromCwd() {
  char Buffer[4096];
  if (getcwd(Buffer, sizeof(Buffer)) == nullptr)
    return "";
  std::string Current(Buffer);
  while (!Current.empty()) {
    std::string Probe = Current + "/runnable/scripts/merge_dynamic_runnable_fragments.py";
    if (access(Probe.c_str(), F_OK) == 0)
      return Current;
    Probe = Current + "/scripts/merge_dynamic_runnable_fragments.py";
    if (access(Probe.c_str(), F_OK) == 0)
      return Current;
    size_t Slash = Current.find_last_of('/');
    if (Slash == std::string::npos)
      break;
    if (Slash == 0) {
      Current = "/";
      break;
    }
    Current = Current.substr(0, Slash);
  }
  return "";
}

static std::string findMergeScriptNearExecutable() {
  char *FullPath = realpath("/proc/self/exe", nullptr);
  if (FullPath == nullptr)
    return "";

  std::string Current(FullPath);
  free(FullPath);

  size_t Slash = Current.find_last_of('/');
  if (Slash == std::string::npos)
    return "";
  Current = Current.substr(0, Slash);

  while (!Current.empty()) {
    std::string Probe = Current + "/merge_dynamic_runnable_fragments.py";
    if (fileExists(Probe))
      return Probe;
    Probe = Current + "/runnable/scripts/merge_dynamic_runnable_fragments.py";
    if (fileExists(Probe))
      return Probe;
    Probe = Current + "/scripts/merge_dynamic_runnable_fragments.py";
    if (fileExists(Probe))
      return Probe;

    Slash = Current.find_last_of('/');
    if (Slash == std::string::npos)
      break;
    if (Slash == 0) {
      Current = "/";
      break;
    }
    Current = Current.substr(0, Slash);
  }

  return "";
}

static void appendMergeScriptPathCandidates(std::vector<std::string> &Candidates) {
  if (const char *Explicit = std::getenv("RUNNABLE_DYNAMIC_MERGE_SCRIPT"))
    Candidates.push_back(Explicit);
  if (const char *BuildDir = std::getenv("RUNNABLE_BUILD_DIR"))
    Candidates.push_back(std::string(BuildDir)
                         + "/merge_dynamic_runnable_fragments.py");
  if (const char *RepoRoot = std::getenv("RUNNABLE_REPO_ROOT")) {
    Candidates.push_back(std::string(RepoRoot)
                         + "/runnable/scripts/merge_dynamic_runnable_fragments.py");
    Candidates.push_back(std::string(RepoRoot)
                         + "/scripts/merge_dynamic_runnable_fragments.py");
  }

  std::string NearExecutable = findMergeScriptNearExecutable();
  if (!NearExecutable.empty())
    Candidates.push_back(NearExecutable);

  if (const char *Path = std::getenv("PATH")) {
    std::stringstream Stream(Path);
    std::string Dir;
    while (std::getline(Stream, Dir, ':')) {
      if (!Dir.empty())
        Candidates.push_back(Dir + "/merge_dynamic_runnable_fragments.py");
    }
  }
}

static std::string findRepoRootFromExecutable() {
  char *FullPath = realpath("/proc/self/exe", nullptr);
  if (FullPath == nullptr)
    return "";

  std::string Current(FullPath);
  free(FullPath);

  size_t Slash = Current.find_last_of('/');
  if (Slash == std::string::npos)
    return "";
  Current = Current.substr(0, Slash);

  while (!Current.empty()) {
    std::string Probe = Current + "/runnable/scripts/merge_dynamic_runnable_fragments.py";
    if (access(Probe.c_str(), F_OK) == 0)
      return Current;
    Probe = Current + "/scripts/merge_dynamic_runnable_fragments.py";
    if (access(Probe.c_str(), F_OK) == 0)
      return Current;
    Slash = Current.find_last_of('/');
    if (Slash == std::string::npos)
      break;
    if (Slash == 0) {
      Current = "/";
      break;
    }
    Current = Current.substr(0, Slash);
  }

  return "";
}

} // namespace

// Register all the arguments

cl::opt<bool> ExeInit("exe-init",
                       cl::desc("Initial the running binary "
                                "and start traverse"),
                       cl::cat(MainCategory));
cl::opt<int> ExeNums("exe-nums",
                       cl::desc("Initial numbers of the running binary "),
                       cl::cat(MainCategory));



// TODO: can we drop this and the associated functionality?
static cl::opt<string> CoveragePath("coverage-path",
                                    cl::desc("destination path for the CSV "
                                             "containing "
                                             "translated ranges"),
                                    cl::value_desc("path"),
                                    cl::cat(MainCategory));
static cl::alias A1("c",
                    cl::desc("Alias for -coverage-path"),
                    cl::aliasopt(CoveragePath),
                    cl::cat(MainCategory));

// TODO: linking-info-path?
static cl::opt<string> LinkingInfoPath("linking-info",
                                       cl::desc("destination path for the CSV "
                                                "containing linking info"),
                                       cl::value_desc("path"),
                                       cl::cat(MainCategory));
static cl::alias A2("i",
                    cl::desc("Alias for -linking-info"),
                    cl::aliasopt(LinkingInfoPath),
                    cl::cat(MainCategory));

// TODO: can we drop this and the associated functionality?
static cl::opt<string> BBSummaryPath("bb-summary",
                                     cl::desc("destination path for the CSV "
                                              "containing the statistics about "
                                              "the translated basic blocks"),
                                     cl::value_desc("path"),
                                     cl::cat(MainCategory));
static cl::alias A3("b",
                    cl::desc("Alias for -bb-summary"),
                    cl::aliasopt(BBSummaryPath),
                    cl::cat(MainCategory));

static cl::opt<bool> NoLink("no-link",
                            cl::desc("do not link the output to QEMU helpers"),
                            cl::cat(MainCategory));
static cl::alias A4("L",
                    cl::desc("Alias for -no-link"),
                    cl::aliasopt(NoLink),
                    cl::cat(MainCategory));

// Enable Debug Options to be specified on the command line
namespace DIT = DebugInfoType;
auto X = cl::values(clEnumValN(DIT::None, "none", "no debug information"),
                    clEnumValN(DIT::OriginalAssembly,
                               "asm",
                               "debug information referred to the assembly "
                               "of the input file"),
                    clEnumValN(DIT::PTC,
                               "ptc",
                               "debug information referred to the Portable "
                               "Tiny Code"),
                    clEnumValN(DIT::LLVMIR,
                               "ll",
                               "debug information referred to the LLVM IR"));
static cl::opt<DIT::Values> DebugInfo("debug-info",
                                      cl::desc("emit debug information"),
                                      X,
                                      cl::cat(MainCategory),
                                      cl::init(DIT::LLVMIR));

static cl::alias A6("g",
                    cl::desc("Alias for -debug-info"),
                    cl::aliasopt(DebugInfo),
                    cl::cat(MainCategory));

// TODO: is this still active?
static cl::opt<string> DebugPath("debug-path",
                                 cl::desc("destination path for the generated "
                                          "debug source"),
                                 cl::value_desc("path"),
                                 cl::cat(MainCategory));

static Logger<> PTCLog("ptc");
static Logger<> TranslatePCLog("translatepc");

template<typename T, typename... Args>
inline std::array<T, sizeof...(Args)> make_array(Args &&... args) {
  return { { std::forward<Args>(args)... } };
}

// Outline the destructor for the sake of privacy in the header
CodeGenerator::~CodeGenerator() = default;

static std::unique_ptr<Module> parseIR(StringRef Path, LLVMContext &Context) {
  std::unique_ptr<Module> Result;
  SMDiagnostic Errors;
  Result = parseIRFile(Path, Errors, Context);

#if LLVM_VERSION_MAJOR >= 15
  if (Result.get() == nullptr) {
    auto BufferOrErr = MemoryBuffer::getFile(Path);
    if (BufferOrErr) {
      std::string UpgradedIR = (*BufferOrErr)->getBuffer().str();
      bool Changed = false;
      auto ReplaceAll = [&](StringRef From, StringRef To) {
        size_t Pos = 0;
        bool LocalChanged = false;
        while ((Pos = UpgradedIR.find(From.str(), Pos)) != std::string::npos) {
          UpgradedIR.replace(Pos, From.size(), To.str());
          Pos += To.size();
          LocalChanged = true;
        }
        Changed |= LocalChanged;
      };

      ReplaceAll("%struct.commonNaNT* noalias sret",
                 "%struct.commonNaNT* noalias sret(%struct.commonNaNT)");
      ReplaceAll("%struct.commonNaNT* sret",
                 "%struct.commonNaNT* sret(%struct.commonNaNT)");
      ReplaceAll("%struct.commonNaNT* byval",
                 "%struct.commonNaNT* byval(%struct.commonNaNT)");

      if (Changed) {
        SMDiagnostic UpgradeErrors;
        Result = parseAssemblyString(UpgradedIR, UpgradeErrors, Context);
        if (Result.get() != nullptr)
          return Result;
        UpgradeErrors.print("runnable", dbgs());
      }
    }
  }
#endif

  if (Result.get() == nullptr) {
    Errors.print("runnable", dbgs());
    runnable_abort();
  }

  return Result;
}

CodeGenerator::CodeGenerator(BinaryFile &Binary,
                             Architecture &Target,
                             llvm::LLVMContext &TheContext,
                             std::string Output,
                             std::string Helpers,
                             std::string EarlyLinked,
                             const ParallelOptions &Options) :
  TargetArchitecture(Target),
  Context(TheContext),
  TheModule((new Module("top", Context))),
  HelpersPath(Helpers),
  EarlyLinkedPath(EarlyLinked),
  OutputPath(Output),
  Debug(new DebugHelper(Output, TheModule.get(), DebugInfo, DebugPath)),
  Binary(Binary),
  ParallelConfig(Options) {
  OriginalInstrMDKind = Context.getMDKindID("oi");
  PTCInstrMDKind = Context.getMDKindID("pi");

  HelpersModule = parseIR(HelpersPath, Context);
  defineQEMURecheckingSingleStepHelper(*HelpersModule);
  defineQEMUCCComputeNZHelper(*HelpersModule);
  defineQEMUV2X86CCComputeCompatHelpers(*HelpersModule);
  for (auto &F : HelpersModule->functions()) {
    // Remove 'optnone' Function attribute from QEMU helpers.
    // QEMU helpers are compiled with -O0 in libtinycode because the LLVM IR
    // generated in this way it much more readable, but we need to optimize
    // them when we link them with the decompiled code.
    // In particular we desperately need SROA to get rid of allocas, to
    // enable the CPUStateAccessAnalysisPass.
    // If we don't remove this attribute future optimizations are blocked.
    F.removeFnAttr(Attribute::OptimizeNone);
    F.setDSOLocal(false);
  }
  EarlyLinkedModule = parseIR(EarlyLinkedPath, Context);

  if (CoveragePath.size() == 0)
    CoveragePath = Output + ".coverage.csv";

  if (BBSummaryPath.size() == 0)
    BBSummaryPath = Output + ".bbsummary.csv";

  // Prepare the linking info CSV
  if (LinkingInfoPath.size() == 0)
    LinkingInfoPath = OutputPath + ".li.csv";
  std::ofstream LinkingInfoStream(LinkingInfoPath);
  LinkingInfoStream << "name,start,end\n";

  auto Path = OutputPath + ".illegalEntry.log";
  std::ofstream EntryAddrInfoStream(Path);
  EntryAddrInfoStream << "illegal entry addresses:\n";

  auto *Uint8Ty = Type::getInt8Ty(Context);
  auto *ElfHeaderHelper = new GlobalVariable(*TheModule,
                                             Uint8Ty,
                                             true,
                                             GlobalValue::ExternalLinkage,
                                             ConstantInt::get(Uint8Ty, 0),
                                             "elfheaderhelper");
  setGlobalAlignment(ElfHeaderHelper, 1);
  ElfHeaderHelper->setSection(".elfheaderhelper");

  auto *RegisterType = Type::getIntNTy(Context,
                                       Binary.architecture().pointerSize());
  auto createConstGlobal = [this, &RegisterType](const Twine &Name,
                                                 uint64_t Value) {
    return new GlobalVariable(*TheModule,
                              RegisterType,
                              true,
                              GlobalValue::ExternalLinkage,
                              ConstantInt::get(RegisterType, Value),
                              Name);
  };

  // These values will be used to populate the auxiliary vectors
  createConstGlobal("e_phentsize", Binary.programHeaderSize());
  createConstGlobal("e_phnum", Binary.programHeadersCount());
  createConstGlobal("phdr_address", Binary.programHeadersAddress());

 for (SegmentInfo &Segment : Binary.segments()) {
    // If it's executable register it as a valid code area
    if (Segment.IsExecutable) {
      // We ignore possible p_filesz-p_memsz mismatches, zeros wouldn't be
      // useful code anyway
//      ptc.mmap(Segment.StartVirtualAddress,
//               static_cast<const void *>(Segment.Data.data()),
//               static_cast<size_t>(Segment.Data.size()));
      CodeStartAddress = Segment.StartVirtualAddress;
    }

    if(!Segment.IsExecutable){
      std::string Name = Segment.generateName();

      // Get data and size
      auto *DataType = ArrayType::get(Uint8Ty, Segment.size());

      Constant *TheData = nullptr;
      if (Segment.size() == Segment.Data.size()) {
        // Create the array directly from the mmap'd ELF
        TheData = ConstantDataArray::get(Context, Segment.Data);
      } else {
        // If we have extra data at the end we need to create a copy of the
        // segment and append the NULL bytes
        auto FullData = std::make_unique<uint8_t[]>(Segment.size());
        ::memcpy(FullData.get(), Segment.Data.data(), Segment.Data.size());
        ::bzero(FullData.get() + Segment.Data.size(),
                Segment.size() - Segment.Data.size());
        auto DataRef = ArrayRef<uint8_t>(FullData.get(), Segment.size());
        TheData = ConstantDataArray::get(Context, DataRef);
      }

      // Create a new global variable
      Segment.Variable = new GlobalVariable(*TheModule,
                                            DataType,
                                            !Segment.IsWriteable,
                                            GlobalValue::ExternalLinkage,
                                            TheData,
                                            Name);

      // Force alignment to 1 and assign the variable to a specific section
      setGlobalAlignment(Segment.Variable, 1);
      Segment.Variable->setSection("." + Name);

      // Write the linking info CSV
      LinkingInfoStream << "." << Name << ",0x" << std::hex
                        << Segment.StartVirtualAddress << ",0x" << std::hex
                        << Segment.EndVirtualAddress << "\n";
    }
  }

  // Write needed libraries CSV
  std::string NeededLibs = OutputPath + ".need.csv";
  std::ofstream NeededLibsStream(NeededLibs);
  for (const std::string &Library : Binary.neededLibraryNames())
    NeededLibsStream << Library << "\n";
}

Function *CodeGenerator::importHelperFunctionDeclaration(StringRef Name) {
  // Don't copy the FunctionType from the HelpersModule. Simply add the function
  // declaration with the correct name, and this will trigger the Linker.
  // The Linker will then overwrite the stub declaration with the real imported
  // definition, fixing it up with the correct FunctionType.
  FunctionType *StubType = FunctionType::get(Type::getVoidTy(Context), false);
  Constant *Inserted = runnable_llvm::getOrInsertFunction(*TheModule,
                                                          Name,
                                                          StubType);
  return cast<Function>(Inserted);
}

std::string SegmentInfo::generateName() {
  // Create name from start and size
  std::stringstream NameStream;
  NameStream << "o_" << (IsReadable ? "r" : "") << (IsWriteable ? "w" : "")
             << (IsExecutable ? "x" : "") << "_0x" << std::hex
             << StartVirtualAddress;

  return NameStream.str();
}

static BasicBlock *replaceFunction(Function *ToReplace) {
  ToReplace->setLinkage(GlobalValue::InternalLinkage);
  ToReplace->dropAllReferences();

  return BasicBlock::Create(ToReplace->getParent()->getContext(),
                            "",
                            ToReplace);
}

static void replaceFunctionWithRet(Function *ToReplace, uint64_t Result) {
  if (ToReplace == nullptr)
    return;

  BasicBlock *Body = replaceFunction(ToReplace);
  Value *ResultValue;

  if (ToReplace->getReturnType()->isVoidTy()) {
    runnable_assert(Result == 0);
    ResultValue = nullptr;
  } else if (ToReplace->getReturnType()->isIntegerTy()) {
    auto *ReturnType = cast<IntegerType>(ToReplace->getReturnType());
    ResultValue = ConstantInt::get(ReturnType, Result, false);
  } else {
    runnable_unreachable("No-op functions can only return void or an integer "
                      "type");
  }

  ReturnInst::Create(ToReplace->getParent()->getContext(), ResultValue, Body);
}

class CpuLoopFunctionPass : public llvm::ModulePass {
public:
  static char ID;

  CpuLoopFunctionPass() : llvm::ModulePass(ID) {}

  void getAnalysisUsage(llvm::AnalysisUsage &AU) const override;

  bool runOnModule(llvm::Module &M) override;
};

char CpuLoopFunctionPass::ID = 0;

using RegisterCLF = RegisterPass<CpuLoopFunctionPass>;
static RegisterCLF Y("cpu-loop", "cpu_loop FunctionPass", false, false);

void CpuLoopFunctionPass::getAnalysisUsage(llvm::AnalysisUsage &AU) const {
  AU.addRequired<LoopInfoWrapperPass>();
}

template<class Range, class UnaryPredicate>
auto find_unique(Range &&TheRange, UnaryPredicate Predicate)
  -> decltype(*TheRange.begin()) {

  const auto Begin = TheRange.begin();
  const auto End = TheRange.end();

  auto It = std::find_if(Begin, End, Predicate);
  auto Result = It;
  runnable_assert(Result != End);
  runnable_assert(std::find_if(++It, End, Predicate) == End);

  return *Result;
}

template<class Range>
auto find_unique(Range &&TheRange) -> decltype(*TheRange.begin()) {

  const auto Begin = TheRange.begin();
  const auto End = TheRange.end();

  auto Result = Begin;
  runnable_assert(Begin != End && ++Result == End);

  return *Begin;
}

bool CpuLoopFunctionPass::runOnModule(Module &M) {
  Function &F = *M.getFunction("cpu_loop");

  // cpu_loop must return void
  runnable_assert(F.getReturnType()->isVoidTy());

  Module *TheModule = F.getParent();

  // Part 1: remove the backedge of the main infinite loop
  const LoopInfo &LI = getAnalysis<LoopInfoWrapperPass>(F).getLoopInfo();
  const Loop *OutermostLoop = find_unique(LI);

  BasicBlock *Header = OutermostLoop->getHeader();

  // Check that the header has only one predecessor inside the loop
  auto IsInLoop = [&OutermostLoop](BasicBlock *Predecessor) {
    return OutermostLoop->contains(Predecessor);
  };
  BasicBlock *Footer = find_unique(predecessors(Header), IsInLoop);

  // Assert on the type of the last instruction (branch or brcond)
  runnable_assert(Footer->end() != Footer->begin());
  Instruction *LastInstruction = &*--Footer->end();
  runnable_assert(isa<BranchInst>(LastInstruction));

  // Remove the last instruction and replace it with a ret
  LastInstruction->eraseFromParent();
  ReturnInst::Create(F.getParent()->getContext(), Footer);

  // Part 2: replace the call to cpu_*_exec with exception_index
  auto IsCpuExec = [](Function &TheFunction) {
    StringRef Name = TheFunction.getName();
    return Name.startswith("cpu_") && Name.endswith("_exec");
  };
  Function &CpuExec = find_unique(F.getParent()->functions(), IsCpuExec);

  User *CallUser = find_unique(CpuExec.users(), [&F](User *TheUser) {
    auto *TheInstruction = dyn_cast<Instruction>(TheUser);

    if (TheInstruction == nullptr)
      return false;

    return TheInstruction->getParent()->getParent() == &F;
  });

  auto *Call = cast<CallInst>(CallUser);
  runnable_assert(Call->getCalledFunction() == &CpuExec);
  Value *ExceptionIndex = TheModule->getOrInsertGlobal("exception_index",
                                                       CpuExec.getReturnType());
  Value *LoadExceptionIndex = createLoad(CpuExec.getReturnType(),
                                         ExceptionIndex,
                                         "",
                                         Call);
  Call->replaceAllUsesWith(LoadExceptionIndex);
  Call->eraseFromParent();

  return true;
}

class CpuLoopExitPass : public llvm::ModulePass {
public:
  static char ID;

  CpuLoopExitPass() : llvm::ModulePass(ID), VM(0) {}
  CpuLoopExitPass(VariableManager *VM) : llvm::ModulePass(ID), VM(VM) {}

  bool runOnModule(llvm::Module &M) override;

private:
  VariableManager *VM;
};

char CpuLoopExitPass::ID = 0;

using RegisterCLE = RegisterPass<CpuLoopExitPass>;
static RegisterCLE Z("cpu-loop-exit", "cpu_loop_exit Pass", false, false);

static void purgeNoReturn(Function *F) {
#if LLVM_VERSION_MAJOR < 8
  auto &Context = F->getParent()->getContext();
#endif

  if (F->hasFnAttribute(Attribute::NoReturn))
    F->removeFnAttr(Attribute::NoReturn);

  for (User *U : F->users())
    if (auto *Call = dyn_cast<CallInst>(U))
      if (Call->hasFnAttr(Attribute::NoReturn)) {
#if LLVM_VERSION_MAJOR >= 8
        Call->removeFnAttr(Attribute::NoReturn);
#else
        auto OldAttr = Call->getAttributes();
        auto NewAttr = OldAttr.removeAttribute(Context,
                                               AttributeList::FunctionIndex,
                                               Attribute::NoReturn);
        Call->setAttributes(NewAttr);
#endif
      }
}

static ReturnInst *createRet(Instruction *Position) {
  Function *F = Position->getParent()->getParent();
  purgeNoReturn(F);

  Type *ReturnType = F->getFunctionType()->getReturnType();
  if (ReturnType->isVoidTy()) {
    return ReturnInst::Create(F->getParent()->getContext(), nullptr, Position);
  } else if (ReturnType->isIntegerTy()) {
    auto *Zero = ConstantInt::get(static_cast<IntegerType *>(ReturnType), 0);
    return ReturnInst::Create(F->getParent()->getContext(), Zero, Position);
  } else {
    runnable_assert("Return type not supported");
  }

  return nullptr;
}

/// Find all calls to cpu_loop_exit and replace them with:
///
/// * call cpu_loop
/// * set cpu_loop_exiting = true
/// * return
///
/// Then look for all the callers of the function calling cpu_loop_exit and make
/// them check whether they should return immediately (cpu_loop_exiting == true)
/// or not.
/// Then when we reach the root function, set cpu_loop_exiting to false after
/// the call.
bool CpuLoopExitPass::runOnModule(llvm::Module &M) {
  LLVMContext &Context = M.getContext();
  Function *CpuLoopExit = M.getFunction("cpu_loop_exit");

  // Nothing to do here
  if (CpuLoopExit == nullptr)
    return false;

  if (not VM->hasEnv()) {
    ReturnInst::Create(Context, BasicBlock::Create(Context, "", CpuLoopExit));
    return true;
  }

  purgeNoReturn(CpuLoopExit);

  Function *CpuLoop = M.getFunction("cpu_loop");
  IntegerType *BoolType = Type::getInt1Ty(Context);
  std::set<Function *> FixedCallers;
  Constant *CpuLoopExitingVariable = nullptr;
  CpuLoopExitingVariable = new GlobalVariable(M,
                                              BoolType,
                                              false,
                                              GlobalValue::CommonLinkage,
                                              ConstantInt::getFalse(BoolType),
                                              StringRef("cpu_loop_exiting"));

  runnable_assert(CpuLoop != nullptr);

  std::queue<User *> CpuLoopExitUsers;
  for (User *TheUser : CpuLoopExit->users())
    CpuLoopExitUsers.push(TheUser);

  while (!CpuLoopExitUsers.empty()) {
    auto *Call = cast<CallInst>(CpuLoopExitUsers.front());
    CpuLoopExitUsers.pop();
    runnable_assert(Call->getCalledFunction() == CpuLoopExit);

    // Call cpu_loop
    auto *EnvType = CpuLoop->getFunctionType()->getParamType(0);
    auto *AddressComputation = VM->computeEnvAddress(EnvType, Call);
    auto *CallCpuLoop = CallInst::Create(CpuLoop,
                                         { AddressComputation },
                                         "",
                                         Call);
    // In recent versions of LLVM you can no longer inject a CallInst in a
    // Function with debug location if the call itself has not a debug location
    // as well, otherwise verifyModule() will fail.
    CallCpuLoop->setDebugLoc(Call->getDebugLoc());

    // Set cpu_loop_exiting to true
    new StoreInst(ConstantInt::getTrue(BoolType), CpuLoopExitingVariable, Call);

    // Return immediately
    createRet(Call);
    auto *Unreach = cast<UnreachableInst>(&*++Call->getIterator());
    Unreach->eraseFromParent();

    Function *Caller = Call->getParent()->getParent();

    // Remove the call to cpu_loop_exit
    Call->eraseFromParent();

    if (FixedCallers.find(Caller) == FixedCallers.end()) {
      FixedCallers.insert(Caller);

      std::queue<Value *> WorkList;
      WorkList.push(Caller);

      while (!WorkList.empty()) {
        Value *F = WorkList.front();
        WorkList.pop();

        for (User *RecUser : F->users()) {
          auto *RecCall = dyn_cast<CallInst>(RecUser);
          if (RecCall == nullptr) {
            auto *Cast = dyn_cast<ConstantExpr>(RecUser);
            runnable_assert(Cast != nullptr, "Unexpected user");
            runnable_assert(Cast->getOperand(0) == F && Cast->isCast());
            WorkList.push(Cast);
            continue;
          }

          Function *RecCaller = RecCall->getParent()->getParent();

          // TODO: make this more reliable than using function name
          if (RecCaller->getName() == "root") {
            // If we got to the translated function, just reset cpu_loop_exiting
            // to false
            new StoreInst(ConstantInt::getFalse(BoolType),
                          CpuLoopExitingVariable,
                          &*++RecCall->getIterator());
          } else {
            // If the caller is a QEMU helper function make it check
            // cpu_loop_exiting and if it's true, make it return

            // Split BB
            BasicBlock *OldBB = RecCall->getParent();
            BasicBlock::iterator SplitPoint = ++RecCall->getIterator();
            runnable_assert(SplitPoint != OldBB->end());
            BasicBlock *NewBB = OldBB->splitBasicBlock(SplitPoint);

            // Add a BB with a ret
            BasicBlock *QuitBB = BasicBlock::Create(Context,
                                                    "cpu_loop_exit_return",
                                                    RecCaller,
                                                    NewBB);
            UnreachableInst *Temp = new UnreachableInst(Context, QuitBB);
            createRet(Temp);
            Temp->eraseFromParent();

            // Check value of cpu_loop_exiting
            auto *Branch = cast<BranchInst>(&*++(RecCall->getIterator()));
            auto *Compare = new ICmpInst(Branch,
                                         CmpInst::ICMP_EQ,
                                         createLoad(BoolType,
                                                    CpuLoopExitingVariable,
                                                    "",
                                                    Branch),
                                         ConstantInt::getTrue(BoolType));

            BranchInst::Create(QuitBB, NewBB, Compare, Branch);
            Branch->eraseFromParent();

            // Add to the work list only if it hasn't been fixed already
            if (FixedCallers.find(RecCaller) == FixedCallers.end()) {
              FixedCallers.insert(RecCaller);
              WorkList.push(RecCaller);
            }
          }
        }
      }
    }
  }

  return true;
}

/// Removes all the basic blocks without predecessors from F
// TODO: this is not efficient, but it shouldn't be critical
static void purgeDeadBlocks(Function *F) {
  std::vector<BasicBlock *> Kill;
  do {
    for (BasicBlock *Dead : Kill)
      DeleteDeadBlock(Dead);
    Kill.clear();

    // Skip the first basic block
    for (BasicBlock &BB : make_range(++F->begin(), F->end()))
      if (pred_empty(&BB))
        Kill.push_back(&BB);

  } while (!Kill.empty());
}

void CodeGenerator::translate(uint64_t VirtualAddress) {
  using FT = FunctionType;

  // Declare useful functions
  auto *AbortTy = FunctionType::get(Type::getVoidTy(Context), false);
  auto *AbortFunction = runnable_llvm::getOrInsertFunction(*TheModule,
                                                           "abort",
                                                           AbortTy);

  importHelperFunctionDeclaration("target_set_brk");
  runnable_llvm::getOrInsertFunction(*TheModule,
                                     "syscall_init",
                                     FT::get(Type::getVoidTy(Context),
                                             {},
                                             false));

  // Instantiate helpers
  VariableManager Variables(*TheModule, *HelpersModule, TargetArchitecture);
  const Architecture &Arch = Binary.architecture();
  EffectivePTCOffsets PTCOffsets = getEffectivePTCOffsets(Arch);
  StringRef SPName = Arch.stackPointerRegister();
  GlobalVariable *PCReg = Variables.getByEnvOffset(PTCOffsets.PC, "pc").first;
  GlobalVariable *SPReg = Variables.getByEnvOffset(PTCOffsets.SP,
                                                   SPName.str()).first;
  runnable_assert(PCReg != nullptr);
  runnable_assert(SPReg != nullptr);
  const bool HasDistinctSPReg = SPReg != nullptr && SPReg != PCReg;

  IRBuilder<> Builder(Context);

  // Create main function
  auto *MainType = FT::get(Builder.getVoidTy(),
                           { SPReg->getValueType() },
                           false);
  auto *MainFunction = Function::Create(MainType,
                                        Function::ExternalLinkage,
                                        "root",
                                        TheModule.get());

  // Create the first basic block and create a placeholder for variable
  // allocations
  BasicBlock *Entry = BasicBlock::Create(Context, "entrypoint", MainFunction);
  BasicBlock *EntryBlock = Entry;
  Builder.SetInsertPoint(Entry);

  QuickMetadata QMD(Context);

  //
  // Create runnable.input named metadata
  //

  const char *MDName = "runnable.input.canonical-values";
  NamedMDNode *CanonicalValuesMD;
  CanonicalValuesMD = TheModule->getOrInsertNamedMetadata(MDName);
  for (auto &P : Binary.canonicalValues()) {
    StringRef CSVName = P.first;
    uint64_t CanonicalValue = P.second;
    ArrayRef<Metadata *> Entry{ QMD.get(CSVName), QMD.get(CanonicalValue) };
    CanonicalValuesMD->addOperand(QMD.tuple(Entry));
  }

  // Currently runnable.input.architecture is composed as follows:
  //
  // runnable.input.architecture = {
  //   InstructionAlignment,
  //   DelaySlotSize,
  //   PCRegisterName,
  //   SPRegisterName,
  //   ABIRegisters
  // }

  const SmallVector<ABIRegister, 20> &ABIRegisters = Arch.abiRegisters();
  SmallVector<Metadata *, 20> ABIRegMetadata;
  for (auto Register : ABIRegisters)
    ABIRegMetadata.push_back(MDString::get(Context, Register.name()));

  auto *Tuple = MDTuple::get(Context,
                             {
                               QMD.get(Arch.instructionAlignment()),
                               QMD.get(Arch.delaySlotSize()),
                               QMD.get("pc"),
                               QMD.get(Arch.stackPointerRegister()),
                               QMD.tuple(ArrayRef<Metadata *>(ABIRegMetadata)),
                             });
  MDName = "runnable.input.architecture";
  NamedMDNode *InputArchMD = TheModule->getOrInsertNamedMetadata(MDName);
  InputArchMD->addOperand(Tuple);

  // Create an instance of JumpTargetManager
  JumpTargetManager JumpTargets(MainFunction, PCReg, Binary);

  if (VirtualAddress == 0) {
    //JumpTargets.harvestGlobalData();
    VirtualAddress = Binary.entryPoint();
  }
//  VirtualAddress = Binary.entryPoint();
  JumpTargets.registerJT(VirtualAddress, JTReason::GlobalData);

  // Initialize the program counter
  auto *StartPC = ConstantInt::get(PCReg->getValueType(),
                                   VirtualAddress);
  // Use this instruction as the delimiter for local variables
  auto *Delimiter = Builder.CreateStore(StartPC, PCReg);
  MDNode *FirstOriginalInstrSeed = nullptr;

  // We need to remember this instruction so we can later insert a call here.
  // The problem is that up until now we don't know where our CPUState structure
  // is.
  // After the translation we will and use this information to create a call to
  // a helper function.
  // TODO: we need a more elegant solution here
  auto *InitEnvInsertPoint = Delimiter;
  if (HasDistinctSPReg) {
    Builder.CreateStore(&*MainFunction->arg_begin(), SPReg);
  } else {
    errs() << "runnable-lift: warning: skipping initial stack pointer store"
           << " because PTC sp offset aliases pc"
           << " (pc=" << ptc.pc << ", sp=" << ptc.sp << ")\n";
  }

  // PoC: in worker mode with a captured register snapshot, materialize each GPR
  // as an IR store in the entry block. This gives the interior seed block's
  // register uses a reaching definition (so haveDef in handleEntryBlock accepts
  // the seed instead of flagging illegalEntry) and seeds the concrete value the
  // coordinator held at the branch point.
  if (ParallelConfig.WorkerMode && ParallelConfig.HasSeedRegs
      && HasDistinctSPReg) {
    static const char *GPRName[16] = {
      "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
      "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"
    };
    // The x86-64 GPR file is a contiguous uint64_t regs[16] in the CPU env;
    // The stack pointer offset is the env offset of RSP (= regs[R_ESP]), so
    // regs[i] sits at env offset RegBase + i*8. Derive the base from the known
    // stack-pointer offset
    // (ptc.regs is a separate pointer, not the env base, so we must not use it).
    intptr_t RegBase = PTCOffsets.SP - (intptr_t)R_ESP * 8;
    if (RegBase >= 0) {
      for (int i = 0; i < 16; i++) {
        intptr_t Off = RegBase + (intptr_t)i * 8;
        GlobalVariable *RegGV = Variables.getByEnvOffset(Off, GPRName[i]).first;
        if (RegGV == nullptr)
          continue;
        auto *Ty = RegGV->getValueType();
        Builder.CreateStore(ConstantInt::get(Ty, ParallelConfig.SeedRegs[i]),
                            RegGV);
      }
    }
  } else if (ParallelConfig.WorkerMode && ParallelConfig.HasSeedRegs) {
    errs() << "runnable-lift: warning: skipping seed register materialization"
           << " because PTC sp offset aliases pc"
           << " (pc=" << ptc.pc << ", sp=" << ptc.sp << ")\n";
  }

  // Fake jumps to the dispatcher-related basic blocks. This way all the blocks
  // are always reachable.
  auto *ReachSwitch = Builder.CreateSwitch(Builder.getInt8(0),
                                           JumpTargets.dispatcher());
  ReachSwitch->addCase(Builder.getInt8(1), JumpTargets.anyPC());
  ReachSwitch->addCase(Builder.getInt8(2), JumpTargets.unexpectedPC());

  std::tie(VirtualAddress, Entry) = JumpTargets.peek();

  std::vector<BasicBlock *> Blocks;

  InstructionTranslator Translator(Builder,
                                   Variables,
                                   Binary,
                                   JumpTargets,
                                   Blocks,
                                   Binary.architecture(),
                                   TargetArchitecture);

  JumpTargets.InitialOutput(getPath());

  int jjj = 0;
  uint64_t DynamicVirtualAddress;
  // To register branch inst of BB into vector
  BasicBlock *BlockBRs;
  bool traverseFLAG = 1;
  uint64_t jtVirtualAddress;
  uint64_t tmpVA = 0;
  llvm::BasicBlock *srcBB = nullptr;
  uint64_t srcAddr = 0;
  bool StaticAddrFlag = false;
  uint32_t EntryFlag = 0;
  uint64_t SuspectEntryAddr = 0;
  bool PreferBranchFrontier = false;
  uint64_t LastHaveBBVA = 0;
  size_t RepeatedHaveBBCount = 0;
  const size_t ParallelHaveBBRepeatLimit = 4096;
  std::vector<uint64_t> BlockPCs1;
  std::vector<uint64_t> &BlockPCs = BlockPCs1;
  std::map<uint32_t, uint64_t> BaseData1;
  std::map<uint32_t, uint64_t> &BaseData = BaseData1;
  std::vector<QEMUV2KnownValue> QEMUV2KnownGPRs(16);
  std::map<uint64_t, std::vector<QEMUV2KnownValue>> QEMUV2FrontierGPRs;
  QEMUV2ConcreteFunctionPointerWrites QEMUV2ConcreteFunctionPointerWrites;
  QEMUV2SymbolicFunctionPointerWrites QEMUV2SymbolicFunctionPointerWrites;
  if (ptc_compat::isPTCAbiV2()
      && ParallelConfig.WorkerMode
      && ParallelConfig.HasSeedRegs) {
    for (int i = 0; i < 16; i++)
      QEMUV2KnownGPRs[i] = makeQEMUV2Known(ParallelConfig.SeedRegs[i]);
  }
  auto rememberQEMUV2FrontierGPRs = [&](uint64_t TargetPC) {
    if (!ptc_compat::isPTCAbiV2())
      return;
    if (!isValidQEMUV2IndirectTarget(TargetPC, tmpVA, JumpTargets))
      return;
    QEMUV2FrontierGPRs[TargetPC] = QEMUV2KnownGPRs;
  };
  auto restoreQEMUV2FrontierGPRs = [&](uint64_t TargetPC) {
    if (!ptc_compat::isPTCAbiV2())
      return;
    auto It = QEMUV2FrontierGPRs.find(TargetPC);
    if (It == QEMUV2FrontierGPRs.end())
      return;
    QEMUV2KnownGPRs = It->second;
  };
  // Restore the coordinator's register snapshot before exploring the seed, so
  // the interior seed block decodes with valid pointer registers. ptc is the
  // (COW-inherited) global QEMU env, so writing ptc.regs sets the concrete
  // state the next ptc.translate() uses.
  if (ParallelConfig.WorkerMode && ParallelConfig.HasSeedRegs
      && ptc.regs != nullptr) {
    for (int i = 0; i < 16; i++)
      ptc.regs[i] = ParallelConfig.SeedRegs[i];
  }
	  while (Entry != nullptr) {
	    jjj++;
	    JumpTargets.haveBB = Entry->empty() ? 0 : 1;
    if (!JumpTargets.haveBB)
      restoreQEMUV2FrontierGPRs(VirtualAddress);
	    BlockBRs = nullptr;
    BlockPCs.clear();
    DynamicVirtualAddress = 0;
    if(!JumpTargets.haveBB){
      Builder.SetInsertPoint(Entry);
      BlockBRs = Builder.GetInsertBlock();
     // TODO: what if create a new instance of an InstructionTranslator here?
     Translator.reset();
     Translator.branchreset();
    }

    // TODO: rename this type
    PTCInstructionListPtr InstructionList(new PTCInstructionList());
    size_t ConsumedSize = 0;
    bool TranslatedThisBlock = false;
    uint64_t V2CSVIndirectTargetPC = 0;
    bool HasV2CSVIndirectTarget = false;
    bool V2CSVIndirectTargetFromMemory = false;
    std::vector<uint64_t> V2CSVAdditionalDataFieldTargets;
    std::vector<uint64_t> V2CSVAdditionalJumpTableTargets;
    std::vector<uint64_t> V2CSVAdditionalFunctionPointerStoreTargets;

    if(traverseFLAG && !JumpTargets.haveBB){
      if (!JumpTargets.isPC(VirtualAddress)
          || JumpTargets.isOutOfAddrRange(VirtualAddress)) {
        errs() << "runnable-lift: skipping invalid translate pc=0x"
               << Twine::utohexstr(VirtualAddress) << "\n";
        if (Entry != nullptr && Entry->empty()) {
          Builder.SetInsertPoint(Entry);
          Builder.CreateUnreachable();
        }
        std::tie(VirtualAddress, Entry) = JumpTargets.peek();
        continue;
      }
      runnable_log(TranslatePCLog,
                   "Translating bb." << JumpTargets.nameForAddress(VirtualAddress));
      ConsumedSize = translatePTCBlock(VirtualAddress,
                                       Binary,
                                       InstructionList.get(),
                                       &DynamicVirtualAddress);
      TranslatedThisBlock = true;
      tmpVA = VirtualAddress;
    }
    if(traverseFLAG && JumpTargets.haveBB){
      ptc_instruction_list_malloc(InstructionList.get());
      if (ParallelConfig.DynamicParallel) {
        if (LastHaveBBVA == VirtualAddress)
          RepeatedHaveBBCount++;
        else {
          LastHaveBBVA = VirtualAddress;
          RepeatedHaveBBCount = 1;
        }
        if (RepeatedHaveBBCount > ParallelHaveBBRepeatLimit) {
          if (ParallelConfig.WorkerMode) {
            errs() << "parallel worker loop guard stop repeated haveBB pc=0x"
                   << Twine::utohexstr(VirtualAddress)
                   << " repeats=" << RepeatedHaveBBCount << "\n";
            break;
          } else {
            errs() << "parallel loop guard skip repeated haveBB pc=0x"
                   << Twine::utohexstr(VirtualAddress)
                   << " repeats=" << RepeatedHaveBBCount << "\n";
            JumpTargets.haveBB = 0;
            DynamicVirtualAddress = 0;
            Entry = nullptr;
            PreferBranchFrontier = !JumpTargets.BranchTargets.empty();
          }
        }
      }
    } else {
      RepeatedHaveBBCount = 0;
    }

    if(!JumpTargets.haveBB){
    if ((TranslatedThisBlock && ConsumedSize == 0)
        || InstructionList->instruction_count == 0
        || InstructionList->instructions == nullptr) {
      failInvalidPTCInstructionList(VirtualAddress,
                                    ConsumedSize,
                                    DynamicVirtualAddress,
                                    *InstructionList);
    }

    JumpTargets.haveBaseDatainRegs(BaseData);

    if (!ptc_compat::normalizePTCV2InstructionList(ptc,
                                                   InstructionList.get())) {
      createNoArgCall(Builder, AbortTy, AbortFunction);
      Builder.CreateUnreachable();
      break;
    }

    SmallSet<unsigned, 1> ToIgnore;
    ToIgnore = Translator.preprocess(InstructionList.get());

    bool CanDumpPTC = true;
    if (PTCLog.isEnabled()) {
      for (unsigned k = 0; k < InstructionList->instruction_count; k++) {
        if (Translator.validateOpcode(&InstructionList->instructions[k],
                                      false) == InstructionTranslator::Abort) {
          CanDumpPTC = false;
          break;
        }
      }
    }

    if (PTCLog.isEnabled() && CanDumpPTC) {
      std::stringstream Stream;
      dumpTranslation(Stream, InstructionList.get());
      PTCLog << Stream.str() << DoLog;
    }

    Variables.newFunction(Delimiter, InstructionList.get());
    unsigned j = 0;
    MDNode *MDOriginalInstr = nullptr;
    bool StopTranslation = false;
    uint64_t PC = VirtualAddress;
    uint64_t EndPC = VirtualAddress + ConsumedSize;
    if (ptc_compat::isPTCAbiV2()
        && DynamicVirtualAddress > VirtualAddress
        && Binary.getAddressData(DynamicVirtualAddress))
      EndPC = DynamicVirtualAddress;
    uint64_t NextPC = EndPC;
    const auto InstructionCount = InstructionList->instruction_count;
    using IT = InstructionTranslator;
    IT::TranslationResult Result;
    bool ForceNewBlock = false;

    unsigned FirstDebugIndex = InstructionCount;
    for (unsigned k = 0; k < InstructionCount; k++) {
      PTCInstruction *I = &InstructionList->instructions[k];
      if (I->opc == PTC_INSTRUCTION_op_debug_insn_start
          && ToIgnore.count(k) == 0) {
        FirstDebugIndex = k;
        break;
      }
    }

    if (ptc_compat::isPTCAbiV2() && FirstDebugIndex != InstructionCount) {
      PTCInstruction *Instruction = &InstructionList->instructions[FirstDebugIndex];
      uint64_t ReturnedPC = canonicalizePTCDebugPC(Instruction->args[0], Binary);
      if (ReturnedPC != VirtualAddress) {
        errs() << "runnable-lift: rejected PTC returned block pc divergence"
               << " requested=0x" << Twine::utohexstr(VirtualAddress)
               << " returned=0x" << Twine::utohexstr(ReturnedPC) << "\n";
        createNoArgCall(Builder, AbortTy, AbortFunction);
        Builder.CreateUnreachable();
        StopTranslation = true;
      }
    }

    if (!StopTranslation && FirstDebugIndex != InstructionCount) {
      PTCInstruction *NextInstruction = nullptr;
      for (unsigned k = FirstDebugIndex + 1; k < InstructionCount; k++) {
        PTCInstruction *I = &InstructionList->instructions[k];
        if (I->opc == PTC_INSTRUCTION_op_debug_insn_start
            && ToIgnore.count(k) == 0) {
          NextInstruction = I;
          break;
        }
      }
      PTCInstruction *Instruction = &InstructionList->instructions[FirstDebugIndex];
      std::tie(Result,
               MDOriginalInstr,
               PC,
               NextPC) = Translator.newInstruction(Instruction,
                                                   NextInstruction,
                                                   EndPC,
                                                   true,
                                                   false);
      if (Result != IT::Abort && FirstOriginalInstrSeed == nullptr)
        FirstOriginalInstrSeed = MDOriginalInstr;
      if (Result == IT::Abort) {
        createNoArgCall(Builder, AbortTy, AbortFunction);
        Builder.CreateUnreachable();
        StopTranslation = true;
      }
      BlockPCs.push_back(PC);
      // QEMU v2 sidecar payloads can contain TB prologue ops before the first
      // debug_insn_start. They are not separate guest instructions, but they
      // define temps/control flow used by the first real instruction. Emit the
      // first newpc marker, then translate those pre-debug ops without creating
      // extra coverage entries.
      j = FirstDebugIndex == 0 ? 1 : 0;
    }

    // TODO: shall we move this whole loop in InstructionTranslator?
    for (; j < InstructionCount && !StopTranslation; j++) {
      if (ToIgnore.count(j) != 0)
        continue;
      if (j == FirstDebugIndex)
        continue;

      PTCInstruction Instruction = InstructionList->instructions[j];
      PTCOpcode Opcode = Instruction.opc;

      Blocks.clear();
      Blocks.push_back(Builder.GetInsertBlock());

      Result = Translator.validateOpcode(&Instruction);
      if (Result == IT::Abort) {
        createNoArgCall(Builder, AbortTy, AbortFunction);
        Builder.CreateUnreachable();
        StopTranslation = true;
        continue;
      }

      switch (Opcode) {
      case PTC_INSTRUCTION_op_discard:
        // Instructions we don't even consider
        break;
      case PTC_INSTRUCTION_op_debug_insn_start: {
        // Find next instruction, if there is one
        PTCInstruction *NextInstruction = nullptr;
        for (unsigned k = j + 1; k < InstructionCount; k++) {
          PTCInstruction *I = &InstructionList->instructions[k];
          if (I->opc == PTC_INSTRUCTION_op_debug_insn_start
              && ToIgnore.count(k) == 0) {
            NextInstruction = I;
            break;
          }
        }

        std::tie(Result,
                 MDOriginalInstr,
                 PC,
                 NextPC) = Translator.newInstruction(&Instruction,
                                                     NextInstruction,
                                                     EndPC,
                                                     false,
                                                     ForceNewBlock);
        ForceNewBlock = false;
	BlockPCs.push_back(PC);
      } break;
      case PTC_INSTRUCTION_op_call: {
        Result = Translator.translateCall(&Instruction, PC);

        // Sometimes libtinycode terminates a basic block with a call, in this
        // case force a fallthrough
        auto &IL = InstructionList;
        if (j == IL->instruction_count - 1) {
          BasicBlock *Target = JumpTargets.registerJT(EndPC,
                                                      JTReason::PostHelper);
          Builder.CreateBr(notNull(Target));
        }

      } break;

      default:
        Result = Translator.translate(&Instruction, PC, NextPC);
        break;
      }

      switch (Result) {
      case IT::Success:
        // No-op
        break;
      case IT::Abort:
        createNoArgCall(Builder, AbortTy, AbortFunction);
        Builder.CreateUnreachable();
        StopTranslation = true;
        continue;
      case IT::Stop:
        StopTranslation = true;
        break;
      case IT::ForceNewPC:
        ForceNewBlock = true;
        break;
      }

      // Create a new metadata referencing the PTC instruction we have just
      // translated
      std::stringstream PTCStringStream;
      dumpInstruction(PTCStringStream, InstructionList.get(), j);
      std::string PTCString = PTCStringStream.str() + "\n";
      MDString *MDPTCString = MDString::get(Context, PTCString);
      MDNode *MDPTCInstr = MDNode::getDistinct(Context, MDPTCString);

      // Set metadata for all the new instructions
      for (BasicBlock *Block : Blocks) {
        BasicBlock::iterator I = Block->end();
        while (I != Block->begin() && !(--I)->hasMetadata()) {
          I->setMetadata(OriginalInstrMDKind, MDOriginalInstr);
          I->setMetadata(PTCInstrMDKind, MDPTCInstr);
        }
      }
    } // End loop over instructions

    if (ForceNewBlock)
      JumpTargets.registerJT(EndPC, JTReason::PostHelper);

    Translator.finalizePendingLabelBlocks();

    // We might have a leftover block, probably due to the block created after
    // the last call to exit_tb
    auto *LastBlock = Builder.GetInsertBlock();
    if (LastBlock->empty()){
      LastBlock->eraseFromParent();}
    else if (!LastBlock->rbegin()->isTerminator()) {
      // Something went wrong, probably a mistranslation
      Builder.CreateUnreachable();
    }
    JumpTargets.SetBlockSize(tmpVA, NextPC);

	    if(*ptc.isDirectJmp or *ptc.isIndirectJmp or *ptc.isIndirect or *ptc.isRet)
	      JumpTargets.harvestNextAddrofBr();

    if (ptc_compat::isPTCAbiV2()) {
		      HasV2CSVIndirectTarget =
		        updateQEMUV2CSVConstantState(InstructionList.get(),
		                                     QEMUV2KnownGPRs,
		                                     QEMUV2ConcreteFunctionPointerWrites,
		                                     QEMUV2SymbolicFunctionPointerWrites,
		                                     tmpVA,
		                                     JumpTargets,
		                                     V2CSVIndirectTargetPC,
	                                     V2CSVIndirectTargetFromMemory,
	                                     V2CSVAdditionalDataFieldTargets,
	                                     V2CSVAdditionalJumpTableTargets,
	                                     V2CSVAdditionalFunctionPointerStoreTargets);
	      auto RegisterAdditionalQEMUV2Targets =
	        [&](const std::vector<uint64_t> &Targets, const char *Kind) {
	      for (uint64_t TargetPC : Targets) {
	        if (!isValidQEMUV2IndirectTarget(TargetPC, tmpVA, JumpTargets))
	          continue;
	        rememberQEMUV2FrontierGPRs(TargetPC);
	        if (JumpTargets.registerJT(TargetPC, JTReason::GlobalData) != nullptr) {
	          errs() << "runnable-lift: Recovered QEMU v2 " << Kind
	                 << " indirect target pc=0x"
	                 << Twine::utohexstr(TargetPC)
	                 << " from block=0x" << Twine::utohexstr(tmpVA) << "\n";
	          runnable_log(TranslatePCLog,
	                       "Recovered QEMU v2 " << Kind
	                         << " indirect target pc=0x"
	                         << hexValue(TargetPC)
	                         << " from block=0x" << hexValue(tmpVA)
	                         << DoLog);
	        }
	      }
	        };
	      RegisterAdditionalQEMUV2Targets(V2CSVAdditionalDataFieldTargets,
	                                      "data-field");
	      RegisterAdditionalQEMUV2Targets(V2CSVAdditionalJumpTableTargets,
	                                      "jump-table");
	      RegisterAdditionalQEMUV2Targets(V2CSVAdditionalFunctionPointerStoreTargets,
	                                      "function-pointer-store");
    }

	    if(*ptc.isIllegal)
	      DynamicVirtualAddress = tmpVA + ConsumedSize;

    if(EntryFlag){
      EntryFlag = JumpTargets.handleEntryBlock(BlockBRs, tmpVA, SuspectEntryAddr, Translator.branchcontent(), getPath());
      if(EntryFlag){
        DynamicVirtualAddress = tmpVA + ConsumedSize;
        if(EntryFlag==3){
          auto size = JumpTargets.getBadBlockSize(DynamicVirtualAddress);
          DynamicVirtualAddress += size;
        }
      }
      else
        JumpTargets.harvestBlockPCs(BlockPCs, BlockBRs);
    }
    if(!BaseData.empty()){
      JumpTargets.handleBaseDataGadget(BlockBRs,BaseData);
      BaseData.clear();
    }
    }////?end if(!JumpTargets.haveBB)

	    if(EntryFlag and JumpTargets.haveBB){
      JumpTargets.handleSuspectDataRegion(SuspectEntryAddr,VirtualAddress);
      SuspectEntryAddr = 0;
      EntryFlag = false;
    }

            // Prefer draining saved branch-frontier states before resuming the
            // general unexplored/static worklist. This preserves the serial
            // queue discipline more closely when dynamic workers are active.
            if (PreferBranchFrontier
                && !ParallelConfig.WorkerMode
                && !ptc_compat::isPTCAbiV2()
                && !JumpTargets.BranchTargets.empty()) {
              VirtualAddress = 0;
              Entry = nullptr;
            } else {
	      std::tie(VirtualAddress, Entry) = JumpTargets.peek();
            }

    uint64_t V2ReturnPC = 0;
    bool HasV2DirectCallReturn =
      BlockBRs
      && extractQEMUV2DirectCallReturnPC(InstructionList.get(),
                                         tmpVA,
                                         DynamicVirtualAddress,
                                         JumpTargets,
                                         V2ReturnPC);
    if((*ptc.isCall || HasV2DirectCallReturn) and BlockBRs){
      if(!JumpTargets.isDataSegmAddr(ptc.regs[R_ESP])){
        ptc.regs[R_ESP] = *ptc.ElfStartStack - 512;
      }
      //if(!JumpTargets.isDataSegmAddr(ptc.regs[R_ESP]))
      //  ptc.regs[R_ESP] = ptc.regs[R_EBP];
      if (HasV2DirectCallReturn) {
        if (JumpTargets.registerJT(V2ReturnPC, JTReason::ReturnAddress) == nullptr) {
          errs() << "runnable-lift: failed to register QEMU v2 direct-call"
                 << " return target pc=0x" << Twine::utohexstr(V2ReturnPC)
                 << " from block=0x" << Twine::utohexstr(tmpVA) << "\n";
          runnable_abort("Failed to register QEMU v2 direct-call return target");
        }
        JumpTargets.harvestCallBasicBlock(BlockBRs, tmpVA, V2ReturnPC);
      } else {
        JumpTargets.harvestCallBasicBlock(BlockBRs,tmpVA);
      }
      if (ParallelConfig.WorkerMode)
        JumpTargets.BranchTargets.clear();
      if (ptc_compat::isPTCAbiV2())
        JumpTargets.BranchTargets.clear();
      *ptc.isCall = 0;
    }

	    if(!EntryFlag){
      if(*ptc.exception_syscall == getEffectiveSyscallExceptionCode(Arch)){
        if(ExeInit){
          if(ptc.regs[R_EAX]==20){
              if(ExeNums==0)
              traverseFLAG = 1;
  	    if(ExeNums!=0)
  	      ExeNums = ExeNums-1;
  	}
        }
        DynamicVirtualAddress = traverseFLAG ? *ptc.syscall_next_eip:ptc.do_syscall2();
        *ptc.exception_syscall = -1;
        if(DynamicVirtualAddress == 0 && traverseFLAG
           && !ptc_compat::isPTCAbiV2()
           && !JumpTargets.BranchTargets.empty()){
          JumpTargets.haveBB = 0;
          BlockBRs = nullptr;
          std::tie(jtVirtualAddress, srcBB, srcAddr) = JumpTargets.BranchTargets.front();
          if (trySpawnBranchWorker(jtVirtualAddress, JumpTargets.BranchTargets)) {
            DynamicVirtualAddress = 0;
            BaseData.clear();
            PreferBranchFrontier = false;
          } else {
            JumpTargets.BranchTargets.erase(JumpTargets.BranchTargets.begin());
            activateBranchFrontierState();
            DynamicVirtualAddress = jtVirtualAddress;
            PreferBranchFrontier = true;
          }
        }
      }
      if(BlockBRs and !JumpTargets.haveBB and *ptc.exception_syscall == 11){
        DynamicVirtualAddress = JumpTargets.handleIllegalMemoryAccess(BlockBRs,tmpVA,ConsumedSize);
        *ptc.exception_syscall = -1;
      }
      bool QEMUV2IndirectTransfer =
        ptc_compat::isPTCAbiV2() && (*ptc.isIndirect || *ptc.isIndirectJmp);
      if(QEMUV2IndirectTransfer) {
        if(DynamicVirtualAddress != 0) {
          if(isValidQEMUV2IndirectTarget(DynamicVirtualAddress,
                                         tmpVA,
                                         JumpTargets)) {
            runnable_log(TranslatePCLog,
                         "Using QEMU v2 dynamic indirect target pc=0x"
                           << hexValue(DynamicVirtualAddress)
                           << " from block=0x" << hexValue(tmpVA)
                           << DoLog);
          } else {
            DynamicVirtualAddress = 0;
          }
        }
      } else if(StaticAddrFlag and (*ptc.isIndirect or *ptc.isIndirectJmp))
        DynamicVirtualAddress = 0;
      if(BlockBRs && DynamicVirtualAddress == 0
         && HasV2CSVIndirectTarget
         && isValidQEMUV2IndirectTarget(V2CSVIndirectTargetPC,
                                        tmpVA,
                                        JumpTargets)) {
	        DynamicVirtualAddress = V2CSVIndirectTargetPC;
	        errs() << "runnable-lift: Recovered QEMU v2 "
	               << (V2CSVIndirectTargetFromMemory ? "memory" : "CSV")
	               << " indirect target pc=0x"
	               << Twine::utohexstr(V2CSVIndirectTargetPC)
	               << " from block=0x" << Twine::utohexstr(tmpVA) << "\n";
	        runnable_log(TranslatePCLog,
	                     "Recovered QEMU v2 "
	                       << (V2CSVIndirectTargetFromMemory ? "memory" : "CSV")
	                       << " indirect target pc=0x"
	                       << hexValue(V2CSVIndirectTargetPC)
	                       << " from block=0x" << hexValue(tmpVA)
	                       << DoLog);
      }
      if(BlockBRs && DynamicVirtualAddress == 0) {
        uint64_t V2IndirectTargetPC = 0;
        if (extractQEMUV2IndirectTargetPC(InstructionList.get(),
                                          tmpVA,
                                          JumpTargets,
                                          V2IndirectTargetPC)) {
          DynamicVirtualAddress = V2IndirectTargetPC;
          errs() << "runnable-lift: Recovered QEMU v2 indirect target pc=0x"
                 << Twine::utohexstr(V2IndirectTargetPC)
                 << " from block=0x" << Twine::utohexstr(tmpVA) << "\n";
          runnable_log(TranslatePCLog,
                       "Recovered QEMU v2 indirect target pc=0x"
                         << hexValue(V2IndirectTargetPC)
                         << " from block=0x" << hexValue(tmpVA)
                         << DoLog);
        }
      }

      if(!ptc_compat::isPTCAbiV2() && !JumpTargets.haveBB)
        JumpTargets.harvestStaticAddr(BlockBRs);
      if(!ptc_compat::isPTCAbiV2() && BlockBRs)
        JumpTargets.harvestJumpTableAddr(BlockBRs,tmpVA);
      //if(!JumpTargets.haveBB and *ptc.isIndirect)
      //  JumpTargets.handleIndirectCall(BlockBRs,tmpVA, StaticAddrFlag);
      //if(!JumpTargets.haveBB and *ptc.isIndirectJmp)
      //  JumpTargets.handleIndirectJmp(BlockBRs,tmpVA, StaticAddrFlag);
      if(*ptc.isRet and !JumpTargets.haveBB){
        std::map<uint64_t, bool>::iterator it = JumpTargets.CallBranches.find(DynamicVirtualAddress);
        if(it == JumpTargets.CallBranches.end())
          DynamicVirtualAddress = 0;
      }
      if(!JumpTargets.haveBB && DynamicVirtualAddress != 0
         && JumpTargets.isOutOfAddrRange(DynamicVirtualAddress))
        DynamicVirtualAddress = 0;
    }

	    if(traverseFLAG){
    //handle invalid address
    if(!JumpTargets.isPC(DynamicVirtualAddress)
       and !JumpTargets.haveBB)
    {
//      JumpTargets.handleIllegalJumpAddress(BlockBRs,tmpVA);
      DynamicVirtualAddress = 0;

    }

	    // Some branch destination addr is 0
		    if((JumpTargets.haveBB || DynamicVirtualAddress == 0 ) and
				    !JumpTargets.BranchTargets.empty()
            && !ptc_compat::isPTCAbiV2())
	    {
	      BlockBRs = nullptr;
	      // if occure a translated BB, traversing next branch
	      std::tie(jtVirtualAddress, srcBB, srcAddr) = JumpTargets.BranchTargets.front();
              if (trySpawnBranchWorker(jtVirtualAddress, JumpTargets.BranchTargets)) {
                JumpTargets.haveBB = 0;
                DynamicVirtualAddress = 0;
                BaseData.clear();
                PreferBranchFrontier = false;
              } else if (ParallelConfig.WorkerMode) {
                DynamicVirtualAddress = jtVirtualAddress;
                BaseData.clear();
              } else {
	        JumpTargets.BranchTargets.erase(JumpTargets.BranchTargets.begin());
	        activateBranchFrontierState();
	        DynamicVirtualAddress = jtVirtualAddress;
	        BaseData.clear();
                PreferBranchFrontier = true;
              }
	    }

                    if (DynamicVirtualAddress == tmpVA)
                      DynamicVirtualAddress = 0;

			    if(DynamicVirtualAddress){
		      rememberQEMUV2FrontierGPRs(DynamicVirtualAddress);
		      auto tmpBB = JumpTargets.registerJT(DynamicVirtualAddress,JTReason::GlobalData);
      //JumpTargets.isContainIndirectInst(DynamicVirtualAddress,tmpVA,tmpBB);
      if(JumpTargets.haveBB){
        // If have translated BB, give Entry an arbitrary value
        Entry = tmpBB;
        VirtualAddress = DynamicVirtualAddress;
        BaseData.clear();
      }
      else{
        std::tie(VirtualAddress, Entry) = JumpTargets.peek();
        if(srcBB)
	  JumpTargets.pushpartCFGStack(Entry,VirtualAddress,srcBB,srcAddr);
        srcBB = nullptr;
	JumpTargets.haveBB = 0;
      }
		      if(BlockBRs != nullptr and !EntryFlag){
		        auto branchLabeledcontent = Translator.branchcontent();
	                if (!ptc_compat::isPTCAbiV2()) {
		          JumpTargets.harvestbranchBasicBlock(VirtualAddress,
				             tmpVA,
	                                     BlockBRs,
		                                     Translator.branchsize(),
		                                     branchLabeledcontent);
	                } else if (Translator.branchsize() > 1) {
	                  runnable_log(TranslatePCLog,
	                               "Skipping QEMU v2 static conditional branch"
	                               " frontier from block=0x" << hexValue(tmpVA)
	                               << " concrete-next=0x"
	                               << hexValue(VirtualAddress) << DoLog);
	                  JumpTargets.BranchTargets.clear();
	                }
	                if (ParallelConfig.WorkerMode)
	                  JumpTargets.BranchTargets.clear();
		      }
    }

    if(JumpTargets.BranchTargets.empty() and !EntryFlag) {
      DynamicVirtualAddress = 0;
      PreferBranchFrontier = false;
    }

    }////?end if(traverseFLAG)
    if(!JumpTargets.haveBB)
      JumpTargets.haveBaseDatainRegs(BaseData);

	    if(Entry==nullptr){
	      /*EntryFlag:
	       *    true/1 means: need to record first three addrs of Block
	       *    false means:  don't need the first three addrs of a Block
	       *    2 means:      callnext addr needs
	       *                  to record the first three addrs. */
	      if (!ptc_compat::isPTCAbiV2()) {
	        EntryFlag = JumpTargets.handleStaticAddr();
	        //StaticAddrFlag: means that entering check point mode
	        StaticAddrFlag = true;
	        std::tie(VirtualAddress, Entry) = JumpTargets.peek();
	        SuspectEntryAddr = EntryFlag ? VirtualAddress:0;
	      } else {
	        EntryFlag = 0;
	        StaticAddrFlag = false;
	        SuspectEntryAddr = 0;
	      }
	    }

		  } // End translations loop

	          waitForForkWorkers();
	  JumpTargets.handleEmbeddedDataAddr(getEmbeddedData());
  embeddedData();
  JumpTargets.TestSuspectDataRegion(getPath());

  outs()<<"\nRewrite Successful\n";
  JumpTargets.StatisticsLog(getPath());

  importHelperFunctionDeclaration("cpu_loop");

  legacy::PassManager CpuLoopPM;
  CpuLoopPM.add(new LoopInfoWrapperPass());
  CpuLoopPM.add(new CpuLoopFunctionPass());
  CpuLoopPM.run(*HelpersModule);

  // CpuLoopFunctionPass expects a variable name exception_index to exist
  GlobalVariable *ExceptionIndex = nullptr;
  intptr_t ExceptionIndexOffset =
    getEffectiveExceptionIndexOffset(Arch, Variables);
  if (ExceptionIndexOffset != 0)
    ExceptionIndex =
      Variables.getByEnvOffset(ExceptionIndexOffset, "exception_index").first;
  if (ExceptionIndex == nullptr)
    getOrCreateI32GlobalDefinition(*TheModule, "exception_index");

  // Handle some specific QEMU functions as no-ops or abort
  auto NoOpFunctionNames = make_array<const char *>("cpu_dump_state",
                                                    "cpu_exit",
                                                    "end_exclusive"
                                                    "fprintf",
                                                    "mmap_lock",
                                                    "mmap_unlock",
                                                    "pthread_cond_broadcast",
                                                    "pthread_mutex_unlock",
                                                    "pthread_mutex_lock",
                                                    "pthread_cond_wait",
                                                    "pthread_cond_signal",
                                                    "process_pending_signals",
                                                    "qemu_log_mask",
                                                    "qemu_thread_atexit_init",
                                                    "start_exclusive");
  auto AbortFunctionNames = make_array<const char *>("cpu_restore_state",
                                                     "cpu_mips_exec",
                                                     "gdb_handlesig",
                                                     "queue_signal",
                                                     // syscall.c
                                                     "do_ioctl_dm",
                                                     "print_syscall",
                                                     "print_syscall_ret",
                                                     // ARM cpu_loop
                                                     "cpu_abort",
                                                     "do_arm_semihosting",
                                                     "EmulateAll");

  // do_arm_semihosting: we don't care about semihosting
  // EmulateAll: requires access to the opcode

  // Import the function to initialize the CPUState, if present.
  // This is important on x86 architecture.
  if (HelpersModule->getFunction("initialize_env") != nullptr)
    importHelperFunctionDeclaration("initialize_env");

  // From syscall.c
  new GlobalVariable(*TheModule,
                     Type::getInt32Ty(Context),
                     false,
                     GlobalValue::CommonLinkage,
                     ConstantInt::get(Type::getInt32Ty(Context), 0),
                     StringRef("do_strace"));

  for (auto Name : NoOpFunctionNames)
    replaceFunctionWithRet(HelpersModule->getFunction(Name), 0);

  for (auto Name : AbortFunctionNames) {
    Function *TheFunction = HelpersModule->getFunction(Name);
    if (TheFunction != nullptr) {
      runnable_assert(HelpersModule->getFunction("abort") != nullptr);
      BasicBlock *NewBody = replaceFunction(TheFunction);
      CallInst::Create(HelpersModule->getFunction("abort"), {}, NewBody);
      new UnreachableInst(Context, NewBody);
    }
  }

  replaceFunctionWithRet(HelpersModule->getFunction("page_check_range"), 1);
  replaceFunctionWithRet(HelpersModule->getFunction("page_get_flags"),
                         0xffffffff);

  if (ptc_compat::isPTCAbiV2()) {
    promoteQEMUV2HelperAllocas(*HelpersModule);
    errs() << "runnable-lift: promoted QEMU v2 helper allocas before "
           << "CPUState access analysis\n";
  }

  // HACK: the LLVM linker does not import non-static functions anymore if
  //       LinkOnlyNeeded is specified. We don't want this so mark all the
  //       non-static symbols not directly imported as static.
  {
    std::set<StringRef> Declarations;
    for (auto &F : TheModule->functions())
      if (F.isDeclaration())
        Declarations.insert(F.getName());

    for (auto &F : HelpersModule->functions())
      if (not F.isDeclaration() and Declarations.count(F.getName()) == 0
          and F.hasExternalLinkage())
        F.setLinkage(GlobalValue::InternalLinkage);

    Declarations.clear();
    for (auto &GV : TheModule->globals())
      if (GV.isDeclaration())
        Declarations.insert(GV.getName());

    for (auto &GV : HelpersModule->globals())
      if (not GV.isDeclaration() and Declarations.count(GV.getName()) == 0
          and GV.hasExternalLinkage())
        GV.setLinkage(GlobalValue::InternalLinkage);
  }

  if (not NoLink) {
    Linker TheLinker(*TheModule);
    bool Result = TheLinker.linkInModule(std::move(HelpersModule),
                                         Linker::LinkOnlyNeeded);
    runnable_assert(!Result, "Linking failed");
  }

  // Add a call to the function to initialize the CPUState, if present.
  // This is important on x86 architecture.
  // We only add the call after the Linker has imported the
  // initialize_env function from the helpers, because the declaration
  // imported before with importHelperFunctionDeclaration() only has
  // stub types and injecting the CallInst earlier would break
  if (Function *InitEnv = TheModule->getFunction("initialize_env")) {
    runnable_assert(not InitEnv->getFunctionType()->isVarArg());
    runnable_assert(InitEnv->getFunctionType()->getNumParams() == 1);
    auto *CPUStateType = InitEnv->getFunctionType()->getParamType(0);
    Instruction *InsertBefore = InitEnvInsertPoint;
    auto *AddressComputation = Variables.computeEnvAddress(CPUStateType,
                                                           InsertBefore);
    CallInst::Create(InitEnv, { AddressComputation }, "", InsertBefore);
  }

  Variables.setDataLayout(&TheModule->getDataLayout());

  const bool IsPTCAbiV2 = ptc_compat::isPTCAbiV2();
  bool NewPCMarkersFinalized = false;

  if (IsPTCAbiV2) {
    JumpTargets.finalizeJumpTargets();
    Translator.finalizeNewPCMarkers(CoveragePath, true);
    NewPCMarkersFinalized = true;

    size_t RootInstructionCountBeforeLateOpt =
      countInstructions(*MainFunction);
    size_t RootAllocaCountBeforeLateOpt = countAllocas(*MainFunction);
    bool UseLargeRootFastPath =
      RootInstructionCountBeforeLateOpt
        >= QEMUV2LargeRootSROAInstructionThreshold;

    legacy::FunctionPassManager LateRootFPM(TheModule.get());
    if (UseLargeRootFastPath) {
      LateRootFPM.add(createPromoteMemoryToRegisterPass());
    } else {
      LateRootFPM.add(createSROAPass());
    }
    LateRootFPM.add(createDeadCodeEliminationPass());
    LateRootFPM.doInitialization();
    auto LateRootOptStart =
      startLiftPhaseTimer(UseLargeRootFastPath
                            ? "qemu-v2-root-mem2reg-dce"
                            : "qemu-v2-root-sroa-dce");
    LateRootFPM.run(*MainFunction);
    LateRootFPM.doFinalization();
    finishLiftPhaseTimer(UseLargeRootFastPath
                           ? "qemu-v2-root-mem2reg-dce"
                           : "qemu-v2-root-sroa-dce",
                         LateRootOptStart);
    errs() << "runnable-lift: ran QEMU v2 root-only "
           << (UseLargeRootFastPath ? "mem2reg" : "SROA")
           << " after removing runtime newpc markers"
           << " root_instructions_before=" << RootInstructionCountBeforeLateOpt
           << " root_allocas_before=" << RootAllocaCountBeforeLateOpt
           << " root_instructions_after=" << countInstructions(*MainFunction)
           << " root_allocas_after=" << countAllocas(*MainFunction)
           << " large_root_threshold="
           << QEMUV2LargeRootSROAInstructionThreshold << "\n";

    redirectQEMUV2ConstantDispatcherBranches(MainFunction, JumpTargets);
  }

  legacy::PassManager PM;
  if (!IsPTCAbiV2)
    PM.add(createSROAPass());
  PM.add(new CpuLoopExitPass(&Variables));
  PM.add(Variables.createCPUStateAccessAnalysisPass());
  PM.add(createDeadCodeEliminationPass());
  auto ModulePMStart = startLiftPhaseTimer("post-root-module-pm");
  PM.run(*TheModule);
  finishLiftPhaseTimer("post-root-module-pm", ModulePMStart);

  if (!IsPTCAbiV2)
    JumpTargets.finalizeJumpTargets();

  purgeDeadBlocks(MainFunction);

  JumpTargets.createJTReasonMD();

  // Link early-linked.c
  // TODO: moving this too earlier seems to break things
  {
    Linker TheLinker(*TheModule);
    bool Result = TheLinker.linkInModule(std::move(EarlyLinkedModule),
                                         Linker::None);
    runnable_assert(!Result, "Linking failed");
  }

  ExternalJumpsHandler JumpOutHandler(Binary, JumpTargets, *MainFunction);
  JumpOutHandler.createExternalJumpsHandler();
  materializeEmptyBasicBlocks(MainFunction);

  JumpTargets.noReturn().cleanup();

  if (!NewPCMarkersFinalized)
    Translator.finalizeNewPCMarkers(CoveragePath, IsPTCAbiV2);
  if (FirstOriginalInstrSeed != nullptr && !EntryBlock->empty()) {
    Instruction &Anchor = *EntryBlock->getFirstNonPHI();
    Anchor.setMetadata(OriginalInstrMDKind, FirstOriginalInstrSeed);
  }

  Variables.finalize();

  Debug->generateDebugInfo();
}

void CodeGenerator::embeddedData(){
  if (Binary.rodataStartAddr != 0 && Binary.ehframeEndAddr > Binary.rodataStartAddr)
    EmbeddedData[Binary.rodataStartAddr] =
      Binary.ehframeEndAddr - Binary.rodataStartAddr;

  if (ptc_compat::isPTCAbiV2()) {
    for (const SegmentInfo &Segment : Binary.segments()) {
      if (Segment.IsExecutable && Segment.IsReadable)
        EmbeddedData[Segment.StartVirtualAddress] = Segment.size();
    }
  } else {
    EmbeddedData[CodeStartAddress] = Binary.entryPoint() - CodeStartAddress;
  }

  //eliminate duplication region
  auto iter = EmbeddedData.begin();
  std::pair<uint64_t, size_t> pre(iter->first,iter->second);
  iter++;
  while(iter != EmbeddedData.end()){
    if((pre.first+pre.second) > iter->first){
        if(((pre.first+pre.second) - iter->first) < iter->second){
          auto it = iter--;
          it->second = iter->first + iter->second - pre.first;
          pre.second = it->second;
          EmbeddedData.erase(iter++);
        }else{
          EmbeddedData.erase(iter++);
        }
    }else{
      pre = std::make_pair(iter->first, iter->second);
      ++iter;
    }

  }

  //Prepare the linking info CSV
  if (LinkingInfoPath.size() == 0)
    LinkingInfoPath = OutputPath + ".li.csv";
  std::ofstream LinkingInfoStream;
  LinkingInfoStream.open(LinkingInfoPath,std::ofstream::out | std::ofstream::app);

  auto *Uint8Ty = Type::getInt8Ty(Context);

  for(const auto &embedded : EmbeddedData){

    if((embedded.first > CodeStartAddress) and (embedded.first < Binary.rodataStartAddr)){
      if(embedded.second>256*1024*1024)
        continue;
    }
    std::stringstream NameStream;
    NameStream <<"o_"<<"r_"<<std::hex<<embedded.first;
    // Get data and size
    auto *DataType = ArrayType::get(Uint8Ty, embedded.second);
    Constant *TheData = nullptr;
    const SegmentInfo *Segment = nullptr;
    for (const SegmentInfo &Candidate : Binary.segments()) {
      if (Candidate.contains(embedded.first, embedded.second)) {
        Segment = &Candidate;
        break;
      }
    }
    if (Segment == nullptr || !Segment->IsReadable) {
      errs() << "runnable-lift: skipping embedded data for pc=0x"
             << Twine::utohexstr(embedded.first)
             << " size=" << embedded.second
             << " because no readable binary segment covers that range\n";
      continue;
    }
    size_t Offset = embedded.first - Segment->StartVirtualAddress;
    llvm::ArrayRef<uint8_t> Data = Segment->Data.slice(Offset, embedded.second);
    TheData = ConstantDataArray::get(Context, Data);
    // Create a new global variable
    auto Variable = new GlobalVariable(*TheModule,
		                          DataType,
					  false,
					  GlobalValue::ExternalLinkage,
					  TheData,
					  NameStream.str());
    // Force alignment to 1 and assign the variable to a specific section
    setGlobalAlignment(Variable, 1);
    Variable->setSection("." + NameStream.str());

    // Write the linking info CSV
    LinkingInfoStream << "." << NameStream.str() << ",0x" << std::hex
                      << embedded.first << ",0x" << std::hex
                      << embedded.first+embedded.second << "\n";
  }
  LinkingInfoStream.close();

}

void CodeGenerator::serialize() {
  // Ask the debug handler if it already has a good copy of the IR, if not dump
  // it
  if (!Debug->copySource()) {
    std::ofstream Output(OutputPath);
    Debug->print(Output, false);
  }
  if (!ParallelConfig.WorkerMode)
    mergeForkWorkerFragments();
}

std::string CodeGenerator::workerOutputPath(uint64_t SeedPC) const {
  std::ostringstream Path;
  if (!ParallelConfig.FragmentDir.empty())
    Path << ParallelConfig.FragmentDir << "/";
  Path << "worker_" << hexValue(SeedPC) << ".ll";
  return Path.str();
}

void CodeGenerator::configureOutputArtifacts(const std::string &Output) {
  OutputPath = Output;
  CoveragePath = OutputPath + ".coverage.csv";
  BBSummaryPath = OutputPath + ".bbsummary.csv";
  LinkingInfoPath = OutputPath + ".li.csv";
}

void CodeGenerator::switchToWorkerOutput(uint64_t SeedPC) {
  if (!ParallelConfig.FragmentDir.empty()) {
    std::string Command = "mkdir -p \"" + ParallelConfig.FragmentDir + "\"";
    ::system(Command.c_str());
  }
  configureOutputArtifacts(workerOutputPath(SeedPC));
  Debug.reset(new DebugHelper(OutputPath, TheModule.get(), DebugInfo, DebugPath));
}

int CodeGenerator::runFreshBranchWorker(uint64_t SeedPC) {
  std::string WorkerOutput = workerOutputPath(SeedPC);
  std::string WorkerStdout = WorkerOutput + ".stdout.log";
  std::string WorkerStderr = WorkerOutput + ".stderr.log";
  ::freopen(WorkerStdout.c_str(), "w", stdout);
  ::freopen(WorkerStderr.c_str(), "w", stderr);
  ::setenv("RUNNABLE_PARALLEL_WORKER_MODE", "1", 1);
  uint32_t QueueDepth = ptc_compat::queueDepth(ptc);
  bool LegacyQueueAssumed = !ptc_compat::supportsQueueDepth();
  if (LegacyQueueAssumed && PendingWorkerStateDrops != 0) {
    while (PendingWorkerStateDrops != 0) {
      ptc_compat::deleteCPULINEState(ptc);
      PendingWorkerStateDrops--;
    }
  }
  if (QueueDepth != 0 || LegacyQueueAssumed) {
    ptc_compat::deleteCPULINEState(ptc);
  }

  if (!ParallelConfig.FragmentDir.empty()) {
    std::string Command = "mkdir -p \"" + ParallelConfig.FragmentDir + "\"";
    ::system(Command.c_str());
  }

  CoveragePath = WorkerOutput + ".coverage.csv";
  BBSummaryPath = WorkerOutput + ".bbsummary.csv";
  LinkingInfoPath = WorkerOutput + ".li.csv";

  ParallelOptions WorkerOptions = ParallelConfig;
  WorkerOptions.DynamicParallel = true;
  WorkerOptions.WorkerMode = true;
  WorkerOptions.WorkerCount = 0;
  WorkerOptions.SeedPC = SeedPC;
  if (SeedRegsSnapshotValid) {
    WorkerOptions.HasSeedRegs = true;
    for (int i = 0; i < 16; i++)
      WorkerOptions.SeedRegs[i] = SeedRegsSnapshot[i];
  }

  BinaryFile WorkerBinary(ParallelConfig.InputPath, Binary.relocate(0));
  Architecture WorkerTargetArchitecture;
  llvm::LLVMContext WorkerContext;

  {
    CodeGenerator WorkerGenerator(WorkerBinary,
                                  WorkerTargetArchitecture,
                                  WorkerContext,
                                  WorkerOutput,
                                  HelpersPath,
                                  EarlyLinkedPath,
                                  WorkerOptions);
    WorkerGenerator.translate(SeedPC);
    WorkerGenerator.serialize();
  }

  return EXIT_SUCCESS;
}

void CodeGenerator::activateBranchFrontierState() {
  if (PendingWorkerStateDrops != 0) {
    errs() << "parallel parent drop-pending-states=" << PendingWorkerStateDrops
           << "\n";
    while (PendingWorkerStateDrops != 0) {
      ptc_compat::deleteCPULINEState(ptc);
      PendingWorkerStateDrops--;
    }
  }
  ptc_compat::deleteCPULINEState(ptc);
}

void CodeGenerator::pollFinishedForkWorkers(bool Block) {
  if (!ParallelConfig.DynamicParallel || ParallelConfig.WorkerMode)
    return;

  for (auto &Worker : ParallelWorkers) {
    if (Worker.Finished)
      continue;

    int Status = 0;
    pid_t Waited = waitpid(Worker.Pid, &Status, Block ? 0 : WNOHANG);
    if (Waited == 0)
      continue;
    if (Waited != Worker.Pid)
      continue;

    Worker.Finished = true;
    Worker.ExitCode = WIFEXITED(Status) ? WEXITSTATUS(Status) : -1;
    if (Worker.ExitCode == 0)
      ParallelWorkersSucceeded++;
    else
      ParallelWorkersFailed++;
  }
}

bool CodeGenerator::trySpawnBranchWorker(
  uint64_t SeedPC,
  std::vector<std::tuple<uint64_t, llvm::BasicBlock *, uint64_t>> &BranchTargets) {
  if (!ParallelConfig.DynamicParallel || ParallelConfig.WorkerMode)
    return false;
  if (ParallelConfig.WorkerCount == 0)
    return false;
  if (ParallelSpawnedSeeds.count(SeedPC) != 0) {
    if (ptc_compat::isPTCAbiV2() && !BranchTargets.empty()
        && std::get<0>(BranchTargets.front()) == SeedPC) {
      BranchTargets.erase(BranchTargets.begin());
      if (ptc_compat::hasDropCPUState(ptc))
        ptc_compat::dropCPUState(ptc);
      else
        PendingWorkerStateDrops++;
      return true;
    }
    return false;
  }

  pollFinishedForkWorkers(false);

  size_t ActiveWorkers = 0;
  for (const auto &Worker : ParallelWorkers)
    if (!Worker.Finished)
      ActiveWorkers++;
  if (ActiveWorkers >= ParallelConfig.WorkerCount
      && ptc_compat::isPTCAbiV2()) {
    pollFinishedForkWorkers(true);
    ActiveWorkers = 0;
    for (const auto &Worker : ParallelWorkers)
      if (!Worker.Finished)
        ActiveWorkers++;
  }
  if (ActiveWorkers >= ParallelConfig.WorkerCount)
    return false;

  // Snapshot the concrete register file at the branch point. The coordinator
  // has just decoded the block that branches to SeedPC, so ptc.regs holds the
  // register context on entry to the seed. The fresh worker restores this so
  // its interior seed block resolves pointer registers (rbx/rsp/...) instead
  // of failing the use-def check in handleEntryBlock (illegalEntry).
  if (ptc.regs != nullptr) {
    for (int i = 0; i < 16; i++)
      SeedRegsSnapshot[i] = ptc.regs[i];
    SeedRegsSnapshotValid = true;
  } else {
    SeedRegsSnapshotValid = false;
  }

  pid_t PID = fork();
  runnable_assert(PID >= 0, "failed to fork branch worker");
  if (PID == 0) {
    int Result = runFreshBranchWorker(SeedPC);
    ::_exit(Result);
  }

  BranchTargets.erase(BranchTargets.begin());
  if (ptc_compat::hasDropCPUState(ptc)) {
    ptc_compat::dropCPUState(ptc);
  } else if (!ptc_compat::isPTCAbiV2()) {
    PendingWorkerStateDrops++;
  }
  ParallelSpawnedSeeds.insert(SeedPC);
  std::ostringstream WorkerOutput;
  WorkerOutput << ParallelConfig.FragmentDir << "/worker_" << hexValue(SeedPC) << ".ll";
  ParallelWorkers.push_back({ static_cast<int>(PID), SeedPC, WorkerOutput.str(), -1, false });
  ParallelWorkersSpawned++;
  return true;
}

void CodeGenerator::waitForForkWorkers() {
  pollFinishedForkWorkers(true);
}

void CodeGenerator::mergeForkWorkerFragments() {
  if (!ParallelConfig.DynamicParallel || ParallelConfig.WorkerMode)
    return;
  if (ParallelWorkersSucceeded == 0)
    return;

  std::vector<std::string> CandidateScripts;
  appendMergeScriptPathCandidates(CandidateScripts);
  std::string RepoRoot = findRepoRootFromCwd();
  if (RepoRoot.empty())
    RepoRoot = findRepoRootFromExecutable();
  if (!RepoRoot.empty()) {
    CandidateScripts.push_back(RepoRoot + "/runnable/scripts/merge_dynamic_runnable_fragments.py");
    CandidateScripts.push_back(RepoRoot + "/scripts/merge_dynamic_runnable_fragments.py");
  }
  CandidateScripts.push_back("merge_dynamic_runnable_fragments.py");

  std::string ScriptPath;
  for (const auto &Candidate : CandidateScripts) {
    if (fileExists(Candidate)) {
      ScriptPath = Candidate;
      break;
    }
  }
  if (ScriptPath.empty()) {
    errs() << "runnable-lift: warning: dynamic-parallel worker fragments"
           << " were produced but merge_dynamic_runnable_fragments.py"
           << " was not found\n";
    return;
  }

  std::string TempOutput = OutputPath + ".merged.ll";
  std::string MergeSummary = OutputPath + ".merge.json";
  std::string MergeLog = OutputPath + ".merge.log";
  std::ostringstream EntryPC;
  EntryPC << "0x" << std::hex << Binary.entryPoint();
  std::ostringstream Command;
  Command << "python3 " << shellQuote(ScriptPath)
          << " --output " << shellQuote(TempOutput)
          << " --entry-pc " << EntryPC.str()
          << " --summary-out " << shellQuote(MergeSummary)
          << " " << shellQuote(OutputPath);
  for (const auto &Worker : ParallelWorkers) {
    if (Worker.ExitCode != 0)
      continue;
    Command << " " << shellQuote(Worker.OutputPath);
  }
  Command << " > " << shellQuote(MergeLog) << " 2>&1";
  int RC = ::system(Command.str().c_str());
  if (RC != 0) {
    errs() << "runnable-lift: warning: dynamic-parallel fragment merge failed"
           << " rc=" << RC
           << " log=" << MergeLog << "\n";
    return;
  }
  rename(TempOutput.c_str(), OutputPath.c_str());

  // Clean up worker fragment files after successful merge
  // (unless --keep-worker-fragments is set for debugging)
  if (!ParallelConfig.KeepWorkerFragments) {
    for (const auto &Worker : ParallelWorkers) {
      if (Worker.ExitCode == 0) {
        // Delete the worker .ll file
        unlink(Worker.OutputPath.c_str());
        // Delete associated log and CSV files
        std::string WorkerStdout = Worker.OutputPath + ".stdout.log";
        std::string WorkerStderr = Worker.OutputPath + ".stderr.log";
        std::string WorkerCov = Worker.OutputPath + ".coverage.csv";
        std::string WorkerBBSummary = Worker.OutputPath + ".bbsummary.csv";
        std::string WorkerLI = Worker.OutputPath + ".li.csv";
        unlink(WorkerStdout.c_str());
        unlink(WorkerStderr.c_str());
        unlink(WorkerCov.c_str());
        unlink(WorkerBBSummary.c_str());
        unlink(WorkerLI.c_str());
      }
    }
  }
}
