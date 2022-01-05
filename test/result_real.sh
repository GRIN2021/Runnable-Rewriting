#!/bin/sh
opath="coreutils_realworld/real/"
path="coreutils_realworld/real_lift/"

files=$(ls $opath)
for str in $files
do

	filename=${str##*/}
	echo $filename
	objdump $opath$filename -d 1>$path$filename.obj
	python3 cmp_instruction.py $path$filename
done
