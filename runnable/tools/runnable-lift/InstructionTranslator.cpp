/// \file instructiontranslator.cpp
/// \brief This file implements the logic to translate a PTC instruction in to
///        LLVM IR.

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include "runnable/Support/Assert.h"
#include <cstdint>
#include <fstream>
#include <queue>
#include <set>
#include <sstream>

// LLVM includes
#include "llvm/ADT/Optional.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/raw_ostream.h"
#if LLVM_VERSION_MAJOR >= 10
#include "llvm/Support/Alignment.h"
#endif

// Local libraries includes
#include "runnable/Support/IRHelpers.h"
#include "runnable/Support/RandomAccessIterator.h"
#include "runnable/Support/Range.h"
#include "runnable/Support/Transform.h"

// Local includes
#include "InstructionTranslator.h"
#include "PTCInterface.h"
#include "VariableManager.h"

using namespace llvm;

using IT = InstructionTranslator;

static unsigned getCallArgCount(CallInst *Call) {
#if LLVM_VERSION_MAJOR >= 14
  return Call->arg_size();
#else
  return Call->getNumArgOperands();
#endif
}

namespace {

struct OpcodeMetadata {
  const char *Name = nullptr;
  unsigned OutArgs = 0;
  unsigned InArgs = 0;
  unsigned ConstArgs = 0;
  unsigned TotalArgs = 0;
  bool HasDefinition = false;
};

static OpcodeMetadata getOpcodeMetadata(PTCOpcode Opcode) {
  OpcodeMetadata Result;
  unsigned OpcodeId = static_cast<unsigned>(Opcode);
  if (OpcodeId >= static_cast<unsigned>(PTC_INSTRUCTION_NB_OPS)
      || ptc.opcode_defs == nullptr)
    return Result;

  PTCOpcodeDef &Definition = ptc.opcode_defs[OpcodeId];
  Result.Name = Definition.name;
  Result.OutArgs = Definition.nb_oargs;
  Result.InArgs = Definition.nb_iargs;
  Result.ConstArgs = Definition.nb_cargs;
  Result.TotalArgs = Definition.nb_args;
  Result.HasDefinition = true;
  return Result;
}

static unsigned getPTCLabelId(uint64_t EncodedLabel) {
  if (ptc.get_arg_label_id != nullptr)
    return ptc.get_arg_label_id(EncodedLabel);
  return static_cast<unsigned>(EncodedLabel);
}

static bool isKnownScalarOpcode(PTCOpcode Opcode) {
  switch (Opcode) {
  case PTC_INSTRUCTION_op_add2_i32:
  case PTC_INSTRUCTION_op_add2_i64:
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_add_i64:
  case PTC_INSTRUCTION_op_andc_i32:
  case PTC_INSTRUCTION_op_andc_i64:
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_and_i64:
  case PTC_INSTRUCTION_op_br:
  case PTC_INSTRUCTION_op_brcond2_i32:
  case PTC_INSTRUCTION_op_brcond_i32:
  case PTC_INSTRUCTION_op_brcond_i64:
  case PTC_INSTRUCTION_op_bswap16_i32:
  case PTC_INSTRUCTION_op_bswap16_i64:
  case PTC_INSTRUCTION_op_bswap32_i32:
  case PTC_INSTRUCTION_op_bswap32_i64:
  case PTC_INSTRUCTION_op_bswap64_i64:
  case PTC_INSTRUCTION_op_call:
  case PTC_INSTRUCTION_op_debug_insn_start:
  case PTC_INSTRUCTION_op_deposit_i32:
  case PTC_INSTRUCTION_op_deposit_i64:
  case PTC_INSTRUCTION_op_discard:
  case PTC_INSTRUCTION_op_div2_i32:
  case PTC_INSTRUCTION_op_div2_i64:
  case PTC_INSTRUCTION_op_div_i32:
  case PTC_INSTRUCTION_op_div_i64:
  case PTC_INSTRUCTION_op_divu2_i32:
  case PTC_INSTRUCTION_op_divu2_i64:
  case PTC_INSTRUCTION_op_divu_i32:
  case PTC_INSTRUCTION_op_divu_i64:
  case PTC_INSTRUCTION_op_eqv_i32:
  case PTC_INSTRUCTION_op_eqv_i64:
  case PTC_INSTRUCTION_op_exit_tb:
  case PTC_INSTRUCTION_op_ext16s_i32:
  case PTC_INSTRUCTION_op_ext16s_i64:
  case PTC_INSTRUCTION_op_ext16u_i32:
  case PTC_INSTRUCTION_op_ext16u_i64:
  case PTC_INSTRUCTION_op_ext32s_i64:
  case PTC_INSTRUCTION_op_ext32u_i64:
  case PTC_INSTRUCTION_op_ext8s_i32:
  case PTC_INSTRUCTION_op_ext8s_i64:
  case PTC_INSTRUCTION_op_ext8u_i32:
  case PTC_INSTRUCTION_op_ext8u_i64:
  case PTC_INSTRUCTION_op_goto_tb:
  case PTC_INSTRUCTION_op_ld16s_i32:
  case PTC_INSTRUCTION_op_ld16s_i64:
  case PTC_INSTRUCTION_op_ld16u_i32:
  case PTC_INSTRUCTION_op_ld16u_i64:
  case PTC_INSTRUCTION_op_ld32s_i64:
  case PTC_INSTRUCTION_op_ld32u_i64:
  case PTC_INSTRUCTION_op_ld8s_i32:
  case PTC_INSTRUCTION_op_ld8s_i64:
  case PTC_INSTRUCTION_op_ld8u_i32:
  case PTC_INSTRUCTION_op_ld8u_i64:
  case PTC_INSTRUCTION_op_ld_i32:
  case PTC_INSTRUCTION_op_ld_i64:
  case PTC_INSTRUCTION_op_mov_i32:
  case PTC_INSTRUCTION_op_mov_i64:
  case PTC_INSTRUCTION_op_movcond_i32:
  case PTC_INSTRUCTION_op_movcond_i64:
  case PTC_INSTRUCTION_op_movi_i32:
  case PTC_INSTRUCTION_op_movi_i64:
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_mul_i64:
  case PTC_INSTRUCTION_op_muls2_i32:
  case PTC_INSTRUCTION_op_muls2_i64:
  case PTC_INSTRUCTION_op_mulsh_i32:
  case PTC_INSTRUCTION_op_mulsh_i64:
  case PTC_INSTRUCTION_op_mulu2_i32:
  case PTC_INSTRUCTION_op_mulu2_i64:
  case PTC_INSTRUCTION_op_muluh_i32:
  case PTC_INSTRUCTION_op_muluh_i64:
  case PTC_INSTRUCTION_op_nand_i32:
  case PTC_INSTRUCTION_op_nand_i64:
  case PTC_INSTRUCTION_op_neg_i32:
  case PTC_INSTRUCTION_op_neg_i64:
  case PTC_INSTRUCTION_op_nor_i32:
  case PTC_INSTRUCTION_op_nor_i64:
  case PTC_INSTRUCTION_op_not_i32:
  case PTC_INSTRUCTION_op_not_i64:
  case PTC_INSTRUCTION_op_orc_i32:
  case PTC_INSTRUCTION_op_orc_i64:
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_or_i64:
  case PTC_INSTRUCTION_op_qemu_ld_i32:
  case PTC_INSTRUCTION_op_qemu_ld_i64:
  case PTC_INSTRUCTION_op_qemu_st_i32:
  case PTC_INSTRUCTION_op_qemu_st_i64:
  case PTC_INSTRUCTION_op_rem_i32:
  case PTC_INSTRUCTION_op_rem_i64:
  case PTC_INSTRUCTION_op_remu_i32:
  case PTC_INSTRUCTION_op_remu_i64:
  case PTC_INSTRUCTION_op_rotl_i32:
  case PTC_INSTRUCTION_op_rotl_i64:
  case PTC_INSTRUCTION_op_rotr_i32:
  case PTC_INSTRUCTION_op_rotr_i64:
  case PTC_INSTRUCTION_op_sar_i32:
  case PTC_INSTRUCTION_op_sar_i64:
  case PTC_INSTRUCTION_op_set_label:
  case PTC_INSTRUCTION_op_setcond2_i32:
  case PTC_INSTRUCTION_op_setcond_i32:
  case PTC_INSTRUCTION_op_setcond_i64:
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shl_i64:
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_shr_i64:
  case PTC_INSTRUCTION_op_st16_i32:
  case PTC_INSTRUCTION_op_st16_i64:
  case PTC_INSTRUCTION_op_st32_i64:
  case PTC_INSTRUCTION_op_st8_i32:
  case PTC_INSTRUCTION_op_st8_i64:
  case PTC_INSTRUCTION_op_st_i32:
  case PTC_INSTRUCTION_op_st_i64:
  case PTC_INSTRUCTION_op_sub2_i32:
  case PTC_INSTRUCTION_op_sub2_i64:
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_sub_i64:
  case PTC_INSTRUCTION_op_trunc_shr_i32:
  case PTC_INSTRUCTION_op_xor_i32:
  case PTC_INSTRUCTION_op_xor_i64:
    return true;
  default:
    return false;
  }
}

static bool isUnsupportedPTCV2OpcodeName(const OpcodeMetadata &Metadata) {
  if (Metadata.Name == nullptr)
    return false;

  StringRef Name(Metadata.Name);
  return Name.startswith("extract")
         || Name.startswith("qemu_ld2")
         || Name.startswith("qemu_st2")
         || Name.contains("_vec")
         || Name.endswith("_vec");
}

static void reportUnsupportedOpcode(PTCOpcode Opcode,
                                    const OpcodeMetadata &Metadata) {
  errs() << "runnable-lift: unsupported PTC opcode";
  errs() << " id=" << static_cast<unsigned>(Opcode);
  errs() << " name="
         << (Metadata.Name != nullptr ? Metadata.Name : "<unknown>");
  if (Metadata.HasDefinition) {
    errs() << " args={out:" << Metadata.OutArgs
           << ",in:" << Metadata.InArgs
           << ",const:" << Metadata.ConstArgs
           << ",total:" << Metadata.TotalArgs << "}";
  } else {
    errs() << " args=<unavailable>";
  }
  errs() << "\n";
  errs() << "runnable-lift: unsupported opcode/schema boundary; future PTC v2"
         << " opcodes such as extract_i64, qemu_ld2/qemu_st2, and vector"
         << " schemas require explicit lowering and are not implemented here\n";
}

static std::string compareAddressMarker(uint64_t Address) {
  std::ostringstream Stream;
  Stream << "0x" << std::hex << Address;
  return Stream.str();
}

static Type *getPointerStorageType(Value *Pointer) {
  if (auto *Alloca = dyn_cast<AllocaInst>(Pointer))
    return Alloca->getAllocatedType();

  if (auto *Global = dyn_cast<GlobalVariable>(Pointer))
    return Global->getValueType();

#if LLVM_VERSION_MAJOR < 15
  return Pointer->getType()->getPointerElementType();
#else
  runnable_unreachable("Cannot infer value type from an opaque pointer");
  return nullptr;
#endif
}

static LoadInst *createLoad(IRBuilder<> &Builder, Value *Pointer) {
  Type *ValueType = getPointerStorageType(Pointer);
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateLoad(ValueType, Pointer);
#else
  (void) ValueType;
  return Builder.CreateLoad(Pointer);
#endif
}

static LoadInst *createAlignedLoad(IRBuilder<> &Builder,
                                   Type *ValueType,
                                   Value *Pointer,
                                   unsigned Alignment) {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateAlignedLoad(ValueType,
                                   Pointer,
                                   MaybeAlign(Align(Alignment)));
#elif LLVM_VERSION_MAJOR >= 10
  (void) ValueType;
  return Builder.CreateAlignedLoad(Pointer, MaybeAlign(Align(Alignment)));
#else
  (void) ValueType;
  return Builder.CreateAlignedLoad(Pointer, Alignment);
#endif
}

static StoreInst *createAlignedStore(IRBuilder<> &Builder,
                                     Value *ToStore,
                                     Value *Pointer,
                                     unsigned Alignment) {
#if LLVM_VERSION_MAJOR >= 10
  return Builder.CreateAlignedStore(ToStore,
                                    Pointer,
                                    MaybeAlign(Align(Alignment)));
#else
  return Builder.CreateAlignedStore(ToStore, Pointer, Alignment);
#endif
}

static CallInst *createCall(IRBuilder<> &Builder,
                            FunctionType *CalleeType,
                            Value *Callee,
                            ArrayRef<Value *> Args) {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateCall(CalleeType, Callee, Args);
#else
  (void) CalleeType;
  return Builder.CreateCall(Callee, Args);
#endif
}

static Value *coerceIntegerToWidth(IRBuilder<> &Builder,
                                   Value *ValueToCoerce,
                                   unsigned Bits,
                                   bool SignExtend = false) {
  auto *TargetTy = Builder.getIntNTy(Bits);
  Type *CurrentTy = ValueToCoerce->getType();
  if (CurrentTy == TargetTy)
    return ValueToCoerce;

  if (!CurrentTy->isIntegerTy())
    return nullptr;

  unsigned CurrentBits = cast<IntegerType>(CurrentTy)->getBitWidth();
  if (CurrentBits < Bits)
    return SignExtend ? Builder.CreateSExt(ValueToCoerce, TargetTy) :
                        Builder.CreateZExt(ValueToCoerce, TargetTy);
  return Builder.CreateTrunc(ValueToCoerce, TargetTy);
}

static Value *loadIntegerGlobal(IRBuilder<> &Builder,
                                Module &TheModule,
                                StringRef Name,
                                unsigned Bits) {
  GlobalVariable *Global = TheModule.getGlobalVariable(Name);
  if (Global == nullptr) {
    errs() << "runnable-lift: QEMU v2 syscall lowering missing CSV"
           << " name=" << Name << "\n";
    return nullptr;
  }

  Type *ValueTy = Global->getValueType();
  if (!ValueTy->isIntegerTy()) {
    errs() << "runnable-lift: QEMU v2 syscall lowering expected integer CSV"
           << " name=" << Name << "\n";
    return nullptr;
  }

  Value *Loaded = createLoad(Builder, Global);
  return coerceIntegerToWidth(Builder, Loaded, Bits);
}

static bool storeIntegerGlobal(IRBuilder<> &Builder,
                               Module &TheModule,
                               StringRef Name,
                               Value *ValueToStore) {
  GlobalVariable *Global = TheModule.getGlobalVariable(Name);
  if (Global == nullptr) {
    errs() << "runnable-lift: QEMU v2 syscall lowering missing CSV"
           << " name=" << Name << "\n";
    return false;
  }

  Type *ValueTy = Global->getValueType();
  if (!ValueTy->isIntegerTy()) {
    errs() << "runnable-lift: QEMU v2 syscall lowering expected integer CSV"
           << " name=" << Name << "\n";
    return false;
  }

  unsigned Bits = cast<IntegerType>(ValueTy)->getBitWidth();
  Value *Coerced = coerceIntegerToWidth(Builder, ValueToStore, Bits);
  if (Coerced == nullptr)
    return false;

  Builder.CreateStore(Coerced, Global);
  return true;
}

static Value *coerceEnvToI8Ptr(IRBuilder<> &Builder, Value *EnvValue) {
  PointerType *I8PtrTy = runnable_llvm::getInt8PtrTy(Builder.getContext());
  if (EnvValue->getType()->isPointerTy())
    return Builder.CreateBitCast(EnvValue, I8PtrTy);
  if (EnvValue->getType()->isIntegerTy())
    return Builder.CreateIntToPtr(EnvValue, I8PtrTy);
  return nullptr;
}

static Value *createEnvOffsetPointer(IRBuilder<> &Builder,
                                     Value *EnvValue,
                                     Type *PointeeType,
                                     int64_t Offset) {
  Value *EnvI8 = coerceEnvToI8Ptr(Builder, EnvValue);
  if (EnvI8 == nullptr)
    return nullptr;

  Value *OffsetValue = ConstantInt::get(Builder.getInt64Ty(), Offset, true);
#if LLVM_VERSION_MAJOR >= 15
  Value *Address = Builder.CreateGEP(Builder.getInt8Ty(), EnvI8, OffsetValue);
#else
  Value *Address = Builder.CreateGEP(EnvI8, OffsetValue);
#endif
  return Builder.CreateBitCast(Address, PointeeType->getPointerTo());
}

static Optional<int64_t> getUniqueConstantIntegerStore(Value *Pointer) {
  Value *Stripped = Pointer->stripPointerCasts();
  if (auto *Global = dyn_cast<GlobalVariable>(Stripped)) {
    if (Global->hasInitializer()) {
      if (auto *Constant = dyn_cast<ConstantInt>(Global->getInitializer()))
        return Constant->getSExtValue();
    }
  }

  Optional<int64_t> Result;
  for (User *TheUser : Stripped->users()) {
    auto *Store = dyn_cast<StoreInst>(TheUser);
    if (Store == nullptr || Store->getPointerOperand() != Stripped)
      continue;

    auto *Constant = dyn_cast<ConstantInt>(Store->getValueOperand());
    if (Constant == nullptr)
      return None;

    int64_t Value = Constant->getSExtValue();
    if (Result && *Result != Value)
      return None;
    Result = Value;
  }

  return Result;
}

static Optional<int64_t> resolveConstantInteger(Value *ValueToResolve) {
  if (auto *Constant = dyn_cast<ConstantInt>(ValueToResolve))
    return Constant->getSExtValue();

  auto *Load = dyn_cast<LoadInst>(ValueToResolve);
  if (Load == nullptr)
    return None;

  return getUniqueConstantIntegerStore(Load->getPointerOperand());
}

static Optional<IT::TranslationResult>
tryLowerQEMUV2X86_64Syscall(IRBuilder<> &Builder,
                            Module &TheModule,
                            JumpTargetManager &JumpTargets,
                            const Architecture &SourceArchitecture,
                            uint64_t GuestPC,
                            StringRef HelperSuffix,
                            ArrayRef<Value *> InArgs,
                            StoreInst *PCSaver) {
  if (!ptc_compat::isPTCAbiV2() || HelperSuffix != "syscall")
    return None;

  if (SourceArchitecture.type() != Triple::x86_64) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering is only "
           << "implemented for x86_64\n";
    return IT::Abort;
  }

