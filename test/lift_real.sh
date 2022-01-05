#!/bin/sh

rm -rf coreutils_realworld/real_lift
mkdir coreutils_realworld/real_lift
real_path="coreutils_realworld/real/"
result_path="coreutils_realworld/real_lift/"
files=$(ls $real_path)
for filename in $files
do
{
	echo $filename
	cp $real_path$filename $result_path$filename
	strip $result_path$filename
	time -p runnable-lift $result_path$filename $result_path$filename.ll -exe-args="--help" 1>/dev/null 2>$result_path$filename.log
} 
done
