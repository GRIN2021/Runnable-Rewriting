#!/bin/sh

rm -rf coreutils_realworld/O2_lift
mkdir coreutils_realworld/O2_lift
O2_path="coreutils_realworld/O2/"
result_path="coreutils_realworld/O2_lift/"
files=$(ls $O2_path)
for filename in $files
do
{
	echo $filename
	cp $O2_path$filename $result_path$filename.O2
	strip $result_path$filename.O2
	time -p runnable-lift $result_path$filename.O2 $result_path$filename.O2.ll -exe-args="--help" 1>/dev/null 2>$result_path$filename.O2.log
} 
done