  if (InArgs.size() != 2) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering expected "
           << "env and next_eip_addend arguments, got " << InArgs.size()
           << "\n";
    return IT::Abort;
  }

  if (GuestPC == 0) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering missing "
           << "guest PC\n";
    return IT::Abort;
  }

  LLVMContext &Context = TheModule.getContext();
  Type *I64Ty = Type::getInt64Ty(Context);
  Type *I32Ty = Type::getInt32Ty(Context);
  Type *I8PtrTy = runnable_llvm::getInt8PtrTy(Context);

  Value *EnvPtr = coerceEnvToI8Ptr(Builder, InArgs[0]);
  if (EnvPtr == nullptr) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering could not "
           << "coerce env argument\n";
    return IT::Abort;
  }

  Value *SyscallNumber64 = loadIntegerGlobal(Builder, TheModule, "rax", 64);
  Value *ArgRDI = loadIntegerGlobal(Builder, TheModule, "rdi", 64);
  Value *ArgRSI = loadIntegerGlobal(Builder, TheModule, "rsi", 64);
  Value *ArgRDX = loadIntegerGlobal(Builder, TheModule, "rdx", 64);
  Value *ArgR10 = loadIntegerGlobal(Builder, TheModule, "r10", 64);
  Value *ArgR8 = loadIntegerGlobal(Builder, TheModule, "r8", 64);
  Value *ArgR9 = loadIntegerGlobal(Builder, TheModule, "r9", 64);
  if (SyscallNumber64 == nullptr || ArgRDI == nullptr || ArgRSI == nullptr
      || ArgRDX == nullptr || ArgR10 == nullptr || ArgR8 == nullptr
      || ArgR9 == nullptr)
    return IT::Abort;

  Value *SyscallNumber = Builder.CreateTrunc(SyscallNumber64, I32Ty);
  Value *NextEIPAddend = coerceIntegerToWidth(Builder,
                                              InArgs[1],
                                              64,
                                              true);
  if (NextEIPAddend == nullptr) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering expected "
           << "integer next_eip_addend\n";
    return IT::Abort;
  }

  Optional<int64_t> StaticNextEIPAddend = resolveConstantInteger(InArgs[1]);
  if (!StaticNextEIPAddend) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering could not "
           << "resolve constant next_eip_addend for post-helper target"
           << " pc=0x" << Twine::utohexstr(GuestPC) << "\n";
    return IT::Abort;
  }

  uint64_t ContinuationPC =
    static_cast<uint64_t>(static_cast<int64_t>(GuestPC)
                          + *StaticNextEIPAddend);
  if (JumpTargets.registerJT(ContinuationPC, JTReason::PostHelper) == nullptr) {
    errs() << "runnable-lift: QEMU v2 helper_syscall lowering could not "
           << "register post-syscall continuation"
           << " pc=0x" << Twine::utohexstr(GuestPC)
           << " next=0x" << Twine::utohexstr(ContinuationPC) << "\n";
    return IT::Abort;
  }

  auto *DoSyscallTy = FunctionType::get(I64Ty,
                                        { I8PtrTy,
                                          I32Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty,
                                          I64Ty },
                                        false);
  Constant *DoSyscall = runnable_llvm::getOrInsertFunction(TheModule,
                                                           "do_syscall",
                                                           DoSyscallTy);
  Value *Zero64 = ConstantInt::get(I64Ty, 0);
  CallInst *SyscallResult = createCall(Builder,
                                       DoSyscallTy,
                                       DoSyscall,
                                       { EnvPtr,
                                         SyscallNumber,
                                         ArgRDI,
                                         ArgRSI,
                                         ArgRDX,
                                         ArgR10,
                                         ArgR8,
                                         ArgR9,
                                         Zero64,
                                         Zero64 });

  if (!storeIntegerGlobal(Builder, TheModule, "rax", SyscallResult))
    return IT::Abort;

  Value *CurrentPC = ConstantInt::get(I64Ty, GuestPC);
  Value *NextPC = Builder.CreateAdd(CurrentPC, NextEIPAddend);
  if (!storeIntegerGlobal(Builder, TheModule, "pc", NextPC))
    return IT::Abort;

  static bool Reported = false;
  if (!Reported) {
    errs() << "runnable-lift: lowering QEMU v2 x86_64 helper_syscall "
           << "to direct do_syscall CSV semantics with post-helper target\n";
    Reported = true;
  }

  return PCSaver != nullptr ? IT::ForceNewPC : IT::Success;
}

static std::string formatCompareAssemblyMarker(uint64_t Address,
                                               StringRef Assembly) {
  std::string Marker = compareAddressMarker(Address);
  Marker += ": ";
  Marker += Assembly.str();
  return Marker;
}

static uint64_t canonicalizeDebugInsnStartPC(uint64_t RawPC,
                                             const BinaryFile &Binary) {
  if (Binary.getAddressData(RawPC))
    return RawPC;

  const uint64_t Base = Binary.baseAddress();
  if (Base == 0 || RawPC >= Base)
    return RawPC;

  uint64_t RelocatedPC = RawPC + Base;
  if (!Binary.getAddressData(RelocatedPC))
    return RawPC;

  errs() << "runnable-lift: canonicalized debug_insn_start pc"
         << " raw=0x" << Twine::utohexstr(RawPC)
         << " relocated=0x" << Twine::utohexstr(RelocatedPC)
         << " base=0x" << Twine::utohexstr(Base) << "\n";
  return RelocatedPC;
}

} // namespace

namespace PTC {

template<bool C>
class InstructionImpl;

enum ArgumentType { In, Out, Const };

template<typename T, typename Q, bool B>
using RAI = RandomAccessIterator<T, Q, B>;

template<ArgumentType Type, bool IsCall>
class InstructionArgumentsIterator
  : public RAI<uint64_t, InstructionArgumentsIterator<Type, IsCall>, false> {

public:
  using base = RandomAccessIterator<uint64_t,
                                    InstructionArgumentsIterator,
                                    false>;

  InstructionArgumentsIterator &
  operator=(const InstructionArgumentsIterator &r) {
    base::operator=(r);
    TheInstruction = r.TheInstruction;
    return *this;
  }

  InstructionArgumentsIterator(const InstructionArgumentsIterator &r) :
    base(r),
    TheInstruction(r.TheInstruction) {}

  InstructionArgumentsIterator(const InstructionArgumentsIterator &r,
                               unsigned Index) :
    base(Index),
    TheInstruction(r.TheInstruction) {}

  InstructionArgumentsIterator(PTCInstruction *TheInstruction, unsigned Index) :
    base(Index),
    TheInstruction(TheInstruction) {}

  bool isCompatible(const InstructionArgumentsIterator &r) const {
    return TheInstruction == r.TheInstruction;
  }

public:
  uint64_t get(unsigned Index) const;

private:
  PTCInstruction *TheInstruction;
};

template<>
inline uint64_t
InstructionArgumentsIterator<In, true>::get(unsigned Index) const {
  return ptc_call_instruction_in_arg(&ptc, TheInstruction, Index);
}

template<>
inline uint64_t
InstructionArgumentsIterator<Const, true>::get(unsigned Index) const {
  return ptc_call_instruction_const_arg(&ptc, TheInstruction, Index);
}

template<>
inline uint64_t
InstructionArgumentsIterator<Out, true>::get(unsigned Index) const {
  return ptc_call_instruction_out_arg(&ptc, TheInstruction, Index);
}

template<>
inline uint64_t
InstructionArgumentsIterator<In, false>::get(unsigned Index) const {
  return ptc_instruction_in_arg(&ptc, TheInstruction, Index);
}

template<>
inline uint64_t
InstructionArgumentsIterator<Const, false>::get(unsigned Index) const {
  return ptc_instruction_const_arg(&ptc, TheInstruction, Index);
}

template<>
inline uint64_t
InstructionArgumentsIterator<Out, false>::get(unsigned Index) const {
  return ptc_instruction_out_arg(&ptc, TheInstruction, Index);
}

template<bool IsCall>
class InstructionImpl {
private:
  template<ArgumentType Type>
  using arguments = InstructionArgumentsIterator<Type, IsCall>;

public:
  InstructionImpl(PTCInstruction *TheInstruction) :
    TheInstruction(TheInstruction),
    InArguments(arguments<In>(TheInstruction, 0),
                arguments<In>(TheInstruction, inArgCount())),
    ConstArguments(arguments<Const>(TheInstruction, 0),
                   arguments<Const>(TheInstruction, constArgCount())),
    OutArguments(arguments<Out>(TheInstruction, 0),
                 arguments<Out>(TheInstruction, outArgCount())) {}

  PTCOpcode opcode() const { return TheInstruction->opc; }

