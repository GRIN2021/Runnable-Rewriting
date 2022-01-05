#!/bin/sh

rm -rf coreutils_realworld/O0_lift
mkdir coreutils_realworld/O0_lift
O0_path="coreutils_realworld/O0/"
result_path="coreutils_realworld/O0_lift/"
files=$(ls $O0_path)
for filename in $files
do
{
	echo $filename
	cp $O0_path$filename $result_path$filename.O0
	strip $result_path$filename.O0
	time -p runnable-lift $result_path$filename.O0 $result_path$filename.O0.ll -exe-args="--help" 1>/dev/null 2>$result_path$filename.O0.log
} 
done
