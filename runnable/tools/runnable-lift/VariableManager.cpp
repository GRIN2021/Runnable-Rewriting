/// \file variablemanager.cpp
/// \brief This file handles the creation and management of global variables,
///        i.e. mainly parts of the CPU state

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <algorithm>
#include <cstdint>
#include <set>
#include <sstream>
#include <stack>
#include <string>

// LLVM includes
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/IR/Type.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/ValueMapper.h"

// Local libraries includes
#include "runnable/Support/Debug.h"
#include "runnable/Support/IRHelpers.h"
#include "runnable/Support/runnable.h"

// Local includes
#include "PTCDump.h"
#include "PTCInterface.h"
#include "VariableManager.h"

using namespace llvm;

static Logger<> VMStateLog("vm-state");

namespace {

static const char *ptcTypeName(PTCType Type) {
  switch (Type) {
  case PTC_TYPE_I32:
    return "PTC_TYPE_I32";
  case PTC_TYPE_I64:
    return "PTC_TYPE_I64";
  default:
    return nullptr;
  }
}

static bool isSupportedScalarPTCType(PTCType Type) {
  return Type == PTC_TYPE_I32 || Type == PTC_TYPE_I64;
}

static void describePTCType(raw_ostream &OS,
                            const char *FieldName,
                            PTCType Type) {
  unsigned RawType = static_cast<unsigned>(Type);
  OS << FieldName << "=";

  if (const char *Name = ptcTypeName(Type)) {
    OS << Name;
    return;
  }

  OS << "unsupported(" << RawType << ")";
  if (RawType >= static_cast<unsigned>(PTC_TYPE_COUNT))
    OS << "/unknown";
}

static void reportInvalidPTCTemp(PTCInstructionList *Instructions,
                                 unsigned TemporaryId) {
  errs() << "runnable-lift: invalid PTC temp reference"
         << " temp_id=" << TemporaryId;
  if (Instructions != nullptr) {
    errs() << " total_temps=" << Instructions->total_temps
           << " global_temps=" << Instructions->global_temps
           << " temps="
           << static_cast<const void *>(Instructions->temps);
  } else {
    errs() << " instruction_list=<null>";
  }
  errs() << "\n";
}

static void reportUnsupportedPTCTempSchema(unsigned TemporaryId,
                                           const PTCTemp &Temporary,
                                           const char *Reason) {
  errs() << "runnable-lift: unsupported PTC temp schema"
         << " temp_id=" << TemporaryId
         << " name="
         << (Temporary.name != nullptr ? Temporary.name : "<unnamed>")
         << " reason=" << Reason << " ";
  describePTCType(errs(), "type", Temporary.type);
  errs() << " ";
  describePTCType(errs(), "base_type", Temporary.base_type);
  errs() << " val_type=" << static_cast<unsigned>(Temporary.val_type)
         << " fixed_reg=" << Temporary.fixed_reg
         << " temp_local=" << Temporary.temp_local
         << " mem_offset=" << Temporary.mem_offset << "\n";
  errs() << "runnable-lift: only legacy scalar PTC temp types PTC_TYPE_I32"
         << " and PTC_TYPE_I64 are supported; I128/vector/future temp"
         << " schemas require explicit lowering and will not be treated as"
         << " i64\n";
}

static Type *typeForPTCTemp(IRBuilder<> &Builder,
                            unsigned TemporaryId,
                            const PTCTemp &Temporary) {
  if (!isSupportedScalarPTCType(Temporary.type)) {
    reportUnsupportedPTCTempSchema(TemporaryId, Temporary,
                                   "unsupported result type");
    return nullptr;
  }

  if (!isSupportedScalarPTCType(Temporary.base_type)) {
    reportUnsupportedPTCTempSchema(TemporaryId, Temporary,
                                   "unsupported base type");
    return nullptr;
  }

  if (Temporary.type == PTC_TYPE_I32)
    return Builder.getInt32Ty();

  return Builder.getInt64Ty();
}

static bool shouldSeedAllocatedTemp(const PTCTemp &Temporary) {
  // QEMU v2 sidecar payloads can expose allocated temps that are already live
  // at TB entry. Some of those are reported as TEMP_VAL_DEAD with val=0 even
  // though following ops read them before a local write. Treat the sidecar's
  // saved value as the TB-entry seed instead of aborting the translation.
  return RunnablePTCAbiMetadata.HasAbiVersion
         && RunnablePTCAbiMetadata.AbiVersion >= 2
         && Temporary.temp_allocated
         && !Temporary.fixed_reg;
}

static bool isQEMUV2TBScopedTemp(const PTCTemp &Temporary) {
  return ptc_compat::isPTCAbiV2()
         && Temporary.temp_allocated
         && !Temporary.fixed_reg;
}

static StructType *getNonOpaquePointeeStruct(Type *MaybePointerType) {
#if LLVM_VERSION_MAJOR < 15
  if (MaybePointerType->isPointerTy())
    return dyn_cast<StructType>(MaybePointerType->getPointerElementType());
#else
  (void) MaybePointerType;
#endif
  return nullptr;
}

#if LLVM_VERSION_MAJOR >= 15
static StructType *inferPointeeStructFromUses(Value *MaybePointer,
                                              SmallPtrSetImpl<Value *> &Visited) {
  if (!MaybePointer->getType()->isPointerTy())
    return nullptr;
  if (!Visited.insert(MaybePointer).second)
    return nullptr;

  for (User *TheUser : MaybePointer->users()) {
    if (auto *GEP = dyn_cast<GetElementPtrInst>(TheUser)) {
      if (auto *Struct = dyn_cast<StructType>(GEP->getSourceElementType()))
        return Struct;
    }
    if (auto *Load = dyn_cast<LoadInst>(TheUser)) {
      if (auto *Struct = inferPointeeStructFromUses(Load, Visited))
        return Struct;
      continue;
    }
    if (auto *Store = dyn_cast<StoreInst>(TheUser)) {
      if (Store->getValueOperand() == MaybePointer) {
        if (auto *Struct = inferPointeeStructFromUses(Store->getPointerOperand(),
                                                      Visited))
          return Struct;
      }
      continue;
    }
    if (auto *Cast = dyn_cast<CastInst>(TheUser)) {
      if (auto *Struct = inferPointeeStructFromUses(Cast, Visited))
        return Struct;
      continue;
    }
  }
  return nullptr;
}

static StructType *inferPointeeStructFromUses(Value *MaybePointer) {
  SmallPtrSet<Value *, 8> Visited;
  return inferPointeeStructFromUses(MaybePointer, Visited);
}
#endif

static Type *getPointerValueType(Value *Pointer) {
  if (auto *Global = dyn_cast<GlobalVariable>(Pointer))
    return Global->getValueType();
  if (auto *Alloca = dyn_cast<AllocaInst>(Pointer))
    return Alloca->getAllocatedType();
#if LLVM_VERSION_MAJOR >= 15
  if (auto *GEP = dyn_cast<GetElementPtrInst>(Pointer))
    return GEP->getResultElementType();

  runnable_abort("Cannot infer value type from an opaque pointer");
  return nullptr;
#else
  return Pointer->getType()->getPointerElementType();
#endif
}

static LoadInst *createLoad(IRBuilder<> &Builder,
                            Type *ValueType,
                            Value *Pointer) {
#if LLVM_VERSION_MAJOR >= 15
  return Builder.CreateLoad(ValueType, Pointer);
#else
  (void) ValueType;
  return Builder.CreateLoad(Pointer);
#endif
}

static LoadInst *createLoad(Type *ValueType,
                            Value *Pointer,
                            const Twine &Name,
                            Instruction *InsertBefore) {
#if LLVM_VERSION_MAJOR >= 15
  return new LoadInst(ValueType, Pointer, Name, InsertBefore);
#else
  (void) ValueType;
  return new LoadInst(Pointer, Name, InsertBefore);
#endif
}

static Value *coerceEnvToI8Ptr(IRBuilder<> &Builder, Value *EnvValue) {
  PointerType *I8PtrTy = runnable_llvm::getInt8PtrTy(Builder.getContext());
  if (EnvValue->getType()->isPointerTy())
    return Builder.CreateBitCast(EnvValue, I8PtrTy);
  if (EnvValue->getType()->isIntegerTy())
    return Builder.CreateIntToPtr(EnvValue, I8PtrTy);
  return nullptr;
}

static Value *createEnvBackingOffsetPointer(IRBuilder<> &Builder,
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

} // namespace

// TODO: rename
cl::opt<bool> External("external",
                       cl::desc("set CSVs linkage to external, useful for "
                                "debugging purposes"),
                       cl::cat(MainCategory));
static cl::alias A1("E",
                    cl::desc("Alias for -external"),
                    cl::aliasopt(External),
                    cl::cat(MainCategory));

class OffsetValueStack {

private:
  using OffsetValuePair = std::pair<int64_t, Value *>;

public:
  void pushIfNew(int64_t Offset, Value *V) {
    OffsetValuePair Element = { Offset, V };
    if (!Seen.count(Element)) {
      Seen.insert(Element);
      Stack.push_back(Element);
    }
  }

