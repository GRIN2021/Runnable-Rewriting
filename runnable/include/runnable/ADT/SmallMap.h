#ifndef SMALLMAP_H
#define SMALLMAP_H

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Standard includes
#include <array>
#include <map>

#if defined(__has_include)
#if __has_include(<boost/variant.hpp>)
#define RUNNABLE_HAS_BOOST_VARIANT 1
#endif
#else
#define RUNNABLE_HAS_BOOST_VARIANT 1
#endif

#if RUNNABLE_HAS_BOOST_VARIANT
#include <boost/variant.hpp>
#else
#include <variant>
#endif

// Local libraries includes
#include "runnable/Support/Assert.h"

// TODO: test SmallMap

namespace smallmap_detail {

#if RUNNABLE_HAS_BOOST_VARIANT
template<typename R>
using StaticVisitor = boost::static_visitor<R>;

template<typename... Ts>
using Variant = boost::variant<Ts...>;

template<typename Visitor, typename VariantT>
auto applyVisitor(Visitor &&V, VariantT &&Variant)
  -> decltype(boost::apply_visitor(std::forward<Visitor>(V),
                                   std::forward<VariantT>(Variant))) {
  return boost::apply_visitor(std::forward<Visitor>(V),
                              std::forward<VariantT>(Variant));
}

template<typename Visitor, typename VariantT, typename OtherVariantT>
auto applyVisitor(Visitor &&V, VariantT &&Variant, OtherVariantT &&Other)
  -> decltype(boost::apply_visitor(std::forward<Visitor>(V),
                                   std::forward<VariantT>(Variant),
                                   std::forward<OtherVariantT>(Other))) {
  return boost::apply_visitor(std::forward<Visitor>(V),
                              std::forward<VariantT>(Variant),
                              std::forward<OtherVariantT>(Other));
}
#else
template<typename R>
struct StaticVisitor {};

template<typename... Ts>
using Variant = std::variant<Ts...>;

template<typename Visitor, typename VariantT>
decltype(auto) applyVisitor(Visitor &&V, VariantT &&Variant) {
  return std::visit(std::forward<Visitor>(V), std::forward<VariantT>(Variant));
}

template<typename Visitor, typename VariantT, typename OtherVariantT>
decltype(auto) applyVisitor(Visitor &&V, VariantT &&Variant,
                            OtherVariantT &&Other) {
  return std::visit(std::forward<Visitor>(V),
                    std::forward<VariantT>(Variant),
                    std::forward<OtherVariantT>(Other));
}
#endif

} // namespace smallmap_detail

/// \brief Type-safe wrapper for different iterators sharing value_type
template<typename... Ts>
class Iteratall {
private:
  template<typename T>
  using it = std::iterator_traits<T>;

  // Define some helpers
  template<typename... Ps>
  struct are_same : std::false_type {};

  template<typename P, typename... Ps>
  struct are_same<P, P, Ps...> : are_same<P, Ps...> {};

  template<typename P>
  struct are_same<P, P> : std::true_type {};

  template<typename P, typename... Ps>
  struct first {
    using type = P;
  };

  // Assert correct usage
  static_assert(are_same<typename it<Ts>::value_type...>::value,
                "The iterators have different value_type");
  static_assert(are_same<typename it<Ts>::reference...>::value,
                "The iterators have different reference");

  using value_type = typename it<typename first<Ts...>::type>::value_type;
  using reference = typename it<typename first<Ts...>::type>::reference;
  using pointer = typename it<typename first<Ts...>::type>::pointer;

public:
  template<typename T>
  Iteratall(T I) : Iterator(I) {}

private:
  struct PostincrementVisitor
    : public smallmap_detail::StaticVisitor<Iteratall> {
    template<typename T>
    Iteratall operator()(T &It) const {
      return Iteratall(It++);
    }
  };

  struct PreincrementVisitor
    : public smallmap_detail::StaticVisitor<Iteratall> {
    template<typename T>
    Iteratall operator()(T &It) const {
      return Iteratall(++It);
    }
  };

  struct DereferenceVisitor : public smallmap_detail::StaticVisitor<reference> {
    template<typename T>
    reference operator()(const T &It) const {
      return *It;
    }
  };

  struct CompareVisitor : public smallmap_detail::StaticVisitor<bool> {
    template<typename T, typename R>
    bool operator()(const T &, const R &) const {
      // The compared type should always be the same
      runnable_abort();
    }

    template<typename T>
    bool operator()(const T &It, const T &Other) const {
      return It == Other;
    }
  };

public:
  Iteratall operator++(int) {
    return smallmap_detail::applyVisitor(PostincrementVisitor(), Iterator);
  }

  Iteratall operator++() {
    return smallmap_detail::applyVisitor(PreincrementVisitor(), Iterator);
  }

  bool operator==(const Iteratall &Other) const {
    return smallmap_detail::applyVisitor(CompareVisitor(),
                                         Iterator,
                                         Other.Iterator);
  }

  bool operator!=(const Iteratall &Other) const { return !(*this == Other); }

  reference operator*() const {
    return smallmap_detail::applyVisitor(DereferenceVisitor(), Iterator);
  }

  pointer operator->() const { return &**this; }

private:
  smallmap_detail::Variant<Ts...> Iterator;
};

