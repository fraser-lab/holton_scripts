#! /bin/tcsh -f
#
#   throw out one water at a time and refine to convergence
#
#

set pdbfile = start.pdb
set mtzfile = Fparted.mtz

foreach arg ( $* )
    if("$arg" =~ *.mtz) set mtzfile = $arg
    if("$arg" =~ *.pdb) set pdbfile = $arg
    if("$arg" =~ CPUs=*) set CPUs = `echo $arg | awk -F "=" '{print $2+0}'`
end

set noglob
set checkpointdir = /dev/shm/${USER}
if(! $?CLUSTER) set CLUSTER
if($CLUSTER == "PBS") set checkpointdir = tempfiles/*/watershed_*/
if($CLUSTER == "SGE") set checkpointdir = /scrapp2/jamesh/*/watershed_*/
unset noglob

set elim0 = `ls -1rt start_elim*.pdb | awk -F "_" '{print $NF+0}' | sort -gr | head -n 1`
if(-e start_elim_${elim0}.pdb) cp start_elim_${elim0}.pdb newstart.pdb
if("$elim0" == "") then
    set elim0 = 1
    cp $pdbfile newstart.pdb
endif

set waters = `awk '/^ATOM|^HETAT/ && /HOH/' newstart.pdb | wc -l`
set pwd = `pwd`
foreach elim ( `seq $elim0 $waters` )

cp newstart.pdb start_elim_${elim}.pdb
awk '/^ATOM|^HETAT/ && /HOH/' newstart.pdb >! water.pdb
set waters = `cat water.pdb | wc -l`
echo "$waters waters in newstart.pdb"

echo "clearing last run"
rm -rf minus_[0-9]*/
rm -rf logs
rm -rf $checkpointdir
mkdir -p logs
echo "job launch"
if("$CLUSTER" == "") goto local
if("$CLUSTER" == "PBS") then
    if("$CPUs" != "") then
        set pbsCPUs = "%$CPUs"
    endif
#    qsub -e logs/errors.log -o logs/run.log -d $pwd -t 0-${waters}%100 ./watershed_cpu.com -F "newstart.pdb $mtzfile" 
    qsub -e logs/errors.log -o logs/run.log -d $pwd -t 0-${waters}$pbsCPUs ./watershed_cpu.com -F "newstart.pdb $mtzfile" 
endif
if("$CLUSTER" == "SGE") then
    @ plusone = ( $waters + 1 )
#    qsub -cwd -t 1-$plusone -j yes -masterq long.q -o logs/run.log.\$TASK_ID -l h_rt=336:00:00 ./watershed_cpu.com newstart.pdb $mtzfile
    qsub -cwd -t 1-$plusone -j yes -masterq lab.q -o logs/run.log.\$TASK_ID -l h_rt=10:00:00 ./watershed_cpu.com newstart.pdb $mtzfile
endif

sleep 10
set running = 0
while ( ! $running )
    set running = `qstat -t | awk '$(NF-1)=="R" || / r /{print}' | wc -l`
    if( ! $running ) then
        echo "waiting for jobs to start ..."
        sleep 300
    endif
end
qstat

set running = 999
set lastrunning = 0
while ( $running )
    set running = `qstat -t | awk '$(NF-1)=="R" || / r /{print}' | wc -l`
    if( $running != $lastrunning ) echo "$running jobs running ..."
    set lastrunning = $running
    if( $running ) sleep 10
end


local:
if("$CLUSTER" != "") goto sumup

if(! $?CPUs) set CPUs = `grep proc /proc/cpuinfo | wc -l`
set waters = `awk '/HOH/' newstart.pdb | wc -l`
set pwd = `pwd`
set water = -1
set jobs = 0
set lastjobs = 0
mkdir -p logs
while ( $water <= $waters )
    @ water = ( $water + 1 )
    ./watershed_cpu.com newstart.pdb $mtzfile $water >&! logs/job_${water}.log &

    # now make sure we dont overload the box
    @ jobs = ( $jobs + 1 )
    while ( $jobs >= $CPUs )
        sleep 4
        set jobs = `ps -fu $USER | grep converge_refmac.com | grep -v grep | wc -l`
        if($jobs != $lastjobs) echo "$jobs jobs running..."
        set lastjobs = $jobs
    end 
end
wait


