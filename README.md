# Runnable Rewriting: Without Copy of Code

This repository guides you to build and test our work `runnable`.


## Overview

`runnable` is an open-source dynamic binary rewriter based on REV.NG. It employs QEMU to execute basic blocks and lifts these blocks to LLVM IRs for our dynamic omni-traversal analysis, and then transforms LLVM IRs into rewritten binary files. 

The current version is an implementation of our concept prototype, the stable version will be updated later. This repository is based on Makefile.


## Requirements

We tested our work `runnable` on Ubuntu-18.04 version. Check Ubuntu version:

```
$ lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 18.04.3 LTS
Release:        18.04
Codename:       bionic
```


## Builds and install

Install dependencies.

```
$ sudo support/install-dependencies.sh
```

Compile and install `runnable`.


```
$ make install-runnable
```


## How to test

Initialize the command environment.

```
$ . ./environment
```

Create a hello world program.

```
$ cat > hello.c <<EOF
#include <stdio.h>

int main(int argc, char *argv[]) {
  printf("Hello, world!\n");
}
EOF
```

Compile.

```
$ x86_64-gentoo-linux-musl-gcc hello.c -o hello -static
```

Lift and translate.

```
$ runnable-lift hello hello.ll 2>hello.log
$ runnable translate hello
```


## Experimental Evaluation

Initialize the command environment.

```
$ . ./environment
$ cd test/
```


### Test SPEC2006 binaries:

Rewrite the SPEC2006 binaries.

```
$ ./lift_spec_O0.sh
$ ./lift_spec_O1.sh
$ ./lift_spec_O2.sh
$ ./lift_spec_O3.sh
```


After successfully running the lifting script, you can evaluate the rewritten files of SPEC2006 and produce the results.

```
$ ./result_spec_O0.sh
$ ./result_spec_O1.sh
$ ./result_spec_O2.sh
$ ./result_spec_O3.sh
```


### Test Coreutils binaries:

We provide scripts to rewrite Coreutils binaries.

```
$ ./lift_coreutils_O0.sh
$ ./lift_coreutils_O1.sh
$ ./lift_coreutils_O2.sh
$ ./lift_coreutils_O3.sh

```


Evaluate the rewritten files of Coreutils and produce the results.

```
$ ./result_coreutils_O0.sh
$ ./result_coreutils_O1.sh
$ ./result_coreutils_O2.sh
$ ./result_coreutils_O3.sh
```


### Test Real-World binaries:

We provide scripts to rewrite Real-World binaries.

```
$ cd realworld_binary/total/
$ ./lift_real.sh run
```

Evaluate the rewritten files of Real-World and produce the results.

```
$ ./result_real.sh
```


### Results harvest:

```
$ cd -
$ ./count.sh
```

The aggregated results will be saved in `./result.csv` and `./result.csv.ascii_table.txt`.
The generated results are saved in the `result/` directory, which contains the test results of each benchmark.