  std::string helperName() const {
    runnable_assert(IsCall);
    PTCHelperDef *Helper = ptc_find_helper(&ptc, ConstArguments[0]);
    if (Helper != nullptr && Helper->name != nullptr)
      return std::string(Helper->name);

    std::ostringstream Name;
    Name << "unknown_0x" << std::hex << ConstArguments[0];
    return Name.str();
  }

  uint64_t pc() const {
    runnable_assert(opcode() == PTC_INSTRUCTION_op_debug_insn_start);
    return TheInstruction->args[0];
  }

private:
  PTCInstruction *TheInstruction;

public:
  const Range<InstructionArgumentsIterator<In, IsCall>> InArguments;
  const Range<InstructionArgumentsIterator<Const, IsCall>> ConstArguments;
  const Range<InstructionArgumentsIterator<Out, IsCall>> OutArguments;

private:
  unsigned inArgCount() const;
  unsigned constArgCount() const;
  unsigned outArgCount() const;
};

using Instruction = InstructionImpl<false>;
using CallInstruction = InstructionImpl<true>;

template<>
inline unsigned CallInstruction::inArgCount() const {
  return ptc_call_instruction_in_arg_count(&ptc, TheInstruction);
}

template<>
inline unsigned Instruction::inArgCount() const {
  return ptc_instruction_in_arg_count(&ptc, TheInstruction);
}

template<>
inline unsigned CallInstruction::constArgCount() const {
  return ptc_call_instruction_const_arg_count(&ptc, TheInstruction);
}

template<>
inline unsigned Instruction::constArgCount() const {
  return ptc_instruction_const_arg_count(&ptc, TheInstruction);
}

template<>
inline unsigned CallInstruction::outArgCount() const {
  return ptc_call_instruction_out_arg_count(&ptc, TheInstruction);
}

template<>
inline unsigned Instruction::outArgCount() const {
  return ptc_instruction_out_arg_count(&ptc, TheInstruction);
}

} // namespace PTC

/// Converts a PTC condition into an LLVM predicate
///
/// \param Condition the input PTC condition.
///
/// \return the corresponding LLVM predicate.
static CmpInst::Predicate conditionToPredicate(PTCCondition Condition) {
  switch (Condition) {
  case PTC_COND_NEVER:
    // TODO: this is probably wrong
    return CmpInst::FCMP_FALSE;
  case PTC_COND_ALWAYS:
    // TODO: this is probably wrong
    return CmpInst::FCMP_TRUE;
  case PTC_COND_EQ:
    return CmpInst::ICMP_EQ;
  case PTC_COND_NE:
    return CmpInst::ICMP_NE;
  case PTC_COND_LT:
    return CmpInst::ICMP_SLT;
  case PTC_COND_GE:
    return CmpInst::ICMP_SGE;
  case PTC_COND_LE:
    return CmpInst::ICMP_SLE;
  case PTC_COND_GT:
    return CmpInst::ICMP_SGT;
  case PTC_COND_LTU:
    return CmpInst::ICMP_ULT;
  case PTC_COND_GEU:
    return CmpInst::ICMP_UGE;
  case PTC_COND_LEU:
    return CmpInst::ICMP_ULE;
  case PTC_COND_GTU:
    return CmpInst::ICMP_UGT;
  default:
    runnable_unreachable("Unknown comparison operator");
  }
}

/// Obtains the LLVM binary operation corresponding to the specified PTC opcode.
///
/// \param Opcode the PTC opcode.
///
/// \return the LLVM binary operation matching opcode.
static Instruction::BinaryOps opcodeToBinaryOp(PTCOpcode Opcode) {
  switch (Opcode) {
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_add_i64:
  case PTC_INSTRUCTION_op_add2_i32:
  case PTC_INSTRUCTION_op_add2_i64:
    return Instruction::Add;
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_sub_i64:
  case PTC_INSTRUCTION_op_sub2_i32:
  case PTC_INSTRUCTION_op_sub2_i64:
    return Instruction::Sub;
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_mul_i64:
    return Instruction::Mul;
  case PTC_INSTRUCTION_op_div_i32:
  case PTC_INSTRUCTION_op_div_i64:
    return Instruction::SDiv;
  case PTC_INSTRUCTION_op_divu_i32:
  case PTC_INSTRUCTION_op_divu_i64:
    return Instruction::UDiv;
  case PTC_INSTRUCTION_op_rem_i32:
  case PTC_INSTRUCTION_op_rem_i64:
    return Instruction::SRem;
  case PTC_INSTRUCTION_op_remu_i32:
  case PTC_INSTRUCTION_op_remu_i64:
    return Instruction::URem;
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_and_i64:
    return Instruction::And;
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_or_i64:
    return Instruction::Or;
  case PTC_INSTRUCTION_op_xor_i32:
  case PTC_INSTRUCTION_op_xor_i64:
    return Instruction::Xor;
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shl_i64:
    return Instruction::Shl;
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_shr_i64:
    return Instruction::LShr;
  case PTC_INSTRUCTION_op_sar_i32:
  case PTC_INSTRUCTION_op_sar_i64:
    return Instruction::AShr;
  default:
    runnable_unreachable("PTC opcode is not a binary operator");
  }
}

/// Returns the maximum value which can be represented with the specified number
/// of bits.
static uint64_t getMaxValue(unsigned Bits) {
  if (Bits == 32)
    return 0xffffffff;
  else if (Bits == 64)
    return 0xffffffffffffffff;
  else
    runnable_unreachable("Not the number of bits in a integer type");
}

/// Maps an opcode the corresponding input and output register size.
///
/// \return the size, in bits, of the registers used by the opcode.
static unsigned getRegisterSize(unsigned Opcode) {
  switch (Opcode) {
  case PTC_INSTRUCTION_op_add2_i32:
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_andc_i32:
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_brcond2_i32:
  case PTC_INSTRUCTION_op_brcond_i32:
  case PTC_INSTRUCTION_op_bswap16_i32:
  case PTC_INSTRUCTION_op_bswap32_i32:
  case PTC_INSTRUCTION_op_deposit_i32:
  case PTC_INSTRUCTION_op_div2_i32:
  case PTC_INSTRUCTION_op_div_i32:
  case PTC_INSTRUCTION_op_divu2_i32:
  case PTC_INSTRUCTION_op_divu_i32:
  case PTC_INSTRUCTION_op_eqv_i32:
  case PTC_INSTRUCTION_op_ext16s_i32:
  case PTC_INSTRUCTION_op_ext16u_i32:
  case PTC_INSTRUCTION_op_ext8s_i32:
  case PTC_INSTRUCTION_op_ext8u_i32:
  case PTC_INSTRUCTION_op_ld16s_i32:
  case PTC_INSTRUCTION_op_ld16u_i32:
  case PTC_INSTRUCTION_op_ld8s_i32:
  case PTC_INSTRUCTION_op_ld8u_i32:
  case PTC_INSTRUCTION_op_ld_i32:
  case PTC_INSTRUCTION_op_movcond_i32:
  case PTC_INSTRUCTION_op_mov_i32:
  case PTC_INSTRUCTION_op_movi_i32:
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_muls2_i32:
  case PTC_INSTRUCTION_op_mulsh_i32:
  case PTC_INSTRUCTION_op_mulu2_i32:
  case PTC_INSTRUCTION_op_muluh_i32:
  case PTC_INSTRUCTION_op_nand_i32:
  case PTC_INSTRUCTION_op_neg_i32:
  case PTC_INSTRUCTION_op_nor_i32:
  case PTC_INSTRUCTION_op_not_i32:
  case PTC_INSTRUCTION_op_orc_i32:
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_qemu_ld_i32:
  case PTC_INSTRUCTION_op_qemu_st_i32:
  case PTC_INSTRUCTION_op_rem_i32:
  case PTC_INSTRUCTION_op_remu_i32:
  case PTC_INSTRUCTION_op_rotl_i32:
  case PTC_INSTRUCTION_op_rotr_i32:
  case PTC_INSTRUCTION_op_sar_i32:
  case PTC_INSTRUCTION_op_setcond2_i32:
  case PTC_INSTRUCTION_op_setcond_i32:
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_st16_i32:
  case PTC_INSTRUCTION_op_st8_i32:
  case PTC_INSTRUCTION_op_st_i32:
  case PTC_INSTRUCTION_op_sub2_i32:
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_trunc_shr_i32:
  case PTC_INSTRUCTION_op_xor_i32:
    return 32;
  case PTC_INSTRUCTION_op_add2_i64:
  case PTC_INSTRUCTION_op_add_i64:
  case PTC_INSTRUCTION_op_andc_i64:
  case PTC_INSTRUCTION_op_and_i64:
  case PTC_INSTRUCTION_op_brcond_i64:
  case PTC_INSTRUCTION_op_bswap16_i64:
  case PTC_INSTRUCTION_op_bswap32_i64:
  case PTC_INSTRUCTION_op_bswap64_i64:
  case PTC_INSTRUCTION_op_deposit_i64:
  case PTC_INSTRUCTION_op_div2_i64:
  case PTC_INSTRUCTION_op_div_i64:
  case PTC_INSTRUCTION_op_divu2_i64:
  case PTC_INSTRUCTION_op_divu_i64:
  case PTC_INSTRUCTION_op_eqv_i64:
  case PTC_INSTRUCTION_op_ext16s_i64:
  case PTC_INSTRUCTION_op_ext16u_i64:
  case PTC_INSTRUCTION_op_ext32s_i64:
  case PTC_INSTRUCTION_op_ext32u_i64:
  case PTC_INSTRUCTION_op_ext8s_i64:
  case PTC_INSTRUCTION_op_ext8u_i64:
  case PTC_INSTRUCTION_op_ld16s_i64:
  case PTC_INSTRUCTION_op_ld16u_i64:
  case PTC_INSTRUCTION_op_ld32s_i64:
  case PTC_INSTRUCTION_op_ld32u_i64:
  case PTC_INSTRUCTION_op_ld8s_i64:
  case PTC_INSTRUCTION_op_ld8u_i64:
  case PTC_INSTRUCTION_op_ld_i64:
  case PTC_INSTRUCTION_op_movcond_i64:
  case PTC_INSTRUCTION_op_mov_i64:
  case PTC_INSTRUCTION_op_movi_i64:
  case PTC_INSTRUCTION_op_mul_i64:
  case PTC_INSTRUCTION_op_muls2_i64:
  case PTC_INSTRUCTION_op_mulsh_i64:
  case PTC_INSTRUCTION_op_mulu2_i64:
  case PTC_INSTRUCTION_op_muluh_i64:
  case PTC_INSTRUCTION_op_nand_i64:
  case PTC_INSTRUCTION_op_neg_i64:
  case PTC_INSTRUCTION_op_nor_i64:
  case PTC_INSTRUCTION_op_not_i64:
  case PTC_INSTRUCTION_op_orc_i64:
  case PTC_INSTRUCTION_op_or_i64:
  case PTC_INSTRUCTION_op_qemu_ld_i64:
  case PTC_INSTRUCTION_op_qemu_st_i64:
  case PTC_INSTRUCTION_op_rem_i64:
  case PTC_INSTRUCTION_op_remu_i64:
  case PTC_INSTRUCTION_op_rotl_i64:
  case PTC_INSTRUCTION_op_rotr_i64:
  case PTC_INSTRUCTION_op_sar_i64:
  case PTC_INSTRUCTION_op_setcond_i64:
  case PTC_INSTRUCTION_op_shl_i64:
  case PTC_INSTRUCTION_op_shr_i64:
  case PTC_INSTRUCTION_op_st16_i64:
  case PTC_INSTRUCTION_op_st32_i64:
  case PTC_INSTRUCTION_op_st8_i64:
  case PTC_INSTRUCTION_op_st_i64:
  case PTC_INSTRUCTION_op_sub2_i64:
  case PTC_INSTRUCTION_op_sub_i64:
  case PTC_INSTRUCTION_op_xor_i64:
    return 64;
  case PTC_INSTRUCTION_op_br:
  case PTC_INSTRUCTION_op_call:
  case PTC_INSTRUCTION_op_debug_insn_start:
  case PTC_INSTRUCTION_op_discard:
  case PTC_INSTRUCTION_op_exit_tb:
  case PTC_INSTRUCTION_op_goto_tb:
  case PTC_INSTRUCTION_op_set_label:
    return 0;
  default:
    runnable_unreachable("Unexpected opcode");
  }
}

/// Create a compare instruction given a comparison operator and the operands
///
/// \param Builder the builder to use to create the instruction.
/// \param RawCondition the PTC condition.
/// \param FirstOperand the first operand of the comparison.
/// \param SecondOperand the second operand of the comparison.
///
/// \return a compare instruction.
template<typename T>
static Value *CreateICmp(T &Builder,
                         uint64_t RawCondition,
                         Value *FirstOperand,
                         Value *SecondOperand) {
  PTCCondition Condition = static_cast<PTCCondition>(RawCondition);
  return Builder.CreateICmp(conditionToPredicate(Condition),
                            FirstOperand,
                            SecondOperand);
}