sumup:
set waters = `cat water.pdb | wc -l`
set water = -1
echo -n "" >! R_vs_elim.txt
rm -f missing_runs.txt
while ( $water < $waters )
    @ water = ( $water + 1 )
    set num = $water
    set rundir = minus_$num
    tac ${rundir}/converge1.log |&\
      awk '/^moved/{while($1+0==0){getline};print "endcyc",$1;exit}' |\
    cat >! endcyc.txt
    if ( ! -e ${rundir}/refmacout.pdb || ! -e ${rundir}/converge1.log ) then
        echo "WARNING: missing $rundir" | tee -a missing_runs.txt
        mkdir -p $rundir
        cp ${checkpointdir}/${rundir}/refmacout.pdb $rundir
        tail -n 1 ${checkpointdir}/${rundir}/refmac_Rplot.txt |&\
          awk '{print "endcyc",$1;exit}' |\
        cat >! endcyc.txt
    endif
    if ( ! -e ${rundir}/refmacout.pdb ) then
        echo "WARNING: missing checkpoint for $rundir" | tee -a missing_runs.txt
        ls -l ${checkpointdir}/${rundir}/ |  tee -a missing_runs.txt
        sleep 1
    endif    
    cat minus_0/refmacout.pdb ${rundir}/refmacout.pdb |\
    awk '/^ATOM|^HETAT/{id=substr($0,12,15);++seen[id];\
                   occB[id]=substr($0,55,12)}\
        END{for(id in seen)if(seen[id]==1)print "elim",id,occB[id]}' |\
    cat >! elim.txt
    echo $rundir |\
    cat - endcyc.txt elim.txt ${rundir}/refmacout.pdb |\
    awk 'NR==1{rundir=$0} /^elim/{elim=substr($0,6);next}\
         /^endcyc/{ec=$2}\
         /  R VALUE/{R=$NF} /  FREE R VALUE  /{print R,$NF,elim,ec+0,rundir;exit}'|\
    tee -a R_vs_elim.txt
end
sort -k1g R_vs_elim.txt >! R_vs_elim_${elim}.txt
sort -k2g R_vs_elim.txt >! cheating.txt

set minR = `awk '{print $NF;exit}' R_vs_elim_${elim}.txt`
set minRfree = `sort -k2g R_vs_elim_${elim}.txt | awk '{print $NF;exit}'`
if("$minR" != "$minRfree") then
    echo "WARNING: minimum R run is not also minimum Rfree run:"
endif
echo $minR $minRfree minus_0 |\
cat - R_vs_elim_${elim}.txt |\
awk 'NR==1{for(i=1;i<=NF;++i)++sel[$i];next} sel[$NF]{print $0,NR-1}' |\
tee minRfacs.txt

# start with the one with the lowest R factor
cp ${minR}/refmacout.pdb best_elim_${elim}.pdb

set Rcut = `awk 'NR==1{minR=$1} /minus_0 /{print (minR+$1)/2}' minRfacs.txt`

if("$minR" == "minus_0") then
    echo "FINISHED: no-elimination run was better than all others"
    exit
endif

# start with the one with the lowest R factor
cp best_elim_${elim}.pdb newstart.pdb


# find best exclusions spatially-separated from others
awk -v Rcut=$Rcut '$1>Rcut || $NF=="minus_0"{exit} {print}' R_vs_elim_${elim}.txt |\
cat - newstart.pdb |\
awk '$1+0>0{id=substr($0,17,15);++elim[id];score[id]=$1;next}\
   /^CRYST1/{print;next} {id=substr($0,12,15)}\
   /^ATOM|^HETAT/ && elim[id]{print score[id],$0}' |\
sort -g |\
awk '{print substr($0,match($0,"HETAT|ATOM"))}' |\
cat >! elim_candidates.pdb
cp elim_candidates.pdb left.pdb
echo -n "" >! elim_forshure.pdb

# run down list of candiates, discarding neighbors as we go
foreach line ( `awk '/^ATOM|^HETAT/{print NR}' elim_candidates.pdb` )
    egrep "^ATOM|^HETAT" elim_candidates.pdb |\
     head -n $line | tail -n 1 >! this.pdb
    # check if this is still a possibility
    set test = `cat this.pdb left.pdb | awk 'NR==1{++sel[$0];next} sel[$0]{print 1}'`
    if("$test" != "1") continue
    # discard any candidates within 5A of true candidate
    neighbors.com left.pdb this.pdb -5 | tee neighbors.log | tail -n 1
    mv neighbors.pdb left.pdb
    @ line = ( $line + 1 )
    cat this.pdb >> elim_forshure.pdb

    set test = `awk '/ready in neigh/{print ($1>0)}' neighbors.log`
    if( "$test" != "1" ) break
