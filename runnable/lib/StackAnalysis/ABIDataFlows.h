#ifndef ABIDATAFLOWS_H
#define ABIDATAFLOWS_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// This file has been automatically generated, please don't change it

// Standard includes
#include <cstdlib>
#include <ostream>

// Local libraries includes
#include "runnable/Support/Assert.h"
#include "runnable/Support/Debug.h"
enum class GeneralTransferFunction {
  Read,
  ReturnFromBottom,
  ReturnFromMaybe,
  ReturnFromNoOrDead,
  ReturnFromUnknown,
  ReturnFromYes,
  TheCall,
  UnknownFunctionCall,
  Write,
  InvalidTransferFunction
};

class DeadRegisterArgumentsOfFunction {
public:
  enum Values {
    Maybe,
    NoOrDead,
    Unknown
  };

  enum TransferFunction {
    Read,
    ReturnFromMaybe,
    ReturnFromNoOrDead,
    ReturnFromUnknown,
    UnknownFunctionCall,
    Write
  };

public:
  DeadRegisterArgumentsOfFunction() :
    Value(NoOrDead) { }

  DeadRegisterArgumentsOfFunction(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const DeadRegisterArgumentsOfFunction &Other) {
    if ((Value == Maybe && Other.Value == NoOrDead)
        || (Value == NoOrDead && Other.Value == Maybe)) {
      Value = Maybe;
    } else if ((Value == Maybe && Other.Value == Unknown)
               || (Value == NoOrDead && Other.Value == Unknown)
               || (Value == Unknown && Other.Value == Maybe)
               || (Value == Unknown && Other.Value == NoOrDead)) {
      Value = Unknown;
    }
  }

  bool greaterThan(const DeadRegisterArgumentsOfFunction &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const DeadRegisterArgumentsOfFunction &Other) const {
    return Value == Other.Value
      || (Value == Maybe && Other.Value == Unknown)
      || (Value == NoOrDead && Other.Value == Maybe)
      || (Value == NoOrDead && Other.Value == Unknown);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromNoOrDead:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromNoOrDead:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Maybe:
      return ReturnFromMaybe;
    case NoOrDead:
      return ReturnFromNoOrDead;
    case Unknown:
      return ReturnFromUnknown;
    }

    runnable_abort();
  }

  static const char *name() {
    return "DeadRegisterArgumentsOfFunction";
  }

  static DeadRegisterArgumentsOfFunction top() {
    return DeadRegisterArgumentsOfFunction(Unknown);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Maybe:
      Output << "Maybe";
      break;
    case NoOrDead:
      Output << "NoOrDead";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    }
  }

private:
  Values Value;
};

class DeadReturnValuesOfFunctionCall {
public:
  enum Values {
    Maybe,
    NoOrDead,
    Unknown
  };

  enum TransferFunction {
    Read,
    ReturnFromMaybe,
    ReturnFromNoOrDead,
    ReturnFromUnknown,
    TheCall,
    UnknownFunctionCall,
    Write
  };

public:
  DeadReturnValuesOfFunctionCall() :
    Value(NoOrDead) { }

  DeadReturnValuesOfFunctionCall(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const DeadReturnValuesOfFunctionCall &Other) {
    if ((Value == Maybe && Other.Value == NoOrDead)
        || (Value == NoOrDead && Other.Value == Maybe)) {
      Value = Maybe;
    } else if ((Value == Maybe && Other.Value == Unknown)
               || (Value == NoOrDead && Other.Value == Unknown)
               || (Value == Unknown && Other.Value == Maybe)
               || (Value == Unknown && Other.Value == NoOrDead)) {
      Value = Unknown;
    }
  }

  bool greaterThan(const DeadReturnValuesOfFunctionCall &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const DeadReturnValuesOfFunctionCall &Other) const {
    return Value == Other.Value
      || (Value == Maybe && Other.Value == Unknown)
      || (Value == NoOrDead && Other.Value == Maybe)
      || (Value == NoOrDead && Other.Value == Unknown);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromNoOrDead:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromNoOrDead:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = NoOrDead;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case NoOrDead:
        Value = NoOrDead;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Maybe:
      return ReturnFromMaybe;
    case NoOrDead:
      return ReturnFromNoOrDead;
    case Unknown:
      return ReturnFromUnknown;
    }

    runnable_abort();
  }

  static const char *name() {
    return "DeadReturnValuesOfFunctionCall";
  }

  static DeadReturnValuesOfFunctionCall top() {
    return DeadReturnValuesOfFunctionCall(Unknown);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Maybe:
      Output << "Maybe";
      break;
    case NoOrDead:
      Output << "NoOrDead";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    }
  }

private:
  Values Value;
};

class RegisterArgumentsOfFunctionCall {
public:
  enum Values {
    Bottom,
    Maybe,
    Unknown,
    Yes
  };

  enum TransferFunction {
    Read,
    ReturnFromBottom,
    ReturnFromMaybe,
    ReturnFromUnknown,
    ReturnFromYes,
    TheCall,
    UnknownFunctionCall,
    Write
  };

public:
  RegisterArgumentsOfFunctionCall() :
    Value(Bottom) { }