  void push(int64_t Offset, Value *V) {
    OffsetValuePair Element = { Offset, V };
    Stack.push_back(Element);
  }

  bool empty() { return Stack.empty(); }

  std::pair<int64_t, Value *> pop() {
    auto Result = Stack.back();
    Stack.pop_back();
    return Result;
  }

  // TODO: this is on O(n)
  void cloneSisters(Value *Old, Value *New) {
    for (auto &OVP : Stack)
      if (OVP.second == Old)
        push(OVP.first, New);
  }

private:
  std::set<OffsetValuePair> Seen;
  std::vector<OffsetValuePair> Stack;
};

static std::pair<IntegerType *, unsigned>
getTypeAtOffset(const DataLayout *TheLayout, Type *VarType, intptr_t Offset) {
  static Logger<> Log("type-at-offset");

  unsigned Depth = 0;
  while (1) {
    switch (VarType->getTypeID()) {
    case llvm::Type::TypeID::PointerTyID:
      // BEWARE: here we return { nullptr, 0 } as an intended workaround for
      // a specific situation.
      //
      // We can't use assertions on pointers, as we do for all the other
      // unhandled types, because they will be inevitably triggered during the
      // execution. Indeed, all the other types are not present in QEMU
      // CPUState and we can safely assert it. This is not true for pointers
      // that are used in different places in QEMU CPUState.
      //
      // Given that we have ruled out assertions, we need to handle the
      // pointer case so that it keeps working. This function is expected to
      // return { nullptr, 0 } when the offset points to a memory location
      // associated to padding space. In principle, pointers are not padding
      // space, but the result of returning { nullptr, 0 } here is that load
      // and store operations treat pointers like padding. This means that
      // pointers cannot be read or written, and memcpy simply skips over them
      // leaving them alone.
      //
      // This behavior is intended, because a pointer into the CPUState could
      // be used to modify CPU registers indirectly, which is against all the
      // assumption of the analysis necessary for the translation, and also
      // against what really happens in a CPU, where CPU state cannot be
      // addressed.
      return { nullptr, 0 };

    case llvm::Type::TypeID::IntegerTyID:
      return { cast<IntegerType>(VarType), Offset };

    case llvm::Type::TypeID::ArrayTyID:
      VarType = VarType->getArrayElementType();
      Offset %= TheLayout->getTypeAllocSize(VarType);
      runnable_log(Log,
                std::string(Depth++ * 2, ' ')
                  << " Is an Array. Offset in Element: " << Offset);
      break;

    case llvm::Type::TypeID::StructTyID: {
      StructType *TheStruct = cast<StructType>(VarType);
      const StructLayout *Layout = TheLayout->getStructLayout(TheStruct);
      unsigned FieldIndex = Layout->getElementContainingOffset(Offset);
      uint64_t FieldOffset = Layout->getElementOffset(FieldIndex);
      VarType = TheStruct->getTypeAtIndex(FieldIndex);
      intptr_t FieldEnd = FieldOffset + TheLayout->getTypeAllocSize(VarType);

      runnable_log(Log,
                std::string(Depth++ * 2, ' ')
                  << " Offset: " << Offset
                  << " Struct Name: " << TheStruct->getName().str()
                  << " Field Index: " << FieldIndex << " Field offset: "
                  << FieldOffset << " Field end: " << FieldEnd);

      if (Offset >= FieldEnd)
        return { nullptr, 0 }; // It's padding

      Offset -= FieldOffset;
    } break;

    default:
      runnable_abort("unexpected TypeID");
    }
  }
}

VariableManager::VariableManager(Module &TheModule,
                                 Module &HelpersModule,
                                 Architecture &TargetArchitecture) :
  TheModule(TheModule),
  Builder(TheModule.getContext()),
  CPUStateType(nullptr),
  ModuleLayout(&HelpersModule.getDataLayout()),
  EnvOffset(0),
  Env(nullptr),
  EnvBacking(nullptr),
  TargetArchitecture(TargetArchitecture) {

  runnable_assert(ptc.initialized_env != nullptr);

  using ElectionMap = std::map<StructType *, unsigned>;
  using ElectionMapElement = std::pair<StructType *const, unsigned>;
  ElectionMap EnvElection;
  const std::string HelperPrefix = "helper_";
  std::set<StructType *> Structs;
  for (Function &HelperFunction : HelpersModule) {
    FunctionType *HelperType = HelperFunction.getFunctionType();
    Type *ReturnType = HelperType->getReturnType();
    Structs.insert(getNonOpaquePointeeStruct(ReturnType));

    for (Type *Param : HelperType->params())
      Structs.insert(getNonOpaquePointeeStruct(Param));

    if (startsWith(HelperFunction.getName().str(), HelperPrefix)
        && HelperFunction.getFunctionType()->getNumParams() > 1) {

      for (unsigned Index = 0; Index < HelperType->getNumParams(); ++Index) {
        Type *Candidate = HelperType->getParamType(Index);
        Structs.insert(dyn_cast<StructType>(Candidate));
        auto *EnvType = getNonOpaquePointeeStruct(Candidate);
#if LLVM_VERSION_MAJOR >= 15
        if (EnvType == nullptr) {
          auto ArgIt = HelperFunction.arg_begin();
          std::advance(ArgIt, Index);
          EnvType = inferPointeeStructFromUses(&*ArgIt);
        }
#endif
        // Ensure it is a struct and not a union
        if (EnvType != nullptr && EnvType->getNumElements() > 1) {

          auto It = EnvElection.find(EnvType);
          if (It != EnvElection.end())
            EnvElection[EnvType]++;
          else
            EnvElection[EnvType] = 1;
        }
      }
    }
  }

  Structs.erase(nullptr);

  runnable_assert(EnvElection.size() > 0);

  auto Compare = [](ElectionMapElement &It1, ElectionMapElement &It2) {
    return It1.second < It2.second;
  };
  auto Max = std::max_element(EnvElection.begin(), EnvElection.end(), Compare);
  CPUStateType = Max->first;

  // Look for structures containing CPUStateType as a member and promove them
  // to CPUStateType. Basically this is a flexible way to keep track of the *CPU
  // struct too (e.g. MIPSCPU).
  std::set<StructType *> Visited;
  bool Changed = true;
  Visited.insert(CPUStateType);
  while (Changed) {
    Changed = false;
    for (StructType *TheStruct : Structs) {
      if (Visited.find(TheStruct) != Visited.end())
        continue;

      auto Begin = TheStruct->element_begin();
      auto End = TheStruct->element_end();
      auto Found = std::find(Begin, End, CPUStateType);
      if (Found != End) {
        unsigned Index = Found - Begin;
        const StructLayout *Layout = nullptr;
        Layout = ModuleLayout->getStructLayout(TheStruct);
        EnvOffset += Layout->getElementOffset(Index);
        CPUStateType = TheStruct;
        Visited.insert(CPUStateType);
        Changed = true;
        break;
      }
    }
  }

  runnable_log(VMStateLog,
               "CPUStateType=" << CPUStateType->getName().str()
                               << " EnvOffset=" << EnvOffset
                               << " ptc.pc=" << ptc.pc
                               << " ptc.sp=" << ptc.sp
                               << " initialized_env="
                               << static_cast<const void *>(ptc.initialized_env)
                               << DoLog);
}

GlobalVariable *VariableManager::getOrCreateEnvPointerGlobal() {
  if (Env != nullptr) {
    auto *EnvGlobal = dyn_cast<GlobalVariable>(Env);
    runnable_assert(EnvGlobal != nullptr);
    return EnvGlobal;
  }

  auto &Context = TheModule.getContext();
  Type *Int64Ty = Type::getInt64Ty(Context);
  Type *Int8Ty = Type::getInt8Ty(Context);
  PointerType *Int8PtrTy = Int8Ty->getPointerTo();

  if (EnvBacking == nullptr) {
    EnvBacking = new GlobalVariable(TheModule,
                                    CPUStateType,
                                    false,
                                    GlobalValue::InternalLinkage,
                                    ConstantAggregateZero::get(CPUStateType),
                                    "runnable_cpu_state");
  }

  Constant *EnvAddress = EnvBacking;
  if (EnvOffset != 0) {
    EnvAddress = ConstantExpr::getBitCast(EnvAddress, Int8PtrTy);
    EnvAddress =
      ConstantExpr::getGetElementPtr(Int8Ty,
                                     EnvAddress,
                                     ConstantInt::get(Int64Ty, EnvOffset));
  }

  Constant *EnvInitialValue = ConstantExpr::getPtrToInt(EnvAddress, Int64Ty);
  auto *EnvGlobal = new GlobalVariable(TheModule,
                                       Int64Ty,
                                       false,
                                       GlobalValue::InternalLinkage,
                                       EnvInitialValue,
                                       "env");
  Env = EnvGlobal;
  return EnvGlobal;
}

bool VariableManager::storeToCPUStateOffset(IRBuilder<> &Builder,
                                            unsigned StoreSize,
                                            unsigned Offset,
                                            Value *ToStore) {
  auto CoerceToWidth = [&](Value *Input, unsigned Bits) -> Value * {
    auto *TargetTy = Builder.getIntNTy(Bits);
    if (Input->getType() == TargetTy)
      return Input;
    auto *InputTy = dyn_cast<IntegerType>(Input->getType());
    if (InputTy == nullptr)
      return nullptr;
    if (InputTy->getBitWidth() < Bits)
      return Builder.CreateZExt(Input, TargetTy);
    return Builder.CreateTrunc(Input, TargetTy);
  };

  auto StoreSingle = [&](unsigned SingleStoreSize,
                         unsigned SingleOffset,
                         Value *SingleValue) -> bool {
    Value *Target;
    unsigned Remaining;
    std::tie(Target, Remaining) = getByCPUStateOffsetInternal(SingleOffset);

    if (Target == nullptr)
      return false;

    auto *InputStoreTy =
      cast<IntegerType>(Builder.getIntNTy(SingleStoreSize * 8));
    auto *FieldTy = cast<IntegerType>(getPointerValueType(Target));
    unsigned FieldSize = FieldTy->getBitWidth() / 8;
    if (Remaining >= FieldSize)
      return false;
    unsigned Available = FieldSize - Remaining;
    if (SingleStoreSize > Available)
      return false;
    unsigned StoreBits = SingleStoreSize * 8;
    unsigned FieldBits = FieldTy->getBitWidth();

    unsigned ShiftAmount = 0;
    if (TargetArchitecture.isLittleEndian())
      ShiftAmount = Remaining;
    else {
      // >> (Size1 - Size2) - Remaining;
      ShiftAmount = (FieldSize - SingleStoreSize) - Remaining;
    }
    ShiftAmount *= 8;

    // Truncate value to store
    Value *Truncated = CoerceToWidth(SingleValue, InputStoreTy->getBitWidth());
    if (Truncated == nullptr)
      return false;

    if (SingleStoreSize == FieldSize && Remaining == 0) {
      Value *ValueToStore = CoerceToWidth(Truncated, FieldBits);
      if (ValueToStore == nullptr)
        return false;
      Builder.CreateStore(ValueToStore, Target);
      return true;
    }

    // Re-extend to the field width only for true subfield merges.
    Value *ValueToStore = CoerceToWidth(Truncated, FieldBits);
    if (ValueToStore == nullptr)
      return false;

    runnable_assert(ShiftAmount < FieldBits);
    runnable_assert(ShiftAmount + StoreBits <= FieldBits);
    APInt StoreMask = APInt::getLowBitsSet(FieldBits, StoreBits);
    StoreMask <<= ShiftAmount;
    APInt PreserveMask = ~StoreMask;
    runnable_assert(!PreserveMask.isNullValue());

    if (ShiftAmount != 0)
      ValueToStore = Builder.CreateShl(ValueToStore, ShiftAmount);

    // Load only for partial-field updates where bytes outside StoreMask survive.
    auto *LoadEnvField = createLoad(Builder, FieldTy, Target);

    auto *Blanked =
      Builder.CreateAnd(LoadEnvField, ConstantInt::get(FieldTy, PreserveMask));

    // Combine them
    ValueToStore = Builder.CreateOr(ValueToStore, Blanked);

    Builder.CreateStore(ValueToStore, Target);

    return true;
  };

  if (StoreSingle(StoreSize, Offset, ToStore))
    return true;

  if (getByCPUStateOffsetInternal(Offset).first == nullptr)
    return false;

  Value *StoreValue = CoerceToWidth(ToStore, StoreSize * 8);
  if (StoreValue == nullptr)
    return false;

  unsigned Processed = 0;
  while (Processed < StoreSize) {
    unsigned CurrentOffset = Offset + Processed;
    Value *Target;
    unsigned Remaining;
    std::tie(Target, Remaining) = getByCPUStateOffsetInternal(CurrentOffset);

    unsigned SegmentSize = 1;
    if (Target != nullptr) {
      auto *FieldTy = cast<IntegerType>(getPointerValueType(Target));
      unsigned FieldSize = FieldTy->getBitWidth() / 8;
      if (Remaining >= FieldSize)
        return false;
      SegmentSize = std::min(StoreSize - Processed, FieldSize - Remaining);
    }

    if (Target != nullptr) {
      unsigned ShiftBytes = TargetArchitecture.isLittleEndian() ?
                              Processed :
                              StoreSize - Processed - SegmentSize;
      Value *Segment = StoreValue;
      if (ShiftBytes != 0)
        Segment = Builder.CreateLShr(Segment, ShiftBytes * 8);
      Segment = Builder.CreateTrunc(Segment,
                                    Builder.getIntNTy(SegmentSize * 8));
      if (!StoreSingle(SegmentSize, CurrentOffset, Segment))
        return false;
    }

    Processed += SegmentSize;
  }

  return true;
}

Value *VariableManager::loadFromCPUStateOffset(IRBuilder<> &Builder,
                                               unsigned LoadSize,
                                               unsigned Offset) {
  auto LoadSingle = [&](unsigned SingleLoadSize,
                        unsigned SingleOffset) -> Value * {
    Value *Target;
    unsigned Remaining;
    std::tie(Target, Remaining) = getByCPUStateOffsetInternal(SingleOffset);

    if (Target == nullptr)
      return nullptr;

    auto *FieldTy = cast<IntegerType>(getPointerValueType(Target));
    unsigned FieldSize = FieldTy->getBitWidth() / 8;
    if (Remaining >= FieldSize)
      return nullptr;
    unsigned Available = FieldSize - Remaining;
    if (SingleLoadSize > Available)
      return nullptr;

    // Load the whole field
    auto *LoadEnvField = createLoad(Builder, FieldTy, Target);

    // Extract the desired part
    // Shift right of the desired amount
    unsigned ShiftAmount = 0;
    if (TargetArchitecture.isLittleEndian()) {
      ShiftAmount = Remaining;
    } else {
      // >> (Size1 - Size2) - Remaining;
      ShiftAmount = (FieldSize - SingleLoadSize) - Remaining;
    }
    ShiftAmount *= 8;
    Value *Result = LoadEnvField;

    if (ShiftAmount != 0)
      Result = Builder.CreateLShr(Result, ShiftAmount);

    Type *LoadTy = Builder.getIntNTy(SingleLoadSize * 8);

    // Truncate of the desired amount
    return Builder.CreateTrunc(Result, LoadTy);
  };

  if (Value *Single = LoadSingle(LoadSize, Offset))
    return Single;

  if (getByCPUStateOffsetInternal(Offset).first == nullptr)
    return nullptr;

  Type *LoadTy = Builder.getIntNTy(LoadSize * 8);
  Value *Result = ConstantInt::get(LoadTy, 0);

  unsigned Processed = 0;
  while (Processed < LoadSize) {
    unsigned CurrentOffset = Offset + Processed;
    Value *Target;
    unsigned Remaining;
    std::tie(Target, Remaining) = getByCPUStateOffsetInternal(CurrentOffset);

    unsigned SegmentSize = 1;
    if (Target != nullptr) {
      auto *FieldTy = cast<IntegerType>(getPointerValueType(Target));
      unsigned FieldSize = FieldTy->getBitWidth() / 8;
      if (Remaining >= FieldSize)
        return nullptr;
      SegmentSize = std::min(LoadSize - Processed, FieldSize - Remaining);
    }

    if (Target != nullptr) {
      Value *Segment = LoadSingle(SegmentSize, CurrentOffset);
      if (Segment == nullptr)
        return nullptr;
      Segment = Builder.CreateZExt(Segment, LoadTy);
      unsigned ShiftBytes = TargetArchitecture.isLittleEndian() ?
                              Processed :
                              LoadSize - Processed - SegmentSize;
      if (ShiftBytes != 0)
        Segment = Builder.CreateShl(Segment, ShiftBytes * 8);
      Result = Builder.CreateOr(Result, Segment);
    }

    Processed += SegmentSize;
  }

  return Result;
}

bool VariableManager::memcpyAtEnvOffset(llvm::IRBuilder<> &Builder,
                                        llvm::CallInst *CallMemcpy,
                                        unsigned InitialEnvOffset,
                                        bool EnvIsSrc) {
  Function *Callee = getCallee(CallMemcpy);
  // We only support memcpys where the last parameter is constant
  runnable_assert(Callee != nullptr
               and (Callee->getIntrinsicID() == Intrinsic::memcpy
                    and isa<ConstantInt>(CallMemcpy->getArgOperand(2))));

  Value *OtherOp = CallMemcpy->getArgOperand(EnvIsSrc ? 0 : 1);
  auto *MemcpySize = cast<Constant>(CallMemcpy->getArgOperand(2));
  Value *OtherBasePtr = Builder.CreatePtrToInt(OtherOp, Builder.getInt64Ty());

  uint64_t TotalSize = getZExtValue(MemcpySize, *ModuleLayout);
  uint64_t Offset = 0;

  bool OnlyPointersAndPadding = true;
  while (Offset < TotalSize) {
    GlobalVariable *EnvVar = getByEnvOffset(InitialEnvOffset + Offset).first;

    // Consider the case when there's simply nothing there (alignment space).
    if (EnvVar == nullptr) {
      // TODO: remove "false and", but after adding type based stuff
      if (false && EnvIsSrc) {
        ConstantInt *ZeroByte = Builder.getInt8(0);
        ConstantInt *OffsetInt = Builder.getInt64(Offset);
        Value *NewAddress = Builder.CreateAdd(OffsetInt, OtherBasePtr);
        Type *Int8PtrTy = Builder.getInt8Ty()->getPointerTo();
        Value *OtherPtr = Builder.CreateIntToPtr(NewAddress, Int8PtrTy);
        Builder.CreateStore(ZeroByte, OtherPtr);
        OnlyPointersAndPadding = false;
      }
      Offset++;
      continue;
    }
    OnlyPointersAndPadding = false;

    ConstantInt *OffsetInt = Builder.getInt64(Offset);
    Value *NewAddress = Builder.CreateAdd(OffsetInt, OtherBasePtr);
    Value *OtherPtr = Builder.CreateIntToPtr(NewAddress, EnvVar->getType());

    Value *Dst = EnvIsSrc ? OtherPtr : EnvVar;
    Value *Src = EnvIsSrc ? EnvVar : OtherPtr;

    Type *EnvVarTy = EnvVar->getValueType();
    Builder.CreateStore(createLoad(Builder, EnvVarTy, Src), Dst);

    Offset += ModuleLayout->getTypeAllocSize(EnvVarTy);
  }

  if (OnlyPointersAndPadding)
    cast<Instruction>(OtherBasePtr)->eraseFromParent();

  return Offset == TotalSize;
}

bool VariableManager::syncCPUStateGlobalsWithEnvBacking(IRBuilder<> &Builder,
                                                        Value *EnvValue,
                                                        bool FlushToEnv) {
  if (EnvValue == nullptr)
    return false;

  bool SyncedAny = false;
  for (const auto &Entry : CPUStateGlobals) {
    intptr_t AbsoluteOffset = Entry.first;
    GlobalVariable *CSV = Entry.second;
    if (CSV == nullptr)
      continue;

    Type *CSVType = CSV->getValueType();
    if (!CSVType->isIntegerTy())
      continue;

    int64_t EnvRelativeOffset =
      static_cast<int64_t>(AbsoluteOffset)
      - static_cast<int64_t>(EnvOffset);
    Value *BackingSlot =
      createEnvBackingOffsetPointer(Builder,
                                    EnvValue,
                                    CSVType,
                                    EnvRelativeOffset);
    if (BackingSlot == nullptr)
      return false;

    if (FlushToEnv) {
      Value *CSVValue = createLoad(Builder, CSVType, CSV);
      Builder.CreateStore(CSVValue, BackingSlot);
    } else {
      Value *BackingValue = createLoad(Builder, CSVType, BackingSlot);
      Builder.CreateStore(BackingValue, CSV);
    }

    SyncedAny = true;
  }

  static bool Reported = false;
  if (SyncedAny && !Reported) {
    errs() << "runnable-lift: syncing QEMU v2 CPUState CSVs at helper"
           << " env backing boundary\n";
    Reported = true;
  }

  return true;
}

bool VariableManager::syncCPUStateRangeWithEnvBacking(IRBuilder<> &Builder,
                                                      Value *EnvValue,
                                                      intptr_t EnvRelativeOffset,
                                                      uint64_t Size,
                                                      bool FlushToEnv) {
  if (EnvValue == nullptr || Size == 0)
    return false;

  uint64_t Processed = 0;
  std::set<intptr_t> SyncedOffsets;
  while (Processed < Size) {
    intptr_t AbsoluteOffset =
      static_cast<intptr_t>(EnvOffset) + EnvRelativeOffset + Processed;

    GlobalVariable *CSV = nullptr;
    unsigned Remaining = 0;
    std::tie(CSV, Remaining) = getByCPUStateOffsetInternal(AbsoluteOffset);
    if (CSV == nullptr) {
      Processed++;
      continue;
    }

    intptr_t CSVOffset = AbsoluteOffset - Remaining;
    if (!SyncedOffsets.insert(CSVOffset).second) {
      Processed++;
      continue;
    }

    Type *CSVType = CSV->getValueType();
    if (!CSVType->isIntegerTy()) {
      Processed++;
      continue;
    }

    uint64_t FieldSize = ModuleLayout->getTypeAllocSize(CSVType);
    if (FieldSize == 0) {
      Processed++;
      continue;
    }

    Value *BackingSlot =
      createEnvBackingOffsetPointer(Builder,
                                    EnvValue,
                                    CSVType,
                                    CSVOffset
                                      - static_cast<intptr_t>(EnvOffset));
    if (BackingSlot == nullptr)
      return false;

    if (FlushToEnv) {
      Value *CSVValue = createLoad(Builder, CSVType, CSV);
      Builder.CreateStore(CSVValue, BackingSlot);
    } else {
      Value *BackingValue = createLoad(Builder, CSVType, BackingSlot);
      Builder.CreateStore(BackingValue, CSV);
    }

    uint64_t Step = FieldSize > Remaining ? FieldSize - Remaining : 1;
    Processed += std::max<uint64_t>(Step, 1);
  }

  static bool Reported = false;
  if (!SyncedOffsets.empty() && !Reported) {
    errs() << "runnable-lift: syncing bounded QEMU v2 CPUState CSVs at"
           << " helper env backing boundary\n";
    Reported = true;
  }

  return true;
}

void VariableManager::aliasAnalysis() {
  unsigned AliasScopeMDKindID = TheModule.getMDKindID("alias.scope");
  unsigned NoAliasMDKindID = TheModule.getMDKindID("noalias");

  LLVMContext &Context = TheModule.getContext();
  MDBuilder MDB(Context);
  MDNode *CSVDomain = MDB.createAliasScopeDomain("CSVAliasDomain");

  struct CSVAliasInfo {
    MDNode *AliasScope;
    MDNode *AliasSet;
    MDNode *NoAliasSet;
  };
  std::map<const GlobalVariable *, CSVAliasInfo> CSVAliasInfoMap;

  // Build alias scopes
  std::vector<Metadata *> AllCSVScopes;
  for (auto &P : CPUStateGlobals) {
    const GlobalVariable *GV = P.second;
    CSVAliasInfo &AliasInfo = CSVAliasInfoMap[GV];

    std::string Name = GV->getName().str();
    MDNode *CSVScope = MDB.createAliasScope(Name, CSVDomain);
    AliasInfo.AliasScope = CSVScope;
    AllCSVScopes.push_back(CSVScope);
    MDNode *CSVAliasSet = MDNode::get(Context,
                                      ArrayRef<Metadata *>({ CSVScope }));
    AliasInfo.AliasSet = CSVAliasSet;
  }
  MDNode *MemoryAliasSet = MDNode::get(Context, AllCSVScopes);

  // Build noalias sets
  for (auto &P : CPUStateGlobals) {
    const GlobalVariable *GV = P.second;
    CSVAliasInfo &AliasInfo = CSVAliasInfoMap[GV];
    std::vector<Metadata *> OtherCSVScopes;
    for (const auto &Q : CSVAliasInfoMap)
      if (Q.first != GV)
        OtherCSVScopes.push_back(Q.second.AliasScope);

    MDNode *CSVNoAliasSet = MDNode::get(Context, OtherCSVScopes);
    AliasInfo.NoAliasSet = CSVNoAliasSet;
  }

  // Decorate the IR with alias information
  for (Function &F : TheModule) {
    for (BasicBlock &BB : F) {
      for (Instruction &I : BB) {
        Value *Ptr = nullptr;

        if (auto *L = dyn_cast<LoadInst>(&I))
          Ptr = L->getPointerOperand();
        else if (auto *S = dyn_cast<StoreInst>(&I))
          Ptr = S->getPointerOperand();
        else
          continue;

        // Check if the pointer is a CSV
        if (auto *GV = dyn_cast<GlobalVariable>(Ptr)) {
          auto It = CSVAliasInfoMap.find(GV);
          if (It != CSVAliasInfoMap.end()) {
            // Set alias.scope and noalias metadata
            I.setMetadata(AliasScopeMDKindID, It->second.AliasSet);
            I.setMetadata(NoAliasMDKindID, It->second.NoAliasSet);
            continue;
          }
        }

        // It's not a CSV memory access, set noalias info
        I.setMetadata(NoAliasMDKindID, MemoryAliasSet);
      }
    }
  }
}

void VariableManager::finalize() {

  // Decorate memory accesses with information about CSV aliasing
  aliasAnalysis();

  if (not External) {
    for (auto &P : CPUStateGlobals)
      P.second->setLinkage(GlobalValue::InternalLinkage);
    for (auto &P : OtherGlobals)
      P.second->setLinkage(GlobalValue::InternalLinkage);
  }

  LLVMContext &Context = getContext(&TheModule);
  IRBuilder<> Builder(Context);

  // Create the setRegister function
  auto *SetRegisterTy = FunctionType::get(Builder.getVoidTy(),
                                          { Builder.getInt32Ty(),
                                            Builder.getInt64Ty() },
                                          false);
  auto *Temp = runnable_llvm::getOrInsertFunction(TheModule,
                                                  "set_register",
                                                  SetRegisterTy);
  auto *SetRegister = cast<Function>(Temp);
  SetRegister->setLinkage(GlobalValue::ExternalLinkage);

  // Collect arguments
  auto ArgIt = SetRegister->arg_begin();
  auto ArgEnd = SetRegister->arg_end();
  runnable_assert(ArgIt != ArgEnd);
  Argument *RegisterID = &*ArgIt;
  ArgIt++;
  runnable_assert(ArgIt != ArgEnd);
  Argument *NewValue = &*ArgIt;
  ArgIt++;
  runnable_assert(ArgIt == ArgEnd);

  // Create main basic blocks
  using BasicBlock = BasicBlock;
  auto *EntryBB = BasicBlock::Create(Context, "", SetRegister);
  auto *DefaultBB = BasicBlock::Create(Context, "", SetRegister);
  auto *ReturnBB = BasicBlock::Create(Context, "", SetRegister);

  // Populate the default case of the switch
  Builder.SetInsertPoint(DefaultBB);
  Builder.CreateCall(TheModule.getFunction("abort"));
  Builder.CreateUnreachable();

  // Create the switch statement
  Builder.SetInsertPoint(EntryBB);
  auto *Switch = Builder.CreateSwitch(RegisterID,
                                      DefaultBB,
                                      CPUStateGlobals.size());
  for (auto &P : CPUStateGlobals) {
    auto *CSVIntTy = cast<IntegerType>(P.second->getValueType());
    if (CSVIntTy->getBitWidth() <= 64) {
      // Set the value of the CSV
      auto *SetRegisterBB = BasicBlock::Create(Context, "", SetRegister);
      Builder.SetInsertPoint(SetRegisterBB);
      Builder.CreateStore(Builder.CreateTrunc(NewValue, CSVIntTy), P.second);
      Builder.CreateBr(ReturnBB);

      // Add the case to the switch
      Switch->addCase(Builder.getInt32(P.first), SetRegisterBB);
    }
  }

  // Finally, populate the return basic block
  Builder.SetInsertPoint(ReturnBB);
  Builder.CreateRetVoid();
}

// TODO: `newFunction` reflects the tcg terminology but in this context is
//       highly misleading
void VariableManager::newFunction(Instruction *Delimiter,
                                  PTCInstructionList *Instructions) {
  LocalTemporaries.clear();
  newBasicBlock(Delimiter, Instructions);
}

/// Informs the VariableManager that a new basic block has begun, so it can
/// discard basic block-level variables.
///
/// \param Delimiter the new point where to insert allocations for local
///                  variables.
/// \param Instructions the new PTCInstructionList to use from now on.
void VariableManager::newBasicBlock(Instruction *Delimiter,
                                    PTCInstructionList *Instructions) {
  Temporaries.clear();
  if (Instructions != nullptr)
    this->Instructions = Instructions;

  if (Delimiter != nullptr)
    Builder.SetInsertPoint(Delimiter);
}

void VariableManager::newBasicBlock(BasicBlock *Delimiter,
                                    PTCInstructionList *Instructions) {
  Temporaries.clear();
  if (Instructions != nullptr)
    this->Instructions = Instructions;

  if (Delimiter != nullptr)
    Builder.SetInsertPoint(Delimiter);
}

bool VariableManager::isEnv(Value *TheValue) {
  auto *Load = dyn_cast<LoadInst>(TheValue);
  if (Load != nullptr)
    return Load->getPointerOperand() == Env;

  return TheValue == Env;
}

static ConstantInt *fromBytes(IntegerType *Type, void *Data) {
  switch (Type->getBitWidth()) {
  case 8:
    return ConstantInt::get(Type, *(static_cast<uint8_t *>(Data)));
  case 16:
    return ConstantInt::get(Type, *(static_cast<uint16_t *>(Data)));
  case 32:
    return ConstantInt::get(Type, *(static_cast<uint32_t *>(Data)));
  case 64:
    return ConstantInt::get(Type, *(static_cast<uint64_t *>(Data)));
  }

  runnable_unreachable("Unexpected type");
}

static ConstantInt *adjustQEMUV2CPUStateInitialValue(StructType *CPUStateType,
                                                     unsigned EnvOffset,
                                                     intptr_t Offset,
                                                     StringRef Name,
                                                     IntegerType *Type,
                                                     ConstantInt *InitialValue) {
  if (!ptc_compat::isPTCAbiV2()
      || CPUStateType == nullptr
      || (!CPUStateType->getName().contains("CPUX86State")
          && !CPUStateType->getName().contains("X86CPU")))
    return InitialValue;

  auto adjustedValue = [&](uint64_t Value, const char *Field) {
    errs() << "runnable-lift: initializing QEMU v2 x86_64 CPUState "
           << Field
           << " offset=0x" << Twine::utohexstr(Offset);
    if (!Name.empty())
      errs() << " name=" << Name;
    errs() << " value=0x" << Twine::utohexstr(Value) << "\n";
    return ConstantInt::get(Type, Value);
  };

  intptr_t EnvRelativeOffset =
    Offset - static_cast<intptr_t>(EnvOffset);

  // QEMU x86 keeps env->df as the byte step used by string instructions:
  // +1 for forward direction, -1 for backward direction. The live sidecar's
  // captured initial env can leave this derived field zero before any string
  // op reads it, but generated TCG uses env->df directly for movs/stos/loads.
  static constexpr intptr_t X86DFEnvOffset = 0xac;
  if (EnvRelativeOffset == X86DFEnvOffset
      && Type->getBitWidth() == 32
      && InitialValue->isZero())
    return adjustedValue(1, "df");

  // The QEMU v2 sidecar can expose CPUX86State bytes before the x86 reset
  // helpers have canonicalized derived FPU/SSE state. Helpers such as
  // helper_cvtsi2ss read env->sse_status directly, so initialize the materialized
  // CSVs to the same reset state as cpu_set_fpuc(env, 0x37f) and mxcsr=0x1f80.
  static constexpr intptr_t X86FPSTTEnvOffset = 0x230;
  static constexpr intptr_t X86FPUSenvOffset = 0x234;
  static constexpr intptr_t X86FPUCEnvOffset = 0x236;
  static constexpr intptr_t X86FPTagsEnvOffset = 0x238;
  static constexpr intptr_t X86FPStatusEnvOffset = 0x2d8;
  static constexpr intptr_t X86MMXStatusEnvOffset = 0x2f0;
  static constexpr intptr_t X86SSEStatusEnvOffset = 0x2f7;
  static constexpr intptr_t X86MXCSREnvOffset = 0x300;
  static constexpr intptr_t X86XStateBVEnvOffset = 0x1140;
  static constexpr intptr_t X86XCR0EnvOffset = 0x1148;

  if (EnvRelativeOffset == X86FPSTTEnvOffset && Type->getBitWidth() == 32)
    return adjustedValue(0, "fpstt");
  if (EnvRelativeOffset == X86FPUSenvOffset && Type->getBitWidth() == 16)
    return adjustedValue(0, "fpus");
  if (EnvRelativeOffset == X86FPUCEnvOffset && Type->getBitWidth() == 16)
    return adjustedValue(0x37f, "fpuc");
  if (EnvRelativeOffset >= X86FPTagsEnvOffset
      && EnvRelativeOffset < X86FPTagsEnvOffset + 8
      && Type->getBitWidth() == 8)
    return adjustedValue(1, "fptags");

  auto adjustFloatStatusByte = [&](intptr_t BaseOffset,
                                   const char *Field,
                                   bool IsX87FPStatus)
    -> ConstantInt * {
    if (EnvRelativeOffset < BaseOffset || EnvRelativeOffset >= BaseOffset + 7
        || Type->getBitWidth() != 8)
      return nullptr;

    uint64_t Value = 0;
    intptr_t FieldOffset = EnvRelativeOffset - BaseOffset;
    if (FieldOffset == 3 && IsX87FPStatus)
      Value = 80;

    return adjustedValue(Value, Field);
  };

  if (auto *Adjusted =
        adjustFloatStatusByte(X86FPStatusEnvOffset, "fp_status",
                              true))
    return Adjusted;
  if (auto *Adjusted =
        adjustFloatStatusByte(X86MMXStatusEnvOffset, "mmx_status",
                              false))
    return Adjusted;
  if (auto *Adjusted =
        adjustFloatStatusByte(X86SSEStatusEnvOffset, "sse_status",
                              false))
    return Adjusted;

  if (EnvRelativeOffset == X86MXCSREnvOffset && Type->getBitWidth() == 32)
    return adjustedValue(0x1f80, "mxcsr");
  if (EnvRelativeOffset == X86XStateBVEnvOffset && Type->getBitWidth() == 64)
    return adjustedValue(0x3, "xstate_bv");
  if (EnvRelativeOffset == X86XCR0EnvOffset && Type->getBitWidth() == 64)
    return adjustedValue(0x1, "xcr0");

  return InitialValue;
}

static GlobalVariable *materializeGlobalDeclaration(Module &M,
                                                    StringRef Name,
                                                    Type *ExpectedType,
                                                    Constant *Initializer) {
  if (Name.empty())
    return nullptr;

  GlobalVariable *GV = M.getNamedGlobal(Name);
  if (GV == nullptr || !GV->isDeclaration())
    return nullptr;

  runnable_assert(GV->getValueType() == ExpectedType);
  GV->setConstant(false);
  GV->setInitializer(Initializer);
  return GV;
}

// TODO: document that it can return nullptr
GlobalVariable *
VariableManager::getByCPUStateOffset(intptr_t Offset, std::string Name) {
  GlobalVariable *Result = nullptr;
  unsigned Remaining;
  std::tie(Result, Remaining) = getByCPUStateOffsetInternal(Offset, Name);
  runnable_assert(Remaining == 0);
  return Result;
}

std::pair<GlobalVariable *, unsigned>
VariableManager::getByCPUStateOffsetInternal(intptr_t Offset,
                                             std::string Name) {
  GlobalsMap::iterator it = CPUStateGlobals.find(Offset);
  static const char *UnknownCSVPref = "state_0x";
  if (it == CPUStateGlobals.end()
      || (Name.size() != 0
          && startsWith(it->second->getName().str(), UnknownCSVPref))) {
    Type *VariableType;
    unsigned Remaining;
    std::tie(VariableType,
             Remaining) = getTypeAtOffset(ModuleLayout, CPUStateType, Offset);

    // Unsupported type, let the caller handle the situation
    if (VariableType == nullptr)
      return { nullptr, 0 };

    // Check we're not trying to go inside an existing variable
    if (Remaining != 0) {
      GlobalsMap::iterator it = CPUStateGlobals.find(Offset - Remaining);
      if (it != CPUStateGlobals.end())
        return { it->second, Remaining };
    }

    if (Name.size() == 0) {
      std::stringstream NameStream;
      NameStream << UnknownCSVPref << std::hex << Offset;
      Name = NameStream.str();
    }

    // TODO: offset could be negative, we could segfault here
    auto *InitialData = ptc.initialized_env - EnvOffset + Offset;
    runnable_log(VMStateLog,
                 "offset=" << Offset
                           << " remaining=" << Remaining
                           << " name=" << Name
                           << " initial_data="
                           << static_cast<const void *>(InitialData)
                           << DoLog);
    auto *VariableIntType = cast<IntegerType>(VariableType);
    auto *InitialValue = fromBytes(VariableIntType, InitialData);
    InitialValue = adjustQEMUV2CPUStateInitialValue(CPUStateType,
                                                   EnvOffset,
                                                   Offset,
                                                   Name,
                                                   VariableIntType,
                                                   InitialValue);

    auto *NewVariable = materializeGlobalDeclaration(TheModule,
                                                     Name,
                                                     VariableType,
                                                     InitialValue);
    if (NewVariable == nullptr)
      NewVariable = new GlobalVariable(TheModule,
                                       VariableType,
                                       false,
                                       GlobalValue::ExternalLinkage,
                                       InitialValue,
                                       Name);
    runnable_assert(NewVariable != nullptr);

    if (it != CPUStateGlobals.end()) {
      it->second->replaceAllUsesWith(NewVariable);
      it->second->eraseFromParent();
    }

    CPUStateGlobals[Offset] = NewVariable;

    return { NewVariable, Remaining };
  } else {
    return { it->second, 0 };
  }
}

Value *VariableManager::getOrCreate(unsigned TemporaryId, bool Reading) {
  runnable_assert(Instructions != nullptr);

  if (Instructions->temps == nullptr
      || TemporaryId >= Instructions->total_temps) {
    reportInvalidPTCTemp(Instructions, TemporaryId);
    return nullptr;
  }

  PTCTemp *Temporary = ptc_temp_get(Instructions, TemporaryId);
  Type *VariableType = typeForPTCTemp(Builder, TemporaryId, *Temporary);
  if (VariableType == nullptr)
    return nullptr;

  StringRef TemporaryName(Temporary->name != nullptr ? Temporary->name : "");

  if (ptc_temp_is_global(Instructions, TemporaryId)) {
    if (ptc_compat::isPTCAbiV2()
        && Temporary->fixed_reg != 0
        && TemporaryName == "env") {
      return getOrCreateEnvPointerGlobal();
    }

    // Basically we use fixed_reg to detect "env"
    if (Temporary->fixed_reg == 0) {
      Value *Result = getByCPUStateOffset(EnvOffset + Temporary->mem_offset,
                                          TemporaryName.str());
      runnable_assert(Result != nullptr);
      return Result;
    } else {
      GlobalsMap::iterator it = OtherGlobals.find(TemporaryId);
      if (it != OtherGlobals.end()) {
        return it->second;
      } else {
        // TODO: what do we have here, apart from env?
        auto InitialValue = ConstantInt::get(VariableType, 0);
        GlobalVariable *Result = new GlobalVariable(TheModule,
                                                    VariableType,
                                                    false,
                                                    GlobalValue::CommonLinkage,
                                                    InitialValue,
                                                    TemporaryName);

        if (Result->getName() == "env")
          Env = Result;

        OtherGlobals[TemporaryId] = Result;
        return Result;
      }
    }
  } else if (Temporary->temp_local || isQEMUV2TBScopedTemp(*Temporary)) {
    auto it = LocalTemporaries.find(TemporaryId);
    if (it != LocalTemporaries.end()) {
      return it->second;
    } else {
      AllocaInst *NewTemporary = Builder.CreateAlloca(VariableType);
      LocalTemporaries[TemporaryId] = NewTemporary;
      if (Reading && shouldSeedAllocatedTemp(*Temporary)) {
        auto *InitialValue = ConstantInt::get(cast<IntegerType>(VariableType),
                                              Temporary->val);
        Builder.CreateStore(InitialValue, NewTemporary);
        runnable_log(VMStateLog,
                     "materialized v2 sidecar TB-scoped temp"
                       << " temp_id=" << TemporaryId
                       << " value=" << Temporary->val
                       << DoLog);
      }
      return NewTemporary;
    }
  } else {
    auto it = Temporaries.find(TemporaryId);
    if (it != Temporaries.end()) {
      return it->second;
    } else {
      // Can't read a temporary if it has never been written, we're probably
      // translating rubbish
      if (Reading) {
        if (!shouldSeedAllocatedTemp(*Temporary))
          return nullptr;

        auto *NewTemporary = Builder.CreateAlloca(VariableType);
        auto *InitialValue = ConstantInt::get(cast<IntegerType>(VariableType),
                                              Temporary->val);
        Builder.CreateStore(InitialValue, NewTemporary);
        Temporaries[TemporaryId] = NewTemporary;
        runnable_log(VMStateLog,
                     "materialized v2 sidecar temp"
                       << " temp_id=" << TemporaryId
                       << " value=" << Temporary->val
                       << DoLog);
        return NewTemporary;
      }

      AllocaInst *NewTemporary = Builder.CreateAlloca(VariableType);
      Temporaries[TemporaryId] = NewTemporary;
      return NewTemporary;
    }
  }
}

Value *VariableManager::computeEnvAddress(Type *TargetType,
                                          Instruction *InsertBefore,
                                          unsigned Offset) {
  Type *EnvType = getPointerValueType(Env);
  auto *LoadEnv = createLoad(EnvType, Env, "", InsertBefore);
  Value *Integer = LoadEnv;
  if (Offset != 0)
    Integer = BinaryOperator::Create(Instruction::Add,
                                     LoadEnv,
                                     ConstantInt::get(EnvType, Offset),
                                     "",
                                     InsertBefore);
  return new IntToPtrInst(Integer, TargetType, "", InsertBefore);
}
