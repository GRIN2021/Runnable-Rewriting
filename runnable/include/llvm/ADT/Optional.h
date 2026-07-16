#ifndef RUNNABLE_LLVM_ADT_OPTIONAL_COMPAT_H
#define RUNNABLE_LLVM_ADT_OPTIONAL_COMPAT_H

#if defined(__has_include_next)
#if __has_include_next("llvm/ADT/Optional.h")
#include_next "llvm/ADT/Optional.h"
#else
#include <optional>
#include <utility>

namespace llvm {
static constexpr std::nullopt_t None = std::nullopt;

template<typename T>
class Optional : public std::optional<T> {
  using Base = std::optional<T>;

public:
  using Base::Base;

  Optional() = default;
  Optional(const Base &Other) : Base(Other) {}
  Optional(Base &&Other) : Base(std::move(Other)) {}

  bool hasValue() const { return this->has_value(); }

  T *getPointer() { return this->has_value() ? &this->value() : nullptr; }
  const T *getPointer() const {
    return this->has_value() ? &this->value() : nullptr;
  }

  T &getValue() & { return this->value(); }
  const T &getValue() const & { return this->value(); }
  T &&getValue() && { return std::move(this->value()); }
};
} // namespace llvm
#endif
#else
#include_next "llvm/ADT/Optional.h"
#endif

#endif // RUNNABLE_LLVM_ADT_OPTIONAL_COMPAT_H