  RegisterArgumentsOfFunctionCall(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const RegisterArgumentsOfFunctionCall &Other) {
    if ((Value == Bottom && Other.Value == Maybe)
        || (Value == Maybe && Other.Value == Bottom)) {
      Value = Maybe;
    } else if ((Value == Bottom && Other.Value == Unknown)
               || (Value == Maybe && Other.Value == Unknown)
               || (Value == Maybe && Other.Value == Yes)
               || (Value == Unknown && Other.Value == Bottom)
               || (Value == Unknown && Other.Value == Maybe)
               || (Value == Unknown && Other.Value == Yes)
               || (Value == Yes && Other.Value == Maybe)
               || (Value == Yes && Other.Value == Unknown)) {
      Value = Unknown;
    } else if ((Value == Bottom && Other.Value == Yes)
               || (Value == Yes && Other.Value == Bottom)) {
      Value = Yes;
    }
  }

  bool greaterThan(const RegisterArgumentsOfFunctionCall &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const RegisterArgumentsOfFunctionCall &Other) const {
    return Value == Other.Value
      || (Value == Bottom && Other.Value == Maybe)
      || (Value == Bottom && Other.Value == Unknown)
      || (Value == Bottom && Other.Value == Yes)
      || (Value == Maybe && Other.Value == Unknown)
      || (Value == Yes && Other.Value == Unknown);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromBottom:
      switch(Value) {
      case Bottom:
        Value = Bottom;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      case Maybe:
        Value = Maybe;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromBottom:
      switch(Value) {
      case Bottom:
        Value = Bottom;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      case Maybe:
        Value = Maybe;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Bottom:
      return ReturnFromBottom;
    case Maybe:
      return ReturnFromMaybe;
    case Unknown:
      return ReturnFromUnknown;
    case Yes:
      return ReturnFromYes;
    }

    runnable_abort();
  }

  static const char *name() {
    return "RegisterArgumentsOfFunctionCall";
  }

  static RegisterArgumentsOfFunctionCall top() {
    return RegisterArgumentsOfFunctionCall(Unknown);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Bottom:
      Output << "Bottom";
      break;
    case Maybe:
      Output << "Maybe";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    case Yes:
      Output << "Yes";
      break;
    }
  }

private:
  Values Value;
};

class UsedArgumentsOfFunction {
public:
  enum Values {
    Maybe,
    Unknown,
    Yes
  };

  enum TransferFunction {
    Read,
    ReturnFromMaybe,
    ReturnFromUnknown,
    ReturnFromYes,
    UnknownFunctionCall,
    Write
  };

public:
  UsedArgumentsOfFunction() :
    Value(Unknown) { }

  UsedArgumentsOfFunction(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const UsedArgumentsOfFunction &Other) {
    if ((Value == Maybe && Other.Value == Unknown)
        || (Value == Unknown && Other.Value == Maybe)) {
      Value = Maybe;
    } else if ((Value == Maybe && Other.Value == Yes)
               || (Value == Unknown && Other.Value == Yes)
               || (Value == Yes && Other.Value == Maybe)
               || (Value == Yes && Other.Value == Unknown)) {
      Value = Yes;
    }
  }

  bool greaterThan(const UsedArgumentsOfFunction &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const UsedArgumentsOfFunction &Other) const {
    return Value == Other.Value
      || (Value == Maybe && Other.Value == Yes)
      || (Value == Unknown && Other.Value == Maybe)
      || (Value == Unknown && Other.Value == Yes);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Maybe:
      return ReturnFromMaybe;
    case Unknown:
      return ReturnFromUnknown;
    case Yes:
      return ReturnFromYes;
    }

    runnable_abort();
  }

  static const char *name() {
    return "UsedArgumentsOfFunction";
  }

  static UsedArgumentsOfFunction top() {
    return UsedArgumentsOfFunction(Yes);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Maybe:
      Output << "Maybe";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    case Yes:
      Output << "Yes";
      break;
    }
  }

private:
  Values Value;
};

class UsedReturnValuesOfFunctionCall {
public:
  enum Values {
    Maybe,
    Unknown,
    Yes
  };

  enum TransferFunction {
    Read,
    ReturnFromMaybe,
    ReturnFromUnknown,
    ReturnFromYes,
    TheCall,
    UnknownFunctionCall,
    Write
  };

public:
  UsedReturnValuesOfFunctionCall() :
    Value(Unknown) { }

  UsedReturnValuesOfFunctionCall(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const UsedReturnValuesOfFunctionCall &Other) {
    if ((Value == Maybe && Other.Value == Unknown)
        || (Value == Unknown && Other.Value == Maybe)) {
      Value = Maybe;
    } else if ((Value == Maybe && Other.Value == Yes)
               || (Value == Unknown && Other.Value == Yes)
               || (Value == Yes && Other.Value == Maybe)
               || (Value == Yes && Other.Value == Unknown)) {
      Value = Yes;
    }
  }