using LBM = IT::LabeledBlocksMap;
IT::InstructionTranslator(IRBuilder<> &Builder,
                          VariableManager &Variables,
                          const BinaryFile &Binary,
                          JumpTargetManager &JumpTargets,
                          std::vector<BasicBlock *> Blocks,
                          const Architecture &SourceArchitecture,
                          const Architecture &TargetArchitecture) :
  Builder(Builder),
  Variables(Variables),
  Binary(Binary),
  JumpTargets(JumpTargets),
  Blocks(Blocks),
  TheModule(*Builder.GetInsertBlock()->getParent()->getParent()),
  TheFunction(Builder.GetInsertBlock()->getParent()),
  SourceArchitecture(SourceArchitecture),
  TargetArchitecture(TargetArchitecture),
  NewPCMarker(nullptr) {

  auto &Context = TheModule.getContext();
  using FT = FunctionType;
  // The newpc function call takes the following parameters:
  //
  // * address of the instruction
  // * instruction size
  // * isJT (-1: unknown, 0: no, 1: yes)
  // * pointer to the disassembled instruction
  // * all the local variables used by this instruction
  auto *NewPCMarkerTy = FT::get(Type::getVoidTy(Context),
                                { Type::getInt64Ty(Context),
                                  Type::getInt64Ty(Context),
                                  Type::getInt32Ty(Context),
                                  runnable_llvm::getInt8PtrTy(Context) },
                                true);
  NewPCMarker = Function::Create(NewPCMarkerTy,
                                 GlobalValue::ExternalLinkage,
                                 "newpc",
                                 &TheModule);
}

void IT::finalizeNewPCMarkers(std::string &CoveragePath,
                              bool RemoveRuntimeMarkers) {
  std::ofstream Output(CoveragePath);
  unsigned OriginalInstrMDKind = TheModule.getContext().getMDKindID("oi");
  std::vector<CallInst *> RuntimeMarkers;

  Output << std::hex;
  for (User *U : NewPCMarker->users()) {
    auto *Call = cast<CallInst>(U);
    if (Call->getParent() != nullptr) {
      // Report the instruction on the coverage CSV
      using CI = ConstantInt;
      uint64_t PC = (cast<CI>(Call->getArgOperand(0)))->getLimitedValue();
      uint64_t Size = (cast<CI>(Call->getArgOperand(1)))->getLimitedValue();
      bool IsJT = JumpTargets.isJumpTarget(PC);
      Output << "0x" << PC << ",0x" << Size << "," << (IsJT ? "1" : "0")
             << std::endl;

      unsigned ArgCount = getCallArgCount(Call);
      Call->setArgOperand(2, Builder.getInt32(static_cast<uint32_t>(IsJT)));

      auto *PCMD = ConstantAsMetadata::get(cast<Constant>(Call->getArgOperand(0)));
      auto *TextMD = ConstantAsMetadata::get(cast<Constant>(Call->getArgOperand(3)));
      Call->setMetadata(OriginalInstrMDKind, MDNode::get(TheModule.getContext(),
                                                         { TextMD, PCMD }));

      // TODO: by default we should leave these
      for (unsigned I = 4; I < ArgCount - 1; I++)
        Call->setArgOperand(I, Call->getArgOperand(ArgCount - 1));

      if (RemoveRuntimeMarkers)
        RuntimeMarkers.push_back(Call);
    }
  }
  Output << std::dec;

  for (CallInst *Call : RuntimeMarkers)
    Call->eraseFromParent();

  if (RemoveRuntimeMarkers) {
    errs() << "runnable-lift: removed QEMU v2 runtime newpc markers after"
              " coverage finalization count="
           << RuntimeMarkers.size() << "\n";
  }
}

unsigned IT::finalizePendingLabelBlocks() {
  std::set<BasicBlock *> Seen;
  unsigned Materialized = 0;

  auto Materialize = [&](const LabeledBlocksMap::value_type &Entry) {
    BasicBlock *BB = Entry.second;
    if (BB == nullptr || BB->getParent() != TheFunction)
      return;
    if (!Seen.insert(BB).second)
      return;
    if (BB->getTerminator() != nullptr)
      return;

    new UnreachableInst(TheModule.getContext(), BB);
    Materialized++;
    errs() << "runnable-lift: warning: materialized unresolved PTC label"
           << " label=" << Entry.first
           << " block=" << BB->getName() << "\n";
  };

  for (const auto &Entry : LabeledBasicBlocks)
    Materialize(Entry);
  for (const auto &Entry : BranchLabeledBasicBlocks)
    Materialize(Entry);

  return Materialized;
}

SmallSet<unsigned, 1> IT::preprocess(PTCInstructionList *InstructionList) {
  SmallSet<unsigned, 1> Result;

  for (unsigned I = 0; I < InstructionList->instruction_count; I++) {
    PTCInstruction &Instruction = InstructionList->instructions[I];
    if (validateOpcode(&Instruction) == Abort)
      return Result;

    switch (Instruction.opc) {
    case PTC_INSTRUCTION_op_movi_i32:
    case PTC_INSTRUCTION_op_movi_i64:
    case PTC_INSTRUCTION_op_mov_i32:
    case PTC_INSTRUCTION_op_mov_i64:
      break;
    default:
      continue;
    }

    const PTC::Instruction TheInstruction(&Instruction);
    if (TheInstruction.OutArguments.size() == 0) {
      errs() << "runnable-lift: temp out-of-range in preprocess"
             << " instruction_index=" << I
             << " opcode=" << static_cast<unsigned>(Instruction.opc)
             << " arg_index=0"
             << " temp_id=<missing>"
             << " total_temps=" << InstructionList->total_temps
             << "\n";
      return Result;
    }

    unsigned OutArg = TheInstruction.OutArguments[0];
    if (OutArg >= InstructionList->total_temps) {
      errs() << "runnable-lift: temp out-of-range in preprocess"
             << " instruction_index=" << I
             << " opcode=" << static_cast<unsigned>(Instruction.opc)
             << " arg_index=0"
             << " temp_id=" << OutArg
             << " total_temps=" << InstructionList->total_temps
             << "\n";
      return Result;
    }

    PTCTemp *Temporary = ptc_temp_get(InstructionList, OutArg);

    if (!ptc_temp_is_global(InstructionList, OutArg))
      continue;

    if (0 != strcmp("btarget", Temporary->name))
      continue;

    for (unsigned J = I + 1; J < InstructionList->instruction_count; J++) {
      unsigned Opcode = InstructionList->instructions[J].opc;
      if (Opcode == PTC_INSTRUCTION_op_debug_insn_start)
        Result.insert(J);
    }

    break;
  }

  return Result;
}

IT::TranslationResult IT::validateOpcode(PTCInstruction *Instr, bool Report) {
  if (Instr == nullptr) {
    if (Report)
      errs() << "runnable-lift: null PTCInstruction pointer\n";
    return Abort;
  }

  PTCOpcode Opcode = Instr->opc;
  OpcodeMetadata Metadata = getOpcodeMetadata(Opcode);
  if (!isKnownScalarOpcode(Opcode)
      || isUnsupportedPTCV2OpcodeName(Metadata)) {
    if (Report)
      reportUnsupportedOpcode(Opcode, Metadata);
    return Abort;
  }

  return Success;
}

std::tuple<IT::TranslationResult, MDNode *, uint64_t, uint64_t>
IT::newInstruction(PTCInstruction *Instr,
                   PTCInstruction *Next,
                   uint64_t EndPC,
                   bool IsFirst,
                   bool ForceNew) {
  using R = std::tuple<TranslationResult, MDNode *, uint64_t, uint64_t>;
  if (Instr == nullptr) {
    errs() << "runnable-lift: null PTCInstruction pointer in newInstruction"
           << " end_pc=0x" << Twine::utohexstr(EndPC)
           << " is_first=" << (IsFirst ? "true" : "false")
           << " force_new=" << (ForceNew ? "true" : "false")
           << "\n";
    return R{ Abort, nullptr, EndPC, EndPC };
  }

  LLVMContext &Context = TheModule.getContext();

  if (Instr->opc != PTC_INSTRUCTION_op_debug_insn_start) {
    errs() << "runnable-lift: expected debug_insn_start in newInstruction"
           << " opcode=" << static_cast<unsigned>(Instr->opc)
           << " end_pc=0x" << Twine::utohexstr(EndPC)
           << " is_first=" << (IsFirst ? "true" : "false")
           << " force_new=" << (ForceNew ? "true" : "false")
           << "\n";
    return R{ Abort, nullptr, EndPC, EndPC };
  }

  OpcodeMetadata Metadata = getOpcodeMetadata(Instr->opc);
  if (isUnsupportedPTCV2OpcodeName(Metadata)) {
    reportUnsupportedOpcode(Instr->opc, Metadata);
    return R{ Abort, nullptr, EndPC, EndPC };
  }

  const PTC::Instruction TheInstruction(Instr);
  // A new original instruction, let's create a new metadata node
  // referencing it for all the next instructions to come
  uint64_t PC = canonicalizeDebugInsnStartPC(TheInstruction.pc(), Binary);
  uint64_t NextPC =
    Next != nullptr
      ? canonicalizeDebugInsnStartPC(PTC::Instruction(Next).pc(), Binary)
      : EndPC;
  uint32_t DisassembleMaxBytes = 0;
  if (NextPC > PC) {
    uint64_t Delta = NextPC - PC;
    DisassembleMaxBytes = static_cast<uint32_t>(
      std::min<uint64_t>(Delta, std::numeric_limits<uint32_t>::max()));
  } else {
    errs() << "runnable-lift: skipping disassembly metadata for non-monotonic"
           << " pc range pc=0x" << Twine::utohexstr(PC)
           << " next_pc=0x" << Twine::utohexstr(NextPC)
           << " end_pc=0x" << Twine::utohexstr(EndPC)
           << " is_first=" << (IsFirst ? "true" : "false")
           << " force_new=" << (ForceNew ? "true" : "false")
           << "\n";
  }

  std::stringstream OriginalStringStream;
  disassemble(OriginalStringStream, PC, DisassembleMaxBytes, 4096, &Binary);
  std::string OriginalString =
    formatCompareAssemblyMarker(PC, OriginalStringStream.str());

  // We don't deduplicate this string since performing a lookup each time is
  // increasingly expensive and we should have relatively few collisions
  std::string AddressName = JumpTargets.nameForAddress(PC);
  Constant *String = buildStringPtr(&TheModule,
                                    OriginalString,
                                    Twine("disam_") + AddressName);

  auto *MDOriginalString = ConstantAsMetadata::get(String);
  auto *MDPC = ConstantAsMetadata::get(Builder.getInt64(PC));
  MDNode *MDOriginalInstr = MDNode::get(Context, { MDOriginalString, MDPC });

  if (ForceNew)
    JumpTargets.registerJT(PC, JTReason::PostHelper);

  if (!IsFirst) {
    // Check if this PC already has a block and use it
    bool ShouldContinue;
    BasicBlock *DivergeTo = JumpTargets.newPC(PC, ShouldContinue);
    if (DivergeTo != nullptr) {
      Builder.CreateBr(DivergeTo);

      if (ShouldContinue) {
        // The block is empty, let's fill it
        Blocks.push_back(DivergeTo);
        Builder.SetInsertPoint(DivergeTo);
      } else {
        // The block contains already translated code, early exit
        return R{ Stop, MDOriginalInstr, PC, NextPC };
      }
    }
  }

  Variables.newBasicBlock();

  // Insert a call to NewPCMarker capturing all the local temporaries
  // This prevents SROA from transforming them in SSA values, which is bad
  // in case we have to split a basic block
  std::vector<Value *> Args = { Builder.getInt64(PC),
                                Builder.getInt64(NextPC - PC),
                                Builder.getInt32(-1),
                                String };
  for (AllocaInst *Local : Variables.locals())
    Args.push_back(Local);

  auto *Call = Builder.CreateCall(NewPCMarker, Args);
  JumpTargets.registerInstructionExtent(PC, NextPC - PC);

  if (!IsFirst) {
    // Inform the JumpTargetManager about the new PC we met
    BasicBlock::iterator CurrentIt = Builder.GetInsertPoint();
    if (CurrentIt == Builder.GetInsertBlock()->begin())
      runnable_assert(JumpTargets.getBlockAt(PC) == Builder.GetInsertBlock());
    else
      JumpTargets.registerInstruction(PC, Call);
  }

  return R{ Success, MDOriginalInstr, PC, NextPC };
}

static StoreInst *getLastUniqueWrite(BasicBlock *BB, const Value *Register) {
  StoreInst *Result = nullptr;
  std::set<BasicBlock *> Visited;
  std::queue<BasicBlock *> WorkList;
  Visited.insert(BB);
  WorkList.push(BB);
  while (!WorkList.empty()) {
    BasicBlock *BB = WorkList.front();
    WorkList.pop();

    bool Stop = false;
    for (auto I = BB->rbegin(); I != BB->rend(); I++) {
      if (auto *Store = dyn_cast<StoreInst>(&*I)) {
        if (Store->getPointerOperand() == Register
            && isa<ConstantInt>(Store->getValueOperand())) {
          runnable_assert(Result == nullptr);
          Result = Store;
          Stop = true;
          break;
        }
      } else if (isa<CallInst>(&*I)) {
        Stop = true;
        break;
      }
    }

    if (!Stop) {
      for (BasicBlock *Prev : predecessors(BB)) {
        if (Visited.find(Prev) == Visited.end()) {
          WorkList.push(Prev);
          Visited.insert(BB);
        }
      }
    }
  }
  return Result;
}

