#!/bin/sh

rm -rf coreutils_realworld/O1_lift
mkdir coreutils_realworld/O1_lift
O1_path="coreutils_realworld/O1/"
result_path="coreutils_realworld/O1_lift/"
files=$(ls $O1_path)
for filename in $files
do
{
	echo $filename
	cp $O1_path$filename $result_path$filename.O1
	strip $result_path$filename.O1
	time -p runnable-lift $result_path$filename.O1 $result_path$filename.O1.ll -exe-args="--help" 1>/dev/null 2>$result_path$filename.O1.log
} 
done
