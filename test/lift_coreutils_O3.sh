#!/bin/sh

rm -rf coreutils_realworld/O3_lift
mkdir coreutils_realworld/O3_lift
O3_path="coreutils_realworld/O3/"
result_path="coreutils_realworld/O3_lift/"
files=$(ls $O3_path)
for filename in $files
do
{
	echo $filename
	cp $O3_path$filename $result_path$filename.O3
	strip $result_path$filename.O3
	time -p runnable-lift $result_path$filename.O3 $result_path$filename.O3.ll -exe-args="--help" 1>/dev/null 2>$result_path$filename.O3.log
} 
done
