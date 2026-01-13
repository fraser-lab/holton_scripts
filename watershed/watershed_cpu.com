#! /bin/tcsh -f
#
#   remove one water, re-refine, report results
#
# PBS instructions
#PBS -e logs/errors.log
#PBS -o logs/run.log 
#
#  SGE instructions
#\$ -S /bin/tcsh                    #-- the shell for the job
##\$ -o logs/minus_$TASK_ID.log      #-- output directory (does not work)
##\$ -j y                            #-- tell the system that the STDERR and STDOUT should be joined
##\$ -cwd                            #-- job should start in your working directory (does not work)
##\$ -r y                            #-- if a job crashes, restart
#\$ -l mem_free=16G                 #-- submits on nodes with enough free memory (required)
#\$ -l arch=linux-x64               #-- SGE resources (CPU type)
#\$ -l netapp=16G,scratch=1G        #-- SGE resources (home and scratch disks)
#\$ -l h_rt=16:00:00               #-- runtime limit
#
# SLURM instructions
#SBATCH --output=watershed_%a.log
#SBATCH --qos=lr_normal
#SBATCH --time=08:00:00

set pdbfile = "$1"
set mtzfile = "$2"
set waternum = "$3"



# listen to the cluster
if($?SGE_TASK_ID) then
    @ waternum = ( $SGE_TASK_ID - 1 )
    set CLUSTER = SGE
endif
if($?SLURM_ARRAY_TASK_ID) then
    set waternum = $SLURM_ARRAY_TASK_ID
    set CLUSTER = SLURM
endif
if($?PBS_ARRAYID) then
    set waternum = $PBS_ARRAYID
    set CLUSTER = PBS
endif

# get CCP4 somehow
if(! $?CCP4) then
    source ~/.cshrc
endif
set path = ( ~/Develop ~/bin $path )

# prevent history substitution bombs
history -c
set savehist = ""
set histlit


echo "eliminating water $waternum "

# some platforms dont have these?
if(! $?USER) then
    setenv USER `whoami`
endif

# pick temp filename location
set mingigs = 10
set pwd = `pwd`
mkdir -p ${CCP4_SCR} >&! /dev/null
set tempdir = ${CCP4_SCR}
foreach location ( /scrapp /scrapp2 /global/scratch /scratch /tmp /dev/shm )
    if(-w ${location}/ ) mkdir -p ${location}/${USER}
    if(! -w ${location}/${USER}) continue
    set test = `df -k ${location}/${USER} | tail -n 1 | awk -v mingigs=$mingigs 'NF>5{print ($(NF-2)*1024>mingigs*1e9)}'`
    if("$test" != "1") continue
    set tempdir = ${location}/${USER}/checkpoint/
end
mkdir -p $tempdir
# pick a temp file location we can see from everywhere
set sharedtmp = ${pwd}/tempfiles
foreach location ( `dirname $tempdir` /scrapp /scrapp2 /global/scratch )
    if($?CLUSTER) then
        if("$location" == "/tmp") continue
        if("$location" == "/dev/shm") continue
        if("$location" == "/scratch") continue
    endif
    if(-w ${location}/ ) mkdir -p ${location}/${USER}
    if(! -w ${location}/${USER}) continue
    set test = `df -k ${location}/${USER} | tail -n 1 | awk -v mingigs=$mingigs 'NF>5{print ($(NF-2)*1024>mingigs*1e9)}'`
    if("$test" != "1") continue
    set sharedtmp = ${location}/${USER}/checkpoint/
end
if($?CLUSTER) set sharedtmp = ${sharedtmp}/${HOST}
mkdir -p $sharedtmp
echo "temporary dirs: $tempdir $sharedtmp"

set rundir = ${tempdir}/watershed_$$/minus_${waternum}/
mkdir -p $rundir
if(! -w $rundir) then
    echo "cannot write to $rundir"
    exit 9
endif
set checkpoint = ${sharedtmp}/watershed_$$/minus_${waternum}/
mkdir -p $checkpoint

set start = `echo "puts [clock seconds]" | tclsh`

cp -p $mtzfile $rundir
cp -p refmac_opts.txt $rundir
tac $pdbfile |\
awk -v water=$waternum '/HOH/{++w} w!=water || ! /HOH/{print}' |\
tac >! ${rundir}/refme.pdb

set libstuff = ""
set test = `ls -1 | egrep '.cif$' | wc -l`
if( $test ) then
    cp *.cif $rundir
    set libstuff = ( *.cif )
endif

onintr cleanup
cd $rundir
ln -sf $checkpoint ./checkpoint
converge_refmac.com $mtzfile refme.pdb trials=100 $libstuff nosalvage |& tee converge1.log | egrep "Free R factor  s"

set finish = `echo "puts [clock seconds]" | tclsh`
echo "$start $finish" | awk '{print "runtime:",$2-$1}'

tail -n 1 refmac_Rplot.txt

cleanup:
cd $pwd
mkdir -p minus_${waternum}/
if(! $?CLUSTER) cp ${rundir}/refmac* minus_${waternum}/
cp ${rundir}/refmacout.pdb minus_${waternum}/
tail -n 1000 ${rundir}/converge1.log >! minus_${waternum}/converge1.log


if(! $?DEBUG) then
    rm -rf $rundir
    rm -rf ${tempdir}/watershed_$$
    #find $tempdir $sharedtmp -empty -exec rm -f \{\} \;
endif


