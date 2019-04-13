#! /bin/tcsh -f
#
#    re-compile mapman so that it works on 64-bit machines
#
#
# retrieve the Uppsala Software Factory distribution
wget http://xray.bmc.uu.se/usf/usf_distribution_kit.tar

# unpack it
tar xzvf usf_distribution_kit.tar.gz 
cd usf_export

# fix the bug
patch mapman/mapman.f << EOF
28,29c28,29
<       integer iaptr,ibptr
<       integer fmalloc
---
>       integer*8 iaptr,ibptr
>       integer*8 fmalloc
EOF

# fix other bug
patch gklib/fmalloc.c << EOF
24c24
< typedef int address_type;
---
> typedef long address_type;
EOF

# run the re-compilation script
./make_all.csh mapman -64 -static

cd mapman

# test it
wget https://github.com/fraser-lab/holton_scripts/blob/master/map_bender/mapman_regression_test.csh
chmod a+x mapman_regression_test.csh
./mapman_regression_test.csh

exit

# if things go wrong, try rebuilding

cd ../gklib
./make_fresh_gklib.csh Linux 64
cd ../mapman

rm mapman *.o
make -f Makefile_linux
cat mapman.in | ./mapman