namespace {

struct EnvLinearExpr {
  bool HasEnv = false;
  int64_t Offset = 0;
};

struct EnvSyncRange {
  intptr_t Offset = 0;
  uint64_t Size = 0;
};

static void appendEnvSyncRange(std::vector<EnvSyncRange> &Ranges,
                               intptr_t Offset,
                               uint64_t Size) {
  if (Size == 0)
    return;

  for (const EnvSyncRange &Range : Ranges)
    if (Range.Offset == Offset && Range.Size == Size)
      return;

  Ranges.push_back({ Offset, Size });
}

static StoreInst *findLastStoreToPointerBefore(Value *Pointer,
                                               Instruction *Before) {
  if (Pointer == nullptr || Before == nullptr || Before->getParent() == nullptr)
    return nullptr;

  BasicBlock *BB = Before->getParent();
  for (auto It = Before->getIterator(); It != BB->begin();) {
    --It;
    if (auto *Store = dyn_cast<StoreInst>(&*It))
      if (Store->getPointerOperand() == Pointer)
        return Store;
  }

  return nullptr;
}

static StoreInst *findUniqueStoreToPointer(Value *Pointer) {
  StoreInst *Result = nullptr;
  if (Pointer == nullptr)
    return nullptr;

  for (User *U : Pointer->users()) {
    auto *Store = dyn_cast<StoreInst>(U);
    if (Store == nullptr || Store->getPointerOperand() != Pointer)
      continue;

    if (Result != nullptr)
      return nullptr;
    Result = Store;
  }

  return Result;
}

static Optional<EnvLinearExpr>
analyzeQEMUV2EnvLinearExpr(Value *V,
                           VariableManager &Variables,
                           unsigned Depth = 0) {
  if (V == nullptr || Depth > 12)
    return None;

  V = V->stripPointerCasts();

  if (Variables.isEnv(V))
    return EnvLinearExpr{ true, 0 };

  if (auto *Const = dyn_cast<ConstantInt>(V))
    return EnvLinearExpr{ false, Const->getValue().getSExtValue() };

  if (auto *Load = dyn_cast<LoadInst>(V)) {
    if (Variables.isEnv(Load))
      return EnvLinearExpr{ true, 0 };

    Value *Pointer = Load->getPointerOperand();
    StoreInst *Store = findLastStoreToPointerBefore(Pointer, Load);
    if (Store == nullptr)
      Store = findUniqueStoreToPointer(Pointer);
    if (Store == nullptr)
      return None;

    return analyzeQEMUV2EnvLinearExpr(Store->getValueOperand(),
                                      Variables,
                                      Depth + 1);
  }

  if (auto *Cast = dyn_cast<CastInst>(V))
    return analyzeQEMUV2EnvLinearExpr(Cast->getOperand(0),
                                      Variables,
                                      Depth + 1);

  if (auto *Op = dyn_cast<BinaryOperator>(V)) {
    auto L = analyzeQEMUV2EnvLinearExpr(Op->getOperand(0),
                                        Variables,
                                        Depth + 1);
    auto R = analyzeQEMUV2EnvLinearExpr(Op->getOperand(1),
                                        Variables,
                                        Depth + 1);
    if (!L || !R)
      return None;

    switch (Op->getOpcode()) {
    case Instruction::Add:
      if (L->HasEnv && R->HasEnv)
        return None;
      return EnvLinearExpr{ L->HasEnv || R->HasEnv, L->Offset + R->Offset };

    case Instruction::Sub:
      if (R->HasEnv)
        return None;
      return EnvLinearExpr{ L->HasEnv, L->Offset - R->Offset };

    default:
      return None;
    }
  }

  return None;
}

static Type *getPointerElementTypeForSync(Type *Ty) {
  auto *PtrTy = dyn_cast<PointerType>(Ty);
  if (PtrTy == nullptr)
    return nullptr;

#if LLVM_VERSION_MAJOR >= 18
  return nullptr;
#elif LLVM_VERSION_MAJOR >= 15
  if (PtrTy->isOpaque())
    return nullptr;
  return PtrTy->getNonOpaquePointerElementType();
#else
  return PtrTy->getElementType();
#endif
}

static bool isQEMUV2X86DivideHelper(StringRef HelperSuffix) {
  return HelperSuffix == "divb_AL"
         || HelperSuffix == "divw_AX"
         || HelperSuffix == "divl_EAX"
         || HelperSuffix == "divq_EAX"
         || HelperSuffix == "idivb_AL"
         || HelperSuffix == "idivw_AX"
         || HelperSuffix == "idivl_EAX"
         || HelperSuffix == "idivq_EAX";
}

static bool canDirectLowerQEMUV2X86DivideHelper(StringRef HelperSuffix) {
  return HelperSuffix == "divq_EAX"
         || HelperSuffix == "divl_EAX"
         || HelperSuffix == "idivq_EAX"
         || HelperSuffix == "idivl_EAX";
}

static Optional<IT::TranslationResult>
tryLowerQEMUV2X86_64DivHelper(IRBuilder<> &Builder,
                              Module &TheModule,
                              const Architecture &SourceArchitecture,
                              StringRef HelperSuffix,
                              ArrayRef<Value *> InArgs,
                              StoreInst *PCSaver) {
  if (!ptc_compat::isPTCAbiV2() || !isQEMUV2X86DivideHelper(HelperSuffix))
    return None;

  // Keep QEMU v2 x86 divide helpers on the real helper path.  The helpers
  // update CPUState regs and raise QEMU exceptions; direct lowering must match
  // all of that before it is safe to re-enable.
  static constexpr bool DirectLowerQEMUV2X86DivideHelpers = false;
  if (!DirectLowerQEMUV2X86DivideHelpers)
    return None;

  if (!canDirectLowerQEMUV2X86DivideHelper(HelperSuffix)) {
    return None;
  } else if (SourceArchitecture.type() != Triple::x86_64) {
    errs() << "runnable-lift: QEMU v2 x86 divide helper lowering is only "
           << "implemented for x86_64\n";
    return IT::Abort;
  }

  if (InArgs.size() != 2) {
    errs() << "runnable-lift: QEMU v2 x86 divide helper lowering expected "
           << "env and divisor arguments, got " << InArgs.size() << "\n";
    return IT::Abort;
  }

  bool IsSigned = HelperSuffix.startswith("idiv");
  bool Is64Bit = HelperSuffix == "divq_EAX" || HelperSuffix == "idivq_EAX";

  Value *RAX64 = loadIntegerGlobal(Builder, TheModule, "rax", 64);
  Value *RDX64 = loadIntegerGlobal(Builder, TheModule, "rdx", 64);
  Value *Divisor64 = coerceIntegerToWidth(Builder, InArgs[1], 64);
  if (RAX64 == nullptr || RDX64 == nullptr || Divisor64 == nullptr)
    return IT::Abort;

  LLVMContext &Context = TheModule.getContext();
  Type *I1Ty = Builder.getInt1Ty();
  Type *I32Ty = Builder.getInt32Ty();
  Type *I64Ty = Builder.getInt64Ty();
  Type *I128Ty = Builder.getIntNTy(128);
  Function *Parent = Builder.GetInsertBlock()->getParent();

  Value *DivisorForZero = Is64Bit ? Divisor64
                                  : Builder.CreateTrunc(Divisor64, I32Ty);
  Value *DivisorIsZero =
    Builder.CreateICmpEQ(DivisorForZero,
                         ConstantInt::get(DivisorForZero->getType(), 0));

  BasicBlock *CurrentBB = Builder.GetInsertBlock();
  BasicBlock *DivBB =
    BasicBlock::Create(Context, "qemu_v2_div_compute", Parent);
  BasicBlock *StoreBB =
    BasicBlock::Create(Context, "qemu_v2_div_store", Parent);
  BasicBlock *AbortBB =
    BasicBlock::Create(Context, "qemu_v2_div_exception", Parent);

  Builder.CreateCondBr(DivisorIsZero, AbortBB, DivBB);

  Builder.SetInsertPoint(DivBB);
  Value *Quotient = nullptr;
  Value *Remainder = nullptr;
  Value *Overflow = nullptr;

  if (Is64Bit) {
    Value *High = Builder.CreateZExt(RDX64, I128Ty);
    Value *Low = Builder.CreateZExt(RAX64, I128Ty);
    Value *Dividend = Builder.CreateOr(Builder.CreateShl(High, 64), Low);
    Value *Divisor = IsSigned ? Builder.CreateSExt(Divisor64, I128Ty)
                              : Builder.CreateZExt(Divisor64, I128Ty);

    if (IsSigned) {
      auto *MinDividend = ConstantInt::get(I128Ty,
                                           APInt::getSignedMinValue(128));
      auto *MinusOne = ConstantInt::getSigned(I128Ty, -1);
      Value *LLVMOverflow =
        Builder.CreateAnd(Builder.CreateICmpEQ(Dividend, MinDividend),
                          Builder.CreateICmpEQ(Divisor, MinusOne));
      Value *SafeDivisor = Builder.CreateSelect(LLVMOverflow,
                                                ConstantInt::get(I128Ty, 1),
                                                Divisor);
      Quotient = Builder.CreateSDiv(Dividend, SafeDivisor);
      Remainder = Builder.CreateSRem(Dividend, SafeDivisor);

      auto *MinQ = ConstantInt::get(I128Ty,
                                    APInt::getSignedMinValue(64).sext(128));
      auto *MaxQ = ConstantInt::get(I128Ty,
                                    APInt::getSignedMaxValue(64).sext(128));
      Value *BelowMin = Builder.CreateICmpSLT(Quotient, MinQ);
      Value *AboveMax = Builder.CreateICmpSGT(Quotient, MaxQ);
      Overflow = Builder.CreateOr(LLVMOverflow,
                                  Builder.CreateOr(BelowMin, AboveMax));
    } else {
      Quotient = Builder.CreateUDiv(Dividend, Divisor);
      Remainder = Builder.CreateURem(Dividend, Divisor);

      auto *MaxQ = ConstantInt::get(I128Ty, APInt::getLowBitsSet(128, 64));
      Overflow = Builder.CreateICmpUGT(Quotient, MaxQ);
    }
  } else {
    Value *EAX = Builder.CreateTrunc(RAX64, I32Ty);
    Value *EDX = Builder.CreateTrunc(RDX64, I32Ty);
    Value *Divisor32 = Builder.CreateTrunc(Divisor64, I32Ty);
    Value *High = Builder.CreateZExt(EDX, I64Ty);
    Value *Low = Builder.CreateZExt(EAX, I64Ty);
    Value *Dividend = Builder.CreateOr(Builder.CreateShl(High, 32), Low);
    Value *Divisor = IsSigned ? Builder.CreateSExt(Divisor32, I64Ty)
                              : Builder.CreateZExt(Divisor32, I64Ty);

    if (IsSigned) {
      auto *MinDividend = ConstantInt::get(I64Ty,
                                           APInt::getSignedMinValue(64));
      auto *MinusOne = ConstantInt::getSigned(I64Ty, -1);
      Value *LLVMOverflow =
        Builder.CreateAnd(Builder.CreateICmpEQ(Dividend, MinDividend),
                          Builder.CreateICmpEQ(Divisor, MinusOne));
      Value *SafeDivisor = Builder.CreateSelect(LLVMOverflow,
                                                ConstantInt::get(I64Ty, 1),
                                                Divisor);
      Quotient = Builder.CreateSDiv(Dividend, SafeDivisor);
      Remainder = Builder.CreateSRem(Dividend, SafeDivisor);

      auto *MinQ = ConstantInt::get(I64Ty,
                                    APInt::getSignedMinValue(32).sext(64));
      auto *MaxQ = ConstantInt::get(I64Ty,
                                    APInt::getSignedMaxValue(32).sext(64));
      Value *BelowMin = Builder.CreateICmpSLT(Quotient, MinQ);
      Value *AboveMax = Builder.CreateICmpSGT(Quotient, MaxQ);
      Overflow = Builder.CreateOr(LLVMOverflow,
                                  Builder.CreateOr(BelowMin, AboveMax));
    } else {
      Quotient = Builder.CreateUDiv(Dividend, Divisor);
      Remainder = Builder.CreateURem(Dividend, Divisor);

      auto *MaxQ = ConstantInt::get(I64Ty, APInt::getLowBitsSet(64, 32));
      Overflow = Builder.CreateICmpUGT(Quotient, MaxQ);
    }
  }

  if (Overflow->getType() != I1Ty)
    return IT::Abort;
  Builder.CreateCondBr(Overflow, AbortBB, StoreBB);

  Builder.SetInsertPoint(AbortBB);
  auto *AbortTy = FunctionType::get(Builder.getVoidTy(), false);
  Constant *Abort = runnable_llvm::getOrInsertFunction(TheModule,
                                                       "abort",
                                                       AbortTy);
  createCall(Builder, AbortTy, Abort, {});
  Builder.CreateUnreachable();

  Builder.SetInsertPoint(StoreBB);
  Value *QuotientOut = nullptr;
  Value *RemainderOut = nullptr;
  if (Is64Bit) {
    QuotientOut = Builder.CreateTrunc(Quotient, I64Ty);
    RemainderOut = Builder.CreateTrunc(Remainder, I64Ty);
  } else {
    QuotientOut = Builder.CreateZExt(Builder.CreateTrunc(Quotient, I32Ty),
                                     I64Ty);
    RemainderOut = Builder.CreateZExt(Builder.CreateTrunc(Remainder, I32Ty),
                                      I64Ty);
  }

  if (!storeIntegerGlobal(Builder, TheModule, "rax", QuotientOut)
      || !storeIntegerGlobal(Builder, TheModule, "rdx", RemainderOut))
    return IT::Abort;

  static bool Reported = false;
  if (!Reported) {
    errs() << "runnable-lift: lowering QEMU v2 x86 divide helpers to direct"
           << " CSV semantics\n";
    Reported = true;
  }

  (void) CurrentBB;
  return PCSaver != nullptr ? IT::ForceNewPC : IT::Success;
}

static bool isQEMUV2X86SSEConversionHelper(StringRef HelperSuffix) {
  return HelperSuffix == "cvtsi2ss"
         || HelperSuffix == "cvtsi2sd"
         || HelperSuffix == "cvtsq2ss"
         || HelperSuffix == "cvtsq2sd";
}

static std::vector<EnvSyncRange>
collectQEMUV2HelperSyncRanges(Module &TheModule,
                              StringRef HelperName,
                              StringRef HelperSuffix,
                              ArrayRef<Value *> InArgs,
                              VariableManager &Variables) {
  std::vector<EnvSyncRange> Ranges;

  bool AllowEnvPointerFallback =
    isQEMUV2X86SSEConversionHelper(HelperSuffix);

  Function *Helper = TheModule.getFunction(HelperName);
  FunctionType *HelperType = Helper != nullptr ? Helper->getFunctionType()
                                               : nullptr;
  const DataLayout &DL = TheModule.getDataLayout();
  unsigned NumArgs = InArgs.size();
  for (unsigned I = 1; I < NumArgs; ++I) {
    auto Expr = analyzeQEMUV2EnvLinearExpr(InArgs[I], Variables);
    if (!Expr || !Expr->HasEnv)
      continue;

    uint64_t Size = 0;
    if (HelperType != nullptr && I < HelperType->getNumParams()) {
      Type *PointeeType =
        getPointerElementTypeForSync(HelperType->getParamType(I));
      if (PointeeType != nullptr)
        Size = DL.getTypeAllocSize(PointeeType);
      if (Size > 256)
        continue;
    }

    if (Size == 0) {
      if (!AllowEnvPointerFallback)
        continue;
      Size = 64;
    }

    appendEnvSyncRange(Ranges, Expr->Offset, Size);
  }

  return Ranges;
}

static bool syncQEMUV2HelperRanges(IRBuilder<> &Builder,
                                   VariableManager &Variables,
                                   Value *EnvValue,
                                   ArrayRef<EnvSyncRange> Ranges,
                                   bool FlushToEnv) {
  for (const EnvSyncRange &Range : Ranges)
    if (!Variables.syncCPUStateRangeWithEnvBacking(Builder,
                                                  EnvValue,
                                                  Range.Offset,
                                                  Range.Size,
                                                  FlushToEnv))
      return false;

  return true;
}

} // namespace

