#!/bin/bash

result="result/"
mkdir -p $result

path0="coreutils_realworld/O0_lift/"
path1="coreutils_realworld/O1_lift/"
path2="coreutils_realworld/O2_lift/"
path3="coreutils_realworld/O3_lift/"

cp $path0*.result $result
cp $path1*.result $result
cp $path2*.result $result
cp $path3*.result $result

path4="realworld_binary/total/O0/"
path5="realworld_binary/total/O1/"
path6="realworld_binary/total/O2/"
path7="realworld_binary/total/O3/"

cp $path4*.result $result
cp $path5*.result $result
cp $path6*.result $result
cp $path7*.result $result

path8="spec/"
cp $path8*.result $result

python3 generate_result.py result/ -o ./result.csv

