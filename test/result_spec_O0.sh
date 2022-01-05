#!/bin/sh

path="spec/"

files=$(ls $path*.O0)
for str in $files
do

	filename=${str##*/}
	echo $filename
	objdump $path$filename -d 1>$path$filename.obj
	python3 cmp_instruction.py $path$filename
done