IT::TranslationResult IT::translateCall(PTCInstruction *Instr, uint64_t PC) {
  if (Instr == nullptr) {
    errs() << "runnable-lift: null PTCInstruction pointer in translateCall\n";
    return Abort;
  }

  const PTC::CallInstruction TheCall(Instr);

  std::vector<Value *> InArgs;

  for (uint64_t TemporaryId : TheCall.InArguments) {
    auto *Temporary = Variables.getOrCreate(TemporaryId, true);
    if (Temporary == nullptr)
      return Abort;
    auto *Load = createLoad(Builder, Temporary);
    InArgs.push_back(Load);
  }

  auto GetValueType = [](Value *Argument) { return Argument->getType(); };
  std::vector<Type *> InArgsType = (InArgs | GetValueType).toVector();

  // TODO: handle multiple return arguments
  runnable_assert(TheCall.OutArguments.size() <= 1);

  Value *ResultDestination = nullptr;
  Type *ResultType = nullptr;

  if (TheCall.OutArguments.size() != 0) {
    ResultDestination = Variables.getOrCreate(TheCall.OutArguments[0], false);
    if (ResultDestination == nullptr)
      return Abort;
    ResultType = getPointerStorageType(ResultDestination);
  } else {
    ResultType = Builder.getVoidTy();
  }

  auto *CalleeType = FunctionType::get(ResultType,
                                       ArrayRef<Type *>(InArgsType),
                                       false);

  std::string HelperSuffix = TheCall.helperName();
  bool UnknownHelper = StringRef(HelperSuffix).startswith("unknown_0x");
  StoreInst *PCSaver = getLastUniqueWrite(Builder.GetInsertBlock(),
                                          JumpTargets.pcReg());
  if (UnknownHelper) {
    errs() << "runnable-lift: unresolved QEMU v2 PTC helper"
           << " helper=" << HelperSuffix << "\n";
    return Abort;
  }

  if (auto Lowered = tryLowerQEMUV2X86_64Syscall(Builder,
                                                 TheModule,
                                                 JumpTargets,
                                                 SourceArchitecture,
                                                 PC,
                                                 HelperSuffix,
                                                 InArgs,
                                                 PCSaver))
    return *Lowered;

  if (auto Lowered = tryLowerQEMUV2X86_64DivHelper(Builder,
                                                   TheModule,
                                                   SourceArchitecture,
                                                   HelperSuffix,
                                                   InArgs,
                                                   PCSaver))
    return *Lowered;

  std::string HelperName = "helper_" + HelperSuffix;
  Constant *FunctionDeclaration = runnable_llvm::getOrInsertFunction(TheModule,
                                                                     HelperName,
                                                                     CalleeType);

  bool SyncQEMUV2EnvBoundary =
    ptc_compat::isPTCAbiV2()
    && SourceArchitecture.type() == Triple::x86_64
    && !InArgs.empty()
    && Variables.isEnv(InArgs[0]);
  bool SyncWholeQEMUV2EnvBoundary =
    SyncQEMUV2EnvBoundary && isQEMUV2X86DivideHelper(HelperSuffix);
  std::vector<EnvSyncRange> QEMUV2HelperSyncRanges;
  if (SyncQEMUV2EnvBoundary && !SyncWholeQEMUV2EnvBoundary)
    QEMUV2HelperSyncRanges =
      collectQEMUV2HelperSyncRanges(TheModule,
                                    HelperName,
                                    HelperSuffix,
                                    InArgs,
                                    Variables);
  if (SyncWholeQEMUV2EnvBoundary
      && !Variables.syncCPUStateGlobalsWithEnvBacking(Builder,
                                                      InArgs[0],
                                                      true))
    return Abort;
  if (SyncQEMUV2EnvBoundary && !SyncWholeQEMUV2EnvBoundary
      && !syncQEMUV2HelperRanges(Builder,
                                 Variables,
                                 InArgs[0],
                                 QEMUV2HelperSyncRanges,
                                 true))
    return Abort;

  CallInst *Result = createCall(Builder, CalleeType, FunctionDeclaration, InArgs);

  if (SyncWholeQEMUV2EnvBoundary
      && !Variables.syncCPUStateGlobalsWithEnvBacking(Builder,
                                                      InArgs[0],
                                                      false))
    return Abort;
  if (SyncQEMUV2EnvBoundary && !SyncWholeQEMUV2EnvBoundary
      && !syncQEMUV2HelperRanges(Builder,
                                 Variables,
                                 InArgs[0],
                                 QEMUV2HelperSyncRanges,
                                 false))
    return Abort;

  if (TheCall.OutArguments.size() != 0)
    Builder.CreateStore(Result, ResultDestination);

  if (PCSaver != nullptr)
    return ForceNewPC;

  return Success;
}

IT::TranslationResult
IT::translate(PTCInstruction *Instr, uint64_t PC, uint64_t NextPC) {
  if (Instr == nullptr) {
    errs() << "runnable-lift: null PTCInstruction pointer in translate"
           << " pc=0x" << Twine::utohexstr(PC)
           << " next_pc=0x" << Twine::utohexstr(NextPC)
           << "\n";
    return Abort;
  }

  PTCOpcode Opcode = Instr->opc;
  if (validateOpcode(Instr) == Abort)
    return Abort;

  const PTC::Instruction TheInstruction(Instr);

  std::vector<Value *> InArgs;
  for (unsigned ArgIndex = 0; ArgIndex < TheInstruction.InArguments.size();
       ArgIndex++) {
    uint64_t TemporaryId = TheInstruction.InArguments[ArgIndex];
    auto *Temporary = Variables.getOrCreate(TemporaryId, true);
    if (Temporary == nullptr) {
      OpcodeMetadata Metadata = getOpcodeMetadata(Opcode);
      errs() << "runnable-lift: temp read failed"
             << " pc=0x" << Twine::utohexstr(PC)
             << " next_pc=0x" << Twine::utohexstr(NextPC)
             << " opcode=" << static_cast<unsigned>(Opcode)
             << " name="
             << (Metadata.Name != nullptr ? Metadata.Name : "<unknown>")
             << " arg_index=" << ArgIndex
             << " temp_id=" << TemporaryId
             << "\n";
      return Abort;
    }

    auto *Load = createLoad(Builder, Temporary);
    InArgs.push_back(Load);
  }

  auto ConstArgs = TheInstruction.ConstArguments;
  LastPC = PC;
  auto Result = translateOpcode(Opcode,
                                ConstArgs.toVector(),
                                InArgs);

  // Check if there was an error while translating the instruction
  if (!Result)
    return Abort;

  runnable_assert(Result->size() == (size_t) TheInstruction.OutArguments.size());
  // TODO: use ZipIterator here
  for (unsigned I = 0; I < Result->size(); I++) {
    auto *Destination = Variables.getOrCreate(TheInstruction.OutArguments[I],
                                              false);
    if (Destination == nullptr) {
      OpcodeMetadata Metadata = getOpcodeMetadata(Opcode);
      errs() << "runnable-lift: temp write failed"
             << " pc=0x" << Twine::utohexstr(PC)
             << " next_pc=0x" << Twine::utohexstr(NextPC)
             << " opcode=" << static_cast<unsigned>(Opcode)
             << " name="
             << (Metadata.Name != nullptr ? Metadata.Name : "<unknown>")
             << " arg_index=" << I
             << " temp_id=" << TheInstruction.OutArguments[I]
             << "\n";
      return Abort;
    }

    auto *Value = Result.get()[I];
    Builder.CreateStore(Value, Destination);

    // If we're writing somewhere an immediate, register it for exploration
    // immediately
//    auto *Constant = dyn_cast<ConstantInt>(Value);
//    if (Constant != nullptr) {
//
//      uint64_t Address = Constant->getLimitedValue();
//      if (PC != Address and JumpTargets.isPC(Address)
//          and not JumpTargets.hasJT(Address)) {
//
//        if (JumpTargets.isPCReg(Destination)) {
//          JumpTargets.registerJT(Address, JTReason::DirectJump);
//        } else {
//          JumpTargets.registerSimpleLiteral(Address);
//        }
//      }
//    }
  }

  return Success;
}

