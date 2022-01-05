#!/bin/bash

path="spec/"
var=O3

PERL=$path'perlbench_base.x86'.$var
BZIP=$path'bzip2_base.x86'.$var
MCF=$path'mcf_base.x86'.$var
LIBQ=$path'libquantum_base.x86'.$var
SJENG=$path'sjeng_base.x86'.$var
HMMER=$path'hmmer_base.x86'.$var
GOBMK=$path'gobmk_base.x86'.$var
GCC=$path'gcc_base.x86'.$var
H264=$path'h264ref_base.x86'.$var
OMN=$path'omnetpp_base.x86'.$var
ASTAR=$path'astar_base.x86'.$var
XALAN=$path'Xalan_base.x86'.$var

echo "400" 
cp $PERL $PERL.stripped
strip $PERL.stripped
time -p runnable-lift $PERL.stripped $PERL.ll 2>$PERL.log 1>/dev/null
rm $PERL.stripped
echo "401" 
cp $BZIP $BZIP.stripped
strip $BZIP.stripped
time -p runnable-lift $BZIP.stripped $BZIP.ll 2>$BZIP.log 1>/dev/null
rm $BZIP.stripped
echo "429"
cp $MCF $MCF.stripped
strip $MCF.stripped
time -p runnable-lift $MCF.stripped $MCF.ll  2>$MCF.log 1>/dev/null
rm $MCF.stripped
echo "462"
cp $LIBQ $LIBQ.stripped
strip $LIBQ.stripped
time -p runnable-lift $LIBQ.stripped $LIBQ.ll 2>$LIBQ.log 1>/dev/null
rm $LIBQ.stripped
echo "458"
cp $SJENG $SJENG.stripped
strip $SJENG.stripped
time -p runnable-lift $SJENG.stripped $SJENG.ll -exe-args="--help" 2>$SJENG.log 1>/dev/null
rm $SJENG.stripped
echo "456"
cp $HMMER $HMMER.stripped
strip $HMMER.stripped
time -p runnable-lift $HMMER.stripped $HMMER.ll 2>$HMMER.log 1>/dev/null
rm $HMMER.stripped
echo "445"
cp $GOBMK $GOBMK.stripped
strip $GOBMK.stripped
time -p runnable-lift $GOBMK.stripped $GOBMK.ll -exe-args="--help" 2>$GOBMK.log 1>/dev/null
rm $GOBMK.stripped
echo "403"
cp $GCC $GCC.stripped
strip $GCC.stripped
time -p runnable-lift $GCC.stripped $GCC.ll -exe-args="--help" 2>$GCC.log 1>/dev/null
rm $GCC.stripped
echo "464"
cp $H264 $H264.stripped
strip $H264.stripped
time -p runnable-lift $H264.stripped $H264.ll 2>$H264.log 1>/dev/null
rm $H264.stripped
echo "471"
cp $OMN $OMN.stripped
strip $OMN.stripped
time -p runnable-lift $OMN.stripped $OMN.ll 2>$OMN.log 1>/dev/null
rm $OMN.stripped
echo "473"
cp $ASTAR $ASTAR.stripped
strip $ASTAR.stripped
time -p runnable-lift $ASTAR.stripped $ASTAR.ll 2>$ASTAR.log 1>/dev/null
rm $ASTAR.stripped
echo "483"
cp $XALAN $XALAN.stripped
strip $XALAN.stripped
time -p runnable-lift $XALAN.stripped $XALAN.ll 2>$XALAN.log 1>/dev/null
rm $XALAN.stripped

