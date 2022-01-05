#!/bin/bash
name=`basename $0 .sh`
root_dir=`pwd`
run_runnable(){
    for str in `cat bin.txt`
    do
        echo "Run $str Opt. Level $1"
        cp ./$1/$str.$1 ./$1/$str.$1.stripped
        strip ./$1/$str.$1.stripped
        time -p runnable-lift ./$1/$str.$1.stripped ./$1/$str.$1.ll 2>./$1/$str.$1.log 1>/dev/null
        if [ $? -ne 0 ]; then
            echo "-----------------$str Opt. Level $1 Lift failed!----------------"
        fi
    done
}

clean_result(){
    rm ./$1/*.log
    rm ./$1/*.csv
    rm ./$1/*.ll
    echo "Clean $1 dir finished!"
}
case $1 in
 r|run)
        echo "Run all test"
        run_runnable O0
        run_runnable O1
        run_runnable O2
        run_runnable O3
        ;;
 clean)
        echo "Clean all result"
        clean_result O0
        clean_result O1
        clean_result O2
        clean_result O3
        ;;
 *)
        echo "Usage: $name [run|clean]"
        exit 1
        ;;
esac