  bool greaterThan(const UsedReturnValuesOfFunctionCall &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const UsedReturnValuesOfFunctionCall &Other) const {
    return Value == Other.Value
      || (Value == Maybe && Other.Value == Yes)
      || (Value == Unknown && Other.Value == Maybe)
      || (Value == Unknown && Other.Value == Yes);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::TheCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Maybe:
      return ReturnFromMaybe;
    case Unknown:
      return ReturnFromUnknown;
    case Yes:
      return ReturnFromYes;
    }

    runnable_abort();
  }

  static const char *name() {
    return "UsedReturnValuesOfFunctionCall";
  }

  static UsedReturnValuesOfFunctionCall top() {
    return UsedReturnValuesOfFunctionCall(Yes);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Maybe:
      Output << "Maybe";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    case Yes:
      Output << "Yes";
      break;
    }
  }

private:
  Values Value;
};

class UsedReturnValuesOfFunction {
public:
  enum Values {
    Bottom,
    Maybe,
    Unknown,
    Yes
  };

  enum TransferFunction {
    Read,
    ReturnFromBottom,
    ReturnFromMaybe,
    ReturnFromUnknown,
    ReturnFromYes,
    UnknownFunctionCall,
    Write
  };

public:
  UsedReturnValuesOfFunction() :
    Value(Bottom) { }

  UsedReturnValuesOfFunction(Values V) :
    Value(V) { }

  static Values initial() {
    return Maybe;
  }

  void combine(const UsedReturnValuesOfFunction &Other) {
    if ((Value == Bottom && Other.Value == Maybe)
        || (Value == Maybe && Other.Value == Bottom)) {
      Value = Maybe;
    } else if ((Value == Bottom && Other.Value == Unknown)
               || (Value == Maybe && Other.Value == Unknown)
               || (Value == Maybe && Other.Value == Yes)
               || (Value == Unknown && Other.Value == Bottom)
               || (Value == Unknown && Other.Value == Maybe)
               || (Value == Unknown && Other.Value == Yes)
               || (Value == Yes && Other.Value == Maybe)
               || (Value == Yes && Other.Value == Unknown)) {
      Value = Unknown;
    } else if ((Value == Bottom && Other.Value == Yes)
               || (Value == Yes && Other.Value == Bottom)) {
      Value = Yes;
    }
  }

  bool greaterThan(const UsedReturnValuesOfFunction &Other) const {
    return !lowerThanOrEqual(Other);
  }

  bool lowerThanOrEqual(const UsedReturnValuesOfFunction &Other) const {
    return Value == Other.Value
      || (Value == Bottom && Other.Value == Maybe)
      || (Value == Bottom && Other.Value == Unknown)
      || (Value == Bottom && Other.Value == Yes)
      || (Value == Maybe && Other.Value == Unknown)
      || (Value == Yes && Other.Value == Unknown);
  }

  void transfer(TransferFunction T) {
    switch(T) {
    case Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromBottom:
      switch(Value) {
      case Bottom:
        Value = Bottom;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      case Maybe:
        Value = Maybe;
        break;
      default:
        break;
      }
      break;

    case ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case Write:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    }
  }

  void transfer(GeneralTransferFunction T) {
    switch(T) {
    case GeneralTransferFunction::Read:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromBottom:
      switch(Value) {
      case Bottom:
        Value = Bottom;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Yes:
        Value = Yes;
        break;
      case Maybe:
        Value = Maybe;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromMaybe:
      switch(Value) {
      case Maybe:
        Value = Maybe;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromUnknown:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::ReturnFromYes:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::UnknownFunctionCall:
      switch(Value) {
      case Maybe:
        Value = Unknown;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    case GeneralTransferFunction::Write:
      switch(Value) {
      case Maybe:
        Value = Yes;
        break;
      case Unknown:
        Value = Unknown;
        break;
      case Bottom:
        Value = Bottom;
        break;
      case Yes:
        Value = Yes;
        break;
      default:
        break;
      }
      break;

    default:
      runnable_abort();
    }

  }

  TransferFunction returnTransferFunction() const {
    switch(Value) {
    case Bottom:
      return ReturnFromBottom;
    case Maybe:
      return ReturnFromMaybe;
    case Unknown:
      return ReturnFromUnknown;
    case Yes:
      return ReturnFromYes;
    }

    runnable_abort();
  }

  static const char *name() {
    return "UsedReturnValuesOfFunction";
  }

  static UsedReturnValuesOfFunction top() {
    return UsedReturnValuesOfFunction(Unknown);
  }

  Values value() const { return Value; }

  void dump() const { dump(dbg); }

  template<typename T>
  void dump(T &Output) const {
    switch(Value) {
    case Bottom:
      Output << "Bottom";
      break;
    case Maybe:
      Output << "Maybe";
      break;
    case Unknown:
      Output << "Unknown";
      break;
    case Yes:
      Output << "Yes";
      break;
    }
  }

private:
  Values Value;
};


#endif // ABIDATAFLOWS_H