end

# now actually remove selected atoms
awk '{print $0,"ELIM"}' elim_forshure.pdb |\
cat - newstart.pdb |\
awk '{ID=substr($0,12,15)}\
     $NF=="ELIM"{++elim[ID];next}\
   /^ATOM|^HETAT/ && elim[ID]{next} {print}' |\
cat >! eliminated.pdb
mv eliminated.pdb newstart.pdb
@ elim = ( $elim + 1 )
cp newstart.pdb start_elim_${elim}.pdb

grep runtime logs/*.log* | sort -k2gr | awk '{print "longest run:",$2/3600,"h";exit}'

end

exit





foreach px ( `seq -f%02.0f 9 32` )
    echo -n "$px "
    ssh pxproc$px "mv /dev/shm/holton/watershed_*/minus_* projects/watershed/torq1/"
end
foreach px ( `seq -f%02.0f 9 32` )
    echo -n "$px "
    ssh pxproc$px "rm -rf /dev/shm/holton/"
end
foreach px ( `seq -f%02.0f 9 32` )
    echo -n "$px "
    ssh pxproc$px "killall -g converge_refmac.com ; rm -rf /dev/shm/holton/"
end




grep HOH newstart.pdb >! water.pdb
set waters = `cat water.pdb | wc -l`
set medocc = `awk '{print substr($0,55,6)}' newstart.pdb | ~/awk/median.awk`
set medB = `awk '{print substr($0,61,6)}' newstart.pdb | ~/awk/median.awk`
echo "$medocc $medB" |\
cat - water.pdb |\
awk 'NR==1{occ0=$1;sigocc=$3;B0=$4;sigB=$6;next}\
    {occ=substr($0,55,6);B=substr($0,61,6);print $0,++n,((occ-occ0)/sigocc)**2*((B-B0)/sigB)**2}' |\
sort -k14g

set jobs = 0
set lastjobs = 0
echo -n "" >! qsubs.log
set water = -1
while ( $water <= $waters )
    @ water = ( $water + 1 )
    set num = `echo $water $waters | awk '{printf("%0"length($2)"d",$1)}'`
    
    echo -n "$num " | tee -a qsubs.log
    mkdir -p minus_${num}/
    qsub -e minus_${num}/errors.log -o minus_${num}/run.log -d $pwd ./watershed_cpu.com -F "newstart.pdb $mtzfile $num" >> qsubs.log
    sleep 2
end






mkidr fuzzcheat17
cd fuzzcheat17

cp ~/projects/solvent_model/fuzzymask/cheat/final.pdb start.pdb
cp ~/projects/solvent_model/fuzzymask/fuzzcheat17/Fparted.mtz .
cp ~/projects/solvent_model/fuzzymask/fuzzcheat17/refmacout.pdb start.pdb
cat << EOF | tee refmac_opts_base.txt | tee refmac_opts.txt
scpart 1
solvent no
scale type simple
vdwrestrains 0
make hydr Y
make hout Y
EOF
refmac_occupancy_setup.com start.pdb | tee -a refmac_opts.txt 

converge_refmac.com start.pdb Fparted.mtz >&! converge1.log &
wait

cat << EOF | tee refmac_opts.txt
scpart 1
solvent no
scale type simple
vdwrestrains 0
make hydr A
make hout Y
EOF

cp refmacout_minRfree.pdb new.pdb
converge_refmac.com new.pdb Fparted.mtz trials=1 
cat refmacout.pdb |\
awk '/HG/ && /CYS/{next} {print}' |\
cat >! start2.pdb
cat << EOF | tee refmac_opts_base.txt | tee refmac_opts.txt
scpart 1
solvent no
scale type simple
vdwrestrains 0
make hydr Y
make hout Y
EOF
refmac_occupancy_setup.com start2.pdb | tee -a refmac_opts.txt 
converge_refmac.com start2.pdb Fparted.mtz >&! converge2.log &







