/// \file monotoneframeworkexample.cpp
/// \brief Example of minimal data-flow analysis using the MonotoneFramework
///        class

//
// This file is distributed under the MIT License. See LICENSE.md for details.
//

// Note: this compilation unit should result in no code and no data

namespace llvm {
class Module;
}

// Local libraries includes
#include "runnable/Support/MonotoneFramework.h"

namespace ExampleAnalysis {

class Label {};

class LatticeElement {
public:
  static LatticeElement bottom() { return LatticeElement(); }
  LatticeElement copy() { runnable_abort(); }
  void combine(const LatticeElement &) { runnable_abort(); }
  bool greaterThan(const LatticeElement &) { runnable_abort(); }
  void dump() { runnable_abort(); }
};

class Interrupt {
public:
  bool requiresInterproceduralHandling() { runnable_abort(); }
  LatticeElement &&extractResult() { runnable_abort(); }
  bool isReturn() const { runnable_abort(); }
};

class Analysis : public MonotoneFramework<Label *,
                                          LatticeElement,
                                          Interrupt,
                                          Analysis,
                                          llvm::iterator_range<Label **>> {
public:
  void assertLowerThanOrEqual(const LatticeElement &A,
                              const LatticeElement &B) const {
    runnable_abort();
  }

  Analysis(Label *Entry) : MonotoneFramework(Entry) {}

  void dumpFinalState() const { runnable_abort(); }

  llvm::iterator_range<Label **> successors(Label *, Interrupt &) const {
    runnable_abort();
  }

  llvm::Optional<LatticeElement> handleEdge(const LatticeElement &Original,
                                            Label *Source,
                                            Label *Destination) const {
    runnable_abort();
  }
  size_t successor_size(Label *, Interrupt &) const { runnable_abort(); }
  Interrupt createSummaryInterrupt() { runnable_abort(); }
  Interrupt createNoReturnInterrupt() const { runnable_abort(); }
  LatticeElement extremalValue(Label *) const { runnable_abort(); }
  LabelRange extremalLabels() const { runnable_abort(); }
  Interrupt transfer(Label *) { runnable_abort(); }
};

inline void testFunction() {
  Label Entry;
  Analysis Example(&Entry);
  Example.initialize();
  Example.run();
}

} // namespace ExampleAnalysis
