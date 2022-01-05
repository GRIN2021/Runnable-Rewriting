#!/bin/sh
root_dir=`pwd`
bin_txt=`cat bin.txt`
generate_result(){
	cd $1/

	for str in $bin_txt
	do
		filename=$str
		echo $filename".$1"
		mv $filename $filename.$1
	done
	cd $root_dir

}

generate_result O0
generate_result O1
generate_result O2
generate_result O3