ErrorOr<std::vector<Value *>>
IT::translateOpcode(PTCOpcode Opcode,
                    std::vector<uint64_t> ConstArguments,
                    std::vector<Value *> InArguments) {
  LLVMContext &Context = TheModule.getContext();
  unsigned RegisterSize = getRegisterSize(Opcode);
  Type *RegisterType = nullptr;
  if (RegisterSize == 32)
    RegisterType = Builder.getInt32Ty();
  else if (RegisterSize == 64)
    RegisterType = Builder.getInt64Ty();
  else if (RegisterSize != 0)
    runnable_unreachable("Unexpected register size");

  using v = std::vector<Value *>;
  switch (Opcode) {
  case PTC_INSTRUCTION_op_movi_i32:
  case PTC_INSTRUCTION_op_movi_i64:
    return v{ ConstantInt::get(RegisterType, ConstArguments[0]) };
  case PTC_INSTRUCTION_op_discard:
    // Let's overwrite the discarded temporary with a 0
    return v{ ConstantInt::get(RegisterType, 0) };
  case PTC_INSTRUCTION_op_mov_i32:
  case PTC_INSTRUCTION_op_mov_i64:
    return v{ Builder.CreateTrunc(InArguments[0], RegisterType) };
  case PTC_INSTRUCTION_op_setcond_i32:
  case PTC_INSTRUCTION_op_setcond_i64: {
    Value *Compare = CreateICmp(Builder,
                                ConstArguments[0],
                                InArguments[0],
                                InArguments[1]);
    // TODO: convert single-bit registers to i1
    return v{ Builder.CreateZExt(Compare, RegisterType) };
  }
  case PTC_INSTRUCTION_op_movcond_i32: // Resist the fallthrough temptation
  case PTC_INSTRUCTION_op_movcond_i64: {
    Value *Compare = CreateICmp(Builder,
                                ConstArguments[0],
                                InArguments[0],
                                InArguments[1]);
    Value *Select = Builder.CreateSelect(Compare,
                                         InArguments[2],
                                         InArguments[3]);
    return v{ Select };
  }
  case PTC_INSTRUCTION_op_qemu_ld_i32:
  case PTC_INSTRUCTION_op_qemu_ld_i64:
  case PTC_INSTRUCTION_op_qemu_st_i32:
  case PTC_INSTRUCTION_op_qemu_st_i64: {
    PTCLoadStoreArg MemoryAccess;
    MemoryAccess = ptc_compat::parseLoadStoreArg(ptc, ConstArguments[0]);

    // What are we supposed to do in this case?
    runnable_assert(MemoryAccess.access_type != PTC_MEMORY_ACCESS_UNKNOWN);

    unsigned Alignment = 0;
    if (MemoryAccess.access_type == PTC_MEMORY_ACCESS_UNALIGNED)
      Alignment = 1;
    else
      Alignment = SourceArchitecture.defaultAlignment();

    // Load size
    IntegerType *MemoryType = nullptr;
    switch (ptc_get_memory_access_size(MemoryAccess.type)) {
    case PTC_MO_8:
      MemoryType = Builder.getInt8Ty();
      break;
    case PTC_MO_16:
      MemoryType = Builder.getInt16Ty();
      break;
    case PTC_MO_32:
      MemoryType = Builder.getInt32Ty();
      break;
    case PTC_MO_64:
      MemoryType = Builder.getInt64Ty();
      break;
    default:
      runnable_unreachable("Unexpected load size");
    }

    // If necessary, handle endianess mismatch
    // TODO: it might be a bit overkill, but it be nice to make this function
    //       template-parametric w.r.t. endianess mismatch
    Function *BSwapFunction = nullptr;
    if (MemoryType != Builder.getInt8Ty()
        && SourceArchitecture.endianess() != TargetArchitecture.endianess())
      BSwapFunction = Intrinsic::getDeclaration(&TheModule,
                                                Intrinsic::bswap,
                                                { MemoryType });

    bool SignExtend = ptc_is_sign_extended_load(MemoryAccess.type);

    Value *Pointer = nullptr;
    if (Opcode == PTC_INSTRUCTION_op_qemu_ld_i32
        || Opcode == PTC_INSTRUCTION_op_qemu_ld_i64) {

      Pointer = Builder.CreateIntToPtr(InArguments[0],
                                       MemoryType->getPointerTo());
      auto *Load = createAlignedLoad(Builder, MemoryType, Pointer, Alignment);
      Value *Loaded = Load;

      if (BSwapFunction != nullptr)
        Loaded = Builder.CreateCall(BSwapFunction, Load);

      if (SignExtend)
        return v{ Builder.CreateSExt(Loaded, RegisterType) };
      else
        return v{ Builder.CreateZExt(Loaded, RegisterType) };

    } else if (Opcode == PTC_INSTRUCTION_op_qemu_st_i32
               || Opcode == PTC_INSTRUCTION_op_qemu_st_i64) {

      Pointer = Builder.CreateIntToPtr(InArguments[1],
                                       MemoryType->getPointerTo());
      Value *Value = Builder.CreateTrunc(InArguments[0], MemoryType);

      if (BSwapFunction != nullptr)
        Value = Builder.CreateCall(BSwapFunction, Value);

      createAlignedStore(Builder, Value, Pointer, Alignment);

      return v{};
    } else {
      runnable_unreachable("Unknown load type");
    }
  }
  case PTC_INSTRUCTION_op_ld8u_i32:
  case PTC_INSTRUCTION_op_ld8s_i32:
  case PTC_INSTRUCTION_op_ld16u_i32:
  case PTC_INSTRUCTION_op_ld16s_i32:
  case PTC_INSTRUCTION_op_ld_i32:
  case PTC_INSTRUCTION_op_ld8u_i64:
  case PTC_INSTRUCTION_op_ld8s_i64:
  case PTC_INSTRUCTION_op_ld16u_i64:
  case PTC_INSTRUCTION_op_ld16s_i64:
  case PTC_INSTRUCTION_op_ld32u_i64:
  case PTC_INSTRUCTION_op_ld32s_i64:
  case PTC_INSTRUCTION_op_ld_i64: {
    Value *Base = dyn_cast<LoadInst>(InArguments[0])->getPointerOperand();
    if (Base == nullptr || !Variables.isEnv(Base)) {
      // TODO: emit warning
      return std::errc::invalid_argument;
    }

    bool Signed;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_ld_i32:
    case PTC_INSTRUCTION_op_ld_i64:

    case PTC_INSTRUCTION_op_ld8u_i32:
    case PTC_INSTRUCTION_op_ld16u_i32:
    case PTC_INSTRUCTION_op_ld8u_i64:
    case PTC_INSTRUCTION_op_ld16u_i64:
    case PTC_INSTRUCTION_op_ld32u_i64:
      Signed = false;
      break;
    case PTC_INSTRUCTION_op_ld8s_i32:
    case PTC_INSTRUCTION_op_ld16s_i32:
    case PTC_INSTRUCTION_op_ld8s_i64:
    case PTC_INSTRUCTION_op_ld16s_i64:
    case PTC_INSTRUCTION_op_ld32s_i64:
      Signed = true;
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    unsigned LoadSize;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_ld8u_i32:
    case PTC_INSTRUCTION_op_ld8s_i32:
    case PTC_INSTRUCTION_op_ld8u_i64:
    case PTC_INSTRUCTION_op_ld8s_i64:
      LoadSize = 1;
      break;
    case PTC_INSTRUCTION_op_ld16u_i32:
    case PTC_INSTRUCTION_op_ld16s_i32:
    case PTC_INSTRUCTION_op_ld16u_i64:
    case PTC_INSTRUCTION_op_ld16s_i64:
      LoadSize = 2;
      break;
    case PTC_INSTRUCTION_op_ld_i32:
    case PTC_INSTRUCTION_op_ld32u_i64:
    case PTC_INSTRUCTION_op_ld32s_i64:
      LoadSize = 4;
      break;
    case PTC_INSTRUCTION_op_ld_i64:
      LoadSize = 8;
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    uint64_t RawOffset = ConstArguments[0];
    int64_t SignedOffset = static_cast<int64_t>(RawOffset);
    bool FitsUnsigned =
      RawOffset == static_cast<uint64_t>(static_cast<unsigned>(RawOffset));
    Value *Result = nullptr;
    if (SignedOffset >= 0 && FitsUnsigned)
      Result = Variables.loadFromEnvOffset(Builder,
                                           LoadSize,
                                           static_cast<unsigned>(RawOffset));
    if (Result == nullptr && ptc_compat::isPTCAbiV2()) {
      Type *MemoryType = Builder.getIntNTy(LoadSize * 8);
      Value *Pointer = createEnvOffsetPointer(Builder,
                                              InArguments[0],
                                              MemoryType,
                                              SignedOffset);
      if (Pointer != nullptr)
        Result = createAlignedLoad(Builder, MemoryType, Pointer, 1);
    }
    runnable_assert(Result != nullptr);

    // Zero/sign extend in the target dimension
    if (Signed)
      return v{ Builder.CreateSExt(Result, RegisterType) };
    else
      return v{ Builder.CreateZExt(Result, RegisterType) };
  }
  case PTC_INSTRUCTION_op_st8_i32:
  case PTC_INSTRUCTION_op_st16_i32:
  case PTC_INSTRUCTION_op_st_i32:
  case PTC_INSTRUCTION_op_st8_i64:
  case PTC_INSTRUCTION_op_st16_i64:
  case PTC_INSTRUCTION_op_st32_i64:
  case PTC_INSTRUCTION_op_st_i64: {
    unsigned StoreSize;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_st8_i32:
    case PTC_INSTRUCTION_op_st8_i64:
      StoreSize = 1;
      break;
    case PTC_INSTRUCTION_op_st16_i32:
    case PTC_INSTRUCTION_op_st16_i64:
      StoreSize = 2;
      break;
    case PTC_INSTRUCTION_op_st_i32:
    case PTC_INSTRUCTION_op_st32_i64:
      StoreSize = 4;
      break;
    case PTC_INSTRUCTION_op_st_i64:
      StoreSize = 8;
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    Value *Base = dyn_cast<LoadInst>(InArguments[1])->getPointerOperand();
    if (Base == nullptr || !Variables.isEnv(Base)) {
      // TODO: emit warning
      return std::errc::invalid_argument;
    }

    uint64_t RawOffset = ConstArguments[0];
    int64_t SignedOffset = static_cast<int64_t>(RawOffset);
    bool FitsUnsigned =
      RawOffset == static_cast<uint64_t>(static_cast<unsigned>(RawOffset));
    bool Result = false;
    if (SignedOffset >= 0 && FitsUnsigned)
      Result = Variables.storeToEnvOffset(Builder,
                                          StoreSize,
                                          static_cast<unsigned>(RawOffset),
                                          InArguments[0]);
    if (!Result && ptc_compat::isPTCAbiV2()) {
      Type *MemoryType = Builder.getIntNTy(StoreSize * 8);
      Value *Pointer = createEnvOffsetPointer(Builder,
                                              InArguments[1],
                                              MemoryType,
                                              SignedOffset);
      if (Pointer != nullptr) {
        Value *ValueToStore = Builder.CreateTrunc(InArguments[0], MemoryType);
        createAlignedStore(Builder, ValueToStore, Pointer, 1);
        Result = true;
      }
    }
    runnable_assert(Result);

    return v{};
  }
  case PTC_INSTRUCTION_op_add_i32:
  case PTC_INSTRUCTION_op_sub_i32:
  case PTC_INSTRUCTION_op_mul_i32:
  case PTC_INSTRUCTION_op_div_i32:
  case PTC_INSTRUCTION_op_divu_i32:
  case PTC_INSTRUCTION_op_rem_i32:
  case PTC_INSTRUCTION_op_remu_i32:
  case PTC_INSTRUCTION_op_and_i32:
  case PTC_INSTRUCTION_op_or_i32:
  case PTC_INSTRUCTION_op_xor_i32:
  case PTC_INSTRUCTION_op_shl_i32:
  case PTC_INSTRUCTION_op_shr_i32:
  case PTC_INSTRUCTION_op_sar_i32:
  case PTC_INSTRUCTION_op_add_i64:
  case PTC_INSTRUCTION_op_sub_i64:
  case PTC_INSTRUCTION_op_mul_i64:
  case PTC_INSTRUCTION_op_div_i64:
  case PTC_INSTRUCTION_op_divu_i64:
  case PTC_INSTRUCTION_op_rem_i64:
  case PTC_INSTRUCTION_op_remu_i64:
  case PTC_INSTRUCTION_op_and_i64:
  case PTC_INSTRUCTION_op_or_i64:
  case PTC_INSTRUCTION_op_xor_i64:
  case PTC_INSTRUCTION_op_shl_i64:
  case PTC_INSTRUCTION_op_shr_i64:
  case PTC_INSTRUCTION_op_sar_i64: {
    // TODO: assert on sizes?
    Instruction::BinaryOps BinaryOp = opcodeToBinaryOp(Opcode);
    Value *Operation = Builder.CreateBinOp(BinaryOp,
                                           InArguments[0],
                                           InArguments[1]);
    return v{ Operation };
  }
  case PTC_INSTRUCTION_op_div2_i32:
  case PTC_INSTRUCTION_op_divu2_i32:
  case PTC_INSTRUCTION_op_div2_i64:
  case PTC_INSTRUCTION_op_divu2_i64: {
    Instruction::BinaryOps DivisionOp, RemainderOp;

    if (Opcode == PTC_INSTRUCTION_op_div2_i32
        || Opcode == PTC_INSTRUCTION_op_div2_i64) {
      DivisionOp = Instruction::SDiv;
      RemainderOp = Instruction::SRem;
    } else if (Opcode == PTC_INSTRUCTION_op_divu2_i32
               || Opcode == PTC_INSTRUCTION_op_divu2_i64) {
      DivisionOp = Instruction::UDiv;
      RemainderOp = Instruction::URem;
    } else {
      runnable_unreachable("Unknown operation type");
    }

    // TODO: we're ignoring InArguments[1], which is the MSB
    // TODO: assert on sizes?
    Value *Division = Builder.CreateBinOp(DivisionOp,
                                          InArguments[0],
                                          InArguments[2]);
    Value *Remainder = Builder.CreateBinOp(RemainderOp,
                                           InArguments[0],
                                           InArguments[2]);
    return v{ Division, Remainder };
  }
  case PTC_INSTRUCTION_op_rotr_i32:
  case PTC_INSTRUCTION_op_rotr_i64:
  case PTC_INSTRUCTION_op_rotl_i32:
  case PTC_INSTRUCTION_op_rotl_i64: {
    Value *Bits = ConstantInt::get(RegisterType, RegisterSize);

    Instruction::BinaryOps FirstShiftOp, SecondShiftOp;
    if (Opcode == PTC_INSTRUCTION_op_rotl_i32
        || Opcode == PTC_INSTRUCTION_op_rotl_i64) {
      FirstShiftOp = Instruction::Shl;
      SecondShiftOp = Instruction::LShr;
    } else if (Opcode == PTC_INSTRUCTION_op_rotr_i32
               || Opcode == PTC_INSTRUCTION_op_rotr_i64) {
      FirstShiftOp = Instruction::LShr;
      SecondShiftOp = Instruction::Shl;
    } else {
      runnable_unreachable("Unexpected opcode");
    }

    Value *FirstShift = Builder.CreateBinOp(FirstShiftOp,
                                            InArguments[0],
                                            InArguments[1]);
    Value *SecondShiftAmount = Builder.CreateSub(Bits, InArguments[1]);
    Value *SecondShift = Builder.CreateBinOp(SecondShiftOp,
                                             InArguments[0],
                                             SecondShiftAmount);

    return v{ Builder.CreateOr(FirstShift, SecondShift) };
  }
  case PTC_INSTRUCTION_op_deposit_i32:
  case PTC_INSTRUCTION_op_deposit_i64: {
    unsigned Position = ConstArguments[0];
    if (Position == RegisterSize)
      return v{ InArguments[0] };

    unsigned Length = ConstArguments[1];
    uint64_t Bits = 0;

    // Thou shall not << 32
    if (Length == RegisterSize)
      Bits = getMaxValue(RegisterSize);
    else
      Bits = (1 << Length) - 1;

    // result = (t1 & ~(bits << position)) | ((t2 & bits) << position)
    uint64_t BaseMask = ~(Bits << Position);
    Value *MaskedBase = Builder.CreateAnd(InArguments[0], BaseMask);
    Value *Deposit = Builder.CreateAnd(InArguments[1], Bits);
    Value *ShiftedDeposit = Builder.CreateShl(Deposit, Position);
    Value *Result = Builder.CreateOr(MaskedBase, ShiftedDeposit);

    return v{ Result };
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
    Type *SourceType = nullptr;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_ext8s_i32:
    case PTC_INSTRUCTION_op_ext8u_i32:
    case PTC_INSTRUCTION_op_ext8s_i64:
    case PTC_INSTRUCTION_op_ext8u_i64:
      SourceType = Builder.getInt8Ty();
      break;
    case PTC_INSTRUCTION_op_ext16s_i32:
    case PTC_INSTRUCTION_op_ext16u_i32:
    case PTC_INSTRUCTION_op_ext16s_i64:
    case PTC_INSTRUCTION_op_ext16u_i64:
      SourceType = Builder.getInt16Ty();
      break;
    case PTC_INSTRUCTION_op_ext32s_i64:
    case PTC_INSTRUCTION_op_ext32u_i64:
      SourceType = Builder.getInt32Ty();
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    Value *Truncated = Builder.CreateTrunc(InArguments[0], SourceType);

    switch (Opcode) {
    case PTC_INSTRUCTION_op_ext8s_i32:
    case PTC_INSTRUCTION_op_ext8s_i64:
    case PTC_INSTRUCTION_op_ext16s_i32:
    case PTC_INSTRUCTION_op_ext16s_i64:
    case PTC_INSTRUCTION_op_ext32s_i64:
      return v{ Builder.CreateSExt(Truncated, RegisterType) };
    case PTC_INSTRUCTION_op_ext8u_i32:
    case PTC_INSTRUCTION_op_ext8u_i64:
    case PTC_INSTRUCTION_op_ext16u_i32:
    case PTC_INSTRUCTION_op_ext16u_i64:
    case PTC_INSTRUCTION_op_ext32u_i64:
      return v{ Builder.CreateZExt(Truncated, RegisterType) };
    default:
      runnable_unreachable("Unexpected opcode");
    }
  }
  case PTC_INSTRUCTION_op_not_i32:
  case PTC_INSTRUCTION_op_not_i64:
    return v{ Builder.CreateXor(InArguments[0], getMaxValue(RegisterSize)) };
  case PTC_INSTRUCTION_op_neg_i32:
  case PTC_INSTRUCTION_op_neg_i64: {
    auto *InitialValue = ConstantInt::get(RegisterType, 0);
    return v{ Builder.CreateSub(InitialValue, InArguments[0]) };
  }
  case PTC_INSTRUCTION_op_andc_i32:
  case PTC_INSTRUCTION_op_andc_i64:
  case PTC_INSTRUCTION_op_orc_i32:
  case PTC_INSTRUCTION_op_orc_i64:
  case PTC_INSTRUCTION_op_eqv_i32:
  case PTC_INSTRUCTION_op_eqv_i64: {
    Instruction::BinaryOps ExternalOp;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_andc_i32:
    case PTC_INSTRUCTION_op_andc_i64:
      ExternalOp = Instruction::And;
      break;
    case PTC_INSTRUCTION_op_orc_i32:
    case PTC_INSTRUCTION_op_orc_i64:
      ExternalOp = Instruction::Or;
      break;
    case PTC_INSTRUCTION_op_eqv_i32:
    case PTC_INSTRUCTION_op_eqv_i64:
      ExternalOp = Instruction::Xor;
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    Value *Negate = Builder.CreateXor(InArguments[1],
                                      getMaxValue(RegisterSize));
    Value *Result = Builder.CreateBinOp(ExternalOp, InArguments[0], Negate);
    return v{ Result };
  }
  case PTC_INSTRUCTION_op_nand_i32:
  case PTC_INSTRUCTION_op_nand_i64: {
    Value *AndValue = Builder.CreateAnd(InArguments[0], InArguments[1]);
    Value *Result = Builder.CreateXor(AndValue, getMaxValue(RegisterSize));
    return v{ Result };
  }
  case PTC_INSTRUCTION_op_nor_i32:
  case PTC_INSTRUCTION_op_nor_i64: {
    Value *OrValue = Builder.CreateOr(InArguments[0], InArguments[1]);
    Value *Result = Builder.CreateXor(OrValue, getMaxValue(RegisterSize));
    return v{ Result };
  }
  case PTC_INSTRUCTION_op_bswap16_i32:
  case PTC_INSTRUCTION_op_bswap32_i32:
  case PTC_INSTRUCTION_op_bswap16_i64:
  case PTC_INSTRUCTION_op_bswap32_i64:
  case PTC_INSTRUCTION_op_bswap64_i64: {
    Type *SwapType = nullptr;
    switch (Opcode) {
    case PTC_INSTRUCTION_op_bswap16_i32:
    case PTC_INSTRUCTION_op_bswap16_i64:
      SwapType = Builder.getInt16Ty();
      break;
    case PTC_INSTRUCTION_op_bswap32_i32:
    case PTC_INSTRUCTION_op_bswap32_i64:
      SwapType = Builder.getInt32Ty();
      break;
    case PTC_INSTRUCTION_op_bswap64_i64:
      SwapType = Builder.getInt64Ty();
      break;
    default:
      runnable_unreachable("Unexpected opcode");
    }

    Value *Truncated = Builder.CreateTrunc(InArguments[0], SwapType);

    Function *BSwapFunction = Intrinsic::getDeclaration(&TheModule,
                                                        Intrinsic::bswap,
                                                        { SwapType });
    Value *Swapped = Builder.CreateCall(BSwapFunction, Truncated);

    return v{ Builder.CreateZExt(Swapped, RegisterType) };
  }
  case PTC_INSTRUCTION_op_set_label: {
    unsigned LabelId = getPTCLabelId(ConstArguments[0]);

    std::stringstream LabelSS;
    LabelSS << "bb." << compareAddressMarker(LastPC);
    LabelSS << "_L" << std::dec << LabelId;
    std::string Label = LabelSS.str();

    BasicBlock *Fallthrough = nullptr;
    auto ExistingBasicBlock = LabeledBasicBlocks.find(Label);

    if (ExistingBasicBlock == LabeledBasicBlocks.end()) {
      Fallthrough = BasicBlock::Create(Context, Label, TheFunction);
      Fallthrough->moveAfter(Builder.GetInsertBlock());
      LabeledBasicBlocks[Label] = Fallthrough;
      BranchLabeledBasicBlocks[Label] = Fallthrough;
    } else {
      // A basic block with that label already exist
      Fallthrough = LabeledBasicBlocks[Label];

      // Ensure it's empty
      runnable_assert(Fallthrough->begin() == Fallthrough->end());

      // Move it to the bottom
      if (Fallthrough != &TheFunction->back())
        Fallthrough->moveAfter(&TheFunction->back());
    }

    Builder.CreateBr(Fallthrough);

    Blocks.push_back(Fallthrough);
    Builder.SetInsertPoint(Fallthrough);
    Variables.newBasicBlock();

    return v{};
  }
  case PTC_INSTRUCTION_op_br:
  case PTC_INSTRUCTION_op_brcond_i32:
  case PTC_INSTRUCTION_op_brcond2_i32:
  case PTC_INSTRUCTION_op_brcond_i64: {
    // We take the last constant arguments, which is the LabelId both in
    // conditional and unconditional jumps
    unsigned LabelId = getPTCLabelId(ConstArguments.back());

    std::stringstream LabelSS;
    LabelSS << "bb." << compareAddressMarker(LastPC);
    LabelSS << "_L" << std::dec << LabelId;
    std::string Label = LabelSS.str();

    BasicBlock *Fallthrough = BasicBlock::Create(Context,
                                                 Label + "_ft",
                                                 TheFunction);

    // Look for a matching label
    BasicBlock *Target = nullptr;
    auto ExistingBasicBlock = LabeledBasicBlocks.find(Label);

    // No matching label, create a temporary block
    if (ExistingBasicBlock == LabeledBasicBlocks.end()) {
      Target = BasicBlock::Create(Context, Label, TheFunction);
      LabeledBasicBlocks[Label] = Target;
      //Adding create label to BranchLabeledBasicBlocks
      BranchLabeledBasicBlocks[Label] = Target;
    } else {
      Target = LabeledBasicBlocks[Label];
    }

    if (Opcode == PTC_INSTRUCTION_op_br) {
      // Unconditional jump
      Builder.CreateBr(Target);
    } else if (Opcode == PTC_INSTRUCTION_op_brcond_i32
               || Opcode == PTC_INSTRUCTION_op_brcond_i64) {
      // Conditional jump
      Value *Compare = CreateICmp(Builder,
                                  ConstArguments[0],
                                  InArguments[0],
                                  InArguments[1]);
      Builder.CreateCondBr(Compare, Target, Fallthrough);
      BranchLabeledBasicBlocks[Fallthrough->getName().str()] = Fallthrough;
    } else {
      runnable_unreachable("Unhandled opcode");
    }

    Blocks.push_back(Fallthrough);
    Builder.SetInsertPoint(Fallthrough);
    Variables.newBasicBlock();

    return v{};
  }
  case PTC_INSTRUCTION_op_exit_tb: {
    for (uint64_t TargetPC : ConstArguments) {
      if (TargetPC != 0)
        JumpTargets.registerJT(TargetPC, JTReason::DirectJump);
    }
    auto *Zero = ConstantInt::get(Type::getInt32Ty(Context), 0);
    auto *ExitCall = Builder.CreateCall(JumpTargets.exitTB(), { Zero });
    if (auto *PCWrite = JumpTargets.getPrevPCWrite(ExitCall)) {
      if (auto *Address = dyn_cast<ConstantInt>(PCWrite->getValueOperand()))
        JumpTargets.registerJT(Address->getZExtValue(), JTReason::DirectJump);
    }
    Builder.CreateUnreachable();

    auto *NextBB = BasicBlock::Create(Context, "", TheFunction);
    Blocks.push_back(NextBB);
    Builder.SetInsertPoint(NextBB);
    Variables.newBasicBlock();

    return v{};
  }
  case PTC_INSTRUCTION_op_goto_tb:
    // Nothing to do here
    return v{};
  case PTC_INSTRUCTION_op_add2_i32:
  case PTC_INSTRUCTION_op_sub2_i32:
  case PTC_INSTRUCTION_op_add2_i64:
  case PTC_INSTRUCTION_op_sub2_i64: {
    Value *FirstOpLow = nullptr;
    Value *FirstOpHigh = nullptr;
    Value *SecondOpLow = nullptr;
    Value *SecondOpHigh = nullptr;

    IntegerType *DestinationType = Builder.getIntNTy(RegisterSize * 2);

    FirstOpLow = Builder.CreateZExt(InArguments[0], DestinationType);
    FirstOpHigh = Builder.CreateZExt(InArguments[1], DestinationType);
    SecondOpLow = Builder.CreateZExt(InArguments[2], DestinationType);
    SecondOpHigh = Builder.CreateZExt(InArguments[3], DestinationType);

    FirstOpHigh = Builder.CreateShl(FirstOpHigh, RegisterSize);
    SecondOpHigh = Builder.CreateShl(SecondOpHigh, RegisterSize);

    Value *FirstOp = Builder.CreateOr(FirstOpHigh, FirstOpLow);
    Value *SecondOp = Builder.CreateOr(SecondOpHigh, SecondOpLow);

    Instruction::BinaryOps BinaryOp = opcodeToBinaryOp(Opcode);

    Value *Result = Builder.CreateBinOp(BinaryOp, FirstOp, SecondOp);

    Value *ResultLow = Builder.CreateTrunc(Result, RegisterType);
    Value *ShiftedResult = Builder.CreateLShr(Result, RegisterSize);
    Value *ResultHigh = Builder.CreateTrunc(ShiftedResult, RegisterType);

    return v{ ResultLow, ResultHigh };
  }
  case PTC_INSTRUCTION_op_mulu2_i32:
  case PTC_INSTRUCTION_op_mulu2_i64:
  case PTC_INSTRUCTION_op_muls2_i32:
  case PTC_INSTRUCTION_op_muls2_i64: {
    IntegerType *DestinationType = Builder.getIntNTy(RegisterSize * 2);

    Value *FirstOp = nullptr;
    Value *SecondOp = nullptr;

    if (Opcode == PTC_INSTRUCTION_op_mulu2_i32
        || Opcode == PTC_INSTRUCTION_op_mulu2_i64) {
      FirstOp = Builder.CreateZExt(InArguments[0], DestinationType);
      SecondOp = Builder.CreateZExt(InArguments[1], DestinationType);
    } else if (Opcode == PTC_INSTRUCTION_op_muls2_i32
               || Opcode == PTC_INSTRUCTION_op_muls2_i64) {
      FirstOp = Builder.CreateSExt(InArguments[0], DestinationType);
      SecondOp = Builder.CreateSExt(InArguments[1], DestinationType);
    } else {
      runnable_unreachable("Unexpected opcode");
    }

    Value *Result = Builder.CreateMul(FirstOp, SecondOp);

    Value *ResultLow = Builder.CreateTrunc(Result, RegisterType);
    Value *ShiftedResult = Builder.CreateLShr(Result, RegisterSize);
    Value *ResultHigh = Builder.CreateTrunc(ShiftedResult, RegisterType);

    return v{ ResultLow, ResultHigh };
  }
  case PTC_INSTRUCTION_op_muluh_i32:
  case PTC_INSTRUCTION_op_mulsh_i32:
  case PTC_INSTRUCTION_op_muluh_i64:
  case PTC_INSTRUCTION_op_mulsh_i64:

  case PTC_INSTRUCTION_op_setcond2_i32:

  case PTC_INSTRUCTION_op_trunc_shr_i32:
    runnable_unreachable("Instruction not implemented");
  default: {
    OpcodeMetadata Metadata = getOpcodeMetadata(Opcode);
    reportUnsupportedOpcode(Opcode, Metadata);
    return std::errc::invalid_argument;
  }
  }
}