/// \brief map that usually contains less than N elements
///
/// SmallMap keeps a std::array of pairs inline which are search linearly if
/// size() < N.
///
/// \note Since this data structure internally uses an std::array, expect the
///       default constructor to be used.
///
/// \tparam N number of elements to keep inline.
template<typename K, typename V, unsigned N, typename C = std::less<K>>
class SmallMap {
private:
  // Define some helper types
  using NonConstPair = std::pair<K, V>;
  using NonConstContainer = std::array<NonConstPair, N>;

  using Pair = std::pair<const K, V>;
  using Container = std::array<Pair, N>;

  using VIterator = typename Container::iterator;
  using ConstVIterator = typename Container::const_iterator;

private:
  // These have to be mutable so we can sort() can be a const method.
  // Note that Vector is an array of pairs where the key is *not* const. We use
  // the pair with the const key only to provide iterators compatible with
  // std::map.
  mutable NonConstContainer Vector; ///< Container for inline elements
  mutable bool IsSorted; ///< Is vector sorted?
  unsigned Size; ///< Size of Vector

  // Non-inline version of the container
  std::map<K, V, C> Map;

private:
  VIterator smallBegin() { return reinterpret_cast<VIterator>(Vector.begin()); }

  ConstVIterator smallBegin() const {
    return reinterpret_cast<ConstVIterator>(Vector.begin());
  }

public:
  SmallMap() : IsSorted(true), Size(0) {}

  SmallMap(const SmallMap &) = default;
  SmallMap &operator=(const SmallMap &Other) = default;
  SmallMap(SmallMap &&Other) = default;
  SmallMap &operator=(SmallMap &&Other) = default;

public:
  using iterator = Iteratall<VIterator, typename std::map<K, V, C>::iterator>;
  using const_iterator = Iteratall<ConstVIterator,
                                   typename std::map<K, V, C>::const_iterator>;
  using size_type = size_t;

public:
  /// \brief If necessary, sorts the inline vector.
  ///
  /// Call this function in case you need to iterate over the container in order
  void sort() const {
    if (IsSorted || !isSmall() || Size <= 1)
      return;

    auto Compare = [](const Pair &A, const Pair &B) {
      return std::less<K>()(A.first, B.first);
    };
    std::sort(Vector.begin(), Vector.begin() + Size, Compare);
    IsSorted = true;
  }

  bool empty() const { return Size == 0 && Map.empty(); }

  size_type size() const { return isSmall() ? Size : Map.size(); }

  const_iterator begin() const {
    if (isSmall())
      return const_iterator(smallBegin());
    else
      return const_iterator(Map.begin());
  }

  const_iterator end() const {
    if (isSmall())
      return const_iterator(smallBegin() + Size);
    else
      return const_iterator(Map.end());
  }

  iterator begin() {
    if (isSmall())
      return iterator(smallBegin());
    else
      return iterator(Map.begin());
  }

  iterator end() {
    if (isSmall())
      return iterator(smallBegin() + Size);
    else
      return iterator(Map.end());
  }

  size_type count(const K &Key) const {
    if (isSmall()) {
      return vfind(Key) == smallBegin() + Size ? 0 : 1;
    } else {
      return Map.count(Key);
    }
  }

  std::pair<iterator, bool> insert(const Pair &P) {
    if (!isSmall()) {
      auto Result = Map.insert(P);
      return { iterator(Result.first), Result.second };
    }

    VIterator I = vfind(P.first);
    // Do we have it?
    if (I != smallBegin() + Size)
      return { iterator(I), false };

    if (Size < N) {
      Vector[Size] = P;
      Size++;

      // Check if we're preserving the ordering
      if (Size > 1 && IsSorted)
        IsSorted = !std::less<K>()(P.first, Vector[Size - 2].first);

      return { iterator(smallBegin() + Size - 1), true };
    }

    // Otherwise, grow from vector to set.
    runnable_assert(Map.empty());
    for (unsigned I = 0; I < Size; I++)
      Map.insert(Vector[I]);

    auto Result = Map.insert(P);
    return { iterator(Result.first), Result.second };
  }

  void erase(const K &Key) {
    if (isSmall()) {
      auto I = Vector.begin();
      auto E = Vector.begin() + Size;

      for (; I != E; ++I)
        if (I->first == Key)
          break;

      if (I == E)
        return;

      Size--;
      for (; I < E - 1; I++)
        *I = *(I + 1);

    } else {
      auto It = Map.find(Key);
      if (It != Map.end())
        Map.erase(It);
    }
  }

  iterator find(const K &Key) {
    if (isSmall())
      return iterator(vfind(Key));
    else
      return iterator(Map.find(Key));
  }

  const_iterator find(const K &Key) const {
    if (isSmall())
      return const_iterator(vfind(Key));
    else
      return const_iterator(Map.find(Key));
  }

  void clear() {
    // TODO: we should invoke some destructors at a certain point
    Size = 0;
    Map.clear();
  }

private:
  bool isSmall() const { return Map.empty(); }

  ConstVIterator vfind(const K &Key) const {
    for (ConstVIterator I = smallBegin(), E = smallBegin() + Size; I != E; ++I)
      if (I->first == Key)
        return I;
    return smallBegin() + Size;
  }

  VIterator vfind(const K &Key) {
    for (VIterator I = smallBegin(), E = smallBegin() + Size; I != E; ++I)
      if (I->first == Key)
        return I;
    return smallBegin() + Size;
  }
};

#endif // SMALLMAP_H
