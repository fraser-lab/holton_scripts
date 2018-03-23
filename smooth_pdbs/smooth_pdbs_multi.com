#! /bin/tcsh -f
#
#	smooth the coordinates, occupancies and B factor for a collection of PDBs		-James Holton  1-31-18
#	break up over multiple CPUs
#       see smooth_pdbs_atom.com for details
#
#
set weight = 1
set in_states = ""		
set out_states = ""		

help:
if("$*" == "" || "$*" =~ "-h*" || "$*" =~ "--h*" || $?HELPME) then
    cat << EOF
usage: $0 refined_00?.pdb CPUs=12 machine=node01 weight=1 in_states=100,200,250,300,310 out_states=100-300:10

where:
*.pdb    list of PDB files to smooth over
ref=     single PDB file containing all possible atoms
weight   increase data weight in smoothing function, higher numbers make result less smooth
in_states  specify "x" axis for smoothing as comma-separated list or start-end:step range. default extract from filenames
out_states specify "x" axis for output files.  default: same as inputs
EOF
    exit 9
endif


set atomrange = ""
set machine = ""

set logfile = /dev/null

set sdir = `dirname $0`
set sdir = `cd $sdir ; pwd`

set refpdb 
set pdbfiles 
set args = ""
foreach arg ( $* )
    if("$arg" =~ ref=*.pdb) then
        set refpdb = `echo $arg | awk -F "=" '{print $2}'`
        continue
    endif
    if("$arg" =~ *.pdb) then
        set pdbfiles = ( $pdbfiles $arg )
        continue
    endif
    if("$arg" =~ CPUs=*) then
        set user_CPUs = `echo $arg | awk -F "=" '{print $2}'`
        continue
    endif
    if("$arg" =~ machine=*) then
        set machine = `echo $arg | awk -F "=" '{print $2+0}'`
        continue
    endif
    if("$arg" =~ [1-9]*-*[0-9]) then
        set atomrange = `echo $arg | awk -F "-" '{print $1+0,$2+0}'`
        continue
    endif

    if("$arg" =~ in_states=*) set in_states = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ out_states=*) set out_states = `echo $arg | awk -F "=" '{print $2}'`

    # pass these along
    set args = ( $args $arg )
end
if($#pdbfiles == 0) then
    set HELPME
    goto help
endif

# transform user-specified input states into words
if("$in_states" =~ *,*) then
    # take as comma-separated list
    set in_states = `echo " $in_states " | awk -F "[, ]" '{for(i=1;i<=NF;++i) print $i}'`
endif
if("$out_states" =~ *,*) then
    # take as comma-separated list
    set out_states = `echo " $out_states " | awk -F "[, ]" '{for(i=1;i<=NF;++i) print $i}'`
endif

# transform user-specified input/output state range into words
if("$in_states" =~ *[0-9]-[0-9]* || "$in_states" =~ *[0-9]:[0-9]*) then
    # take as start-stop:step
    set in_states = `echo " $in_states " | awk -F "[x,:-]" '{for(x=$1;x<=$2;x+=$3) print x}'`
endif
if("$out_states" =~ *[0-9]-[0-9]* || "$in_states" =~ *[0-9]:[0-9]* ) then
    # take as comma-separated list
    set out_states = `echo " $out_states " | awk -F "[x,:-]" '{for(x=$1;x<=$2;x+=$3) print x}'`
endif

# make something up by default
if("$in_states" == "") then
    echo -n "" >! in_states.txt
    foreach n ( `seq 1 $#pdbfiles` )
        set pdbfile = $pdbfiles[$n]
        set in_state = `echo $pdbfile | awk '$1~/[0-9]/{print substr($1,match($1,"[0-9]"))+0}'`
        if("$in_state" == "") set in_state = $n
        echo "$in_state" >> in_states.txt
    end
    set in_states = `sort -g in_states.txt`
    if(! $?DEBUG) rm -f in_states.txt
endif

echo "input states: $in_states "
if( $#in_states != $#pdbfiles || $#in_states == 0 ) then
    set BAD = "number of input states must match number of pdb files"
    goto exit
endif

# if all else fails, match input to output
if("$out_states" == "") then
    set out_states = ( $in_states )
endif


if("$refpdb" == "") then
    # need to make a reference containing all unique atom names.  Preferably in the right order.
    echo "making reference pdb..."
    cat $pdbfiles |\
    egrep "^ATOM|^HETAT" |\
    awk '{id=substr($0,12,15)} \
    ! seen[id]{++seen[id];print id}' |\
    tee tempfile$$_ids.txt |\
    awk 'substr($0,6,1)!=" "{print "SPLITTER:",substr($0,1,5)" "substr($0,7)}' |\
    cat >! tempfile$$_splitters.txt

    # now find all atom ids, excluding " " conf for "splitter" atoms (that have non-" " confs)
    awk '{line[FNR]=line[FNR]"\n"$0} FNR>maxFNR{maxFNR=FNR}\
      END{for(i=1;i<=maxFNR;++i)print line[i]}' $pdbfiles |\
    egrep "^ATOM|^HETAT" |\
    cat tempfile$$_splitters.txt - |\
    awk '/^SPLITTER/{id=substr($0,11);++splitter[id];next}\
      {id=substr($0,12,15)} \
    ! seen[id] && ! splitter[id]{++atoms;++seen[id];print}' |\
    sort -k1.22,1.22 -k1.23,1.26g -k1.7,1.11g |\
    cat >! tempfile$$_ref.pdb
    set refpdb = tempfile$$_ref.pdb
    rm -f tempfile$$_ids.txt tempfile$$_splitters.txt

    if(! -e ref.pdb) then
        mv tempfile$$_ref.pdb ref.pdb
        set refpdb = ref.pdb
    endif
endif


set atoms = `egrep "^ATOM|^HETAT" $refpdb | wc -l`
if($#atomrange == 2) then
    set atomrange = `echo $atomrange $aroms | awk '$1<1{$1=1} $2>$3{$2=$3} {print $1,$2}'`
    set atoms = `echo $atomrange | awk '{print $2-$1+1}'`
else
    set atomrange = ( 1 $atoms )
endif
echo "smoothing $#pdbfiles pdb files with $atoms atoms each for atom range: $atomrange[1]-$atomrange[2]"

set MULTI_CPUS = 1
if ($?MULTI_CPUS) then
    set procs = `awk '/^processor/' /proc/cpuinfo | wc -l`
    set chips = `awk '/^physical/' /proc/cpuinfo | sort -u | wc -l`
    set cores_per_chip = `awk '/^core/' /proc/cpuinfo | sort -u | wc -l`
    set cores = `echo $chips $cores_per_chip | awk '{print $1*$2}'`
    set threads_per_chip = `awk '/^siblings/{print $NF;exit}' /proc/cpuinfo`
    set threads_per_core = `echo $threads_per_chip $cores_per_chip | awk '{threads=int($1/$2+0.001)} threads==0{threads=1} {print threads}'`
    echo "found $procs CPUs on $chips chips with $cores_per_chip cores each ($threads_per_core threads/core)"

    set freeCPUs = `w | cat - /proc/cpuinfo - | awk '/^processor/{++p} /load aver/{l=$(NF-2)+0} END{print int(p-l+0.5)}'`
    echo "found $freeCPUs free CPUs"
    set CPUs = "$freeCPUs"
    if("$freeCPUs" == "") then
        echo "WARNING: unable to determine number of CPUs, reverting to single-threaded operation"
        unset MULTI_CPUS
        set CPUs = 2
    endif
    if($?user_CPUs) then
        if("$user_CPUs" == "all") set user_CPUs = $procs
        if("$user_CPUs" == "cores") set user_CPUs = $cores
        if("$user_CPUs" == "0") set user_CPUs = $cores
        set CPUs = $user_CPUs
    endif
    echo "using $CPUs cpus."
endif
set machinetag = "_${machine}"
if("$machine" == "") set machinetag = ""


set pwd = `pwd`
set tmpwd = /dev/shm/gnuplot
rm -rf ${tmpwd}/atom* >& /dev/null
mkdir -p $tmpwd
# copy into cache
set tmppdbfiles = ""
foreach n ( `seq 1 $#pdbfiles` )
    set pdbfile = $pdbfiles[$n]
    set state = $in_states[$n]
    cp -p $pdbfile ${tmpwd}/state_${state}.pdb
    set tmppdbfiles = ( $tmppdbfiles state_${state}.pdb )
end
cp -p $refpdb ${tmpwd}/ref.pdb
set jobs = 0
foreach atom ( cell `seq $atomrange` )
  echo "atom $atom"
  set atomdir = ${tmpwd}/atom$atom
  mkdir -p $atomdir
  cd $atomdir
  ${sdir}/smooth_pdbs_atom.com atom=$atom $args $tmppdbfiles ref=../ref.pdb >&! runme_cpu.log &
cd $pwd
@ jobs = ( $jobs + 1 )
echo "$jobs $CPUs"
while( $jobs >= $CPUs )
    set jobs = `ps -fu $USER | grep "smooth_pdbs_atom.com" | grep -v grep | grep -v logs | wc -l`
    echo "atom $atom : $jobs jobs running..."
    if( $jobs >= $CPUs ) sleep 1
end

end

set lastjobs = $jobs
while( $jobs > 0 )
    set jobs = `ps -fu $USER | grep "smooth_pdbs_atom.com" | grep -v grep | grep -v logs | wc -l`
    if($jobs != $lastjobs) then
        echo "$jobs jobs still running at `date`"
        set lastjobs = $jobs
    endif
    sleep 1
end
wait

# now combine smoothed parameter data into one big file
# also compile the atom "noisiness" data
cat ${tmpwd}/atomcell/smooth_vs_*.txt >! state_vs_xyzoB${machinetag}.txt
cat ${tmpwd}/atomcell/atom_noise.txt >! atom_noise${machinetag}.txt
foreach atom ( `seq $atomrange` )
    set atomdir = ${tmpwd}/atom$atom
    if(! -s ${atomdir}/smooth_vs_B.txt) then
        echo "check ${atomdir}/smooth_vs_B.txt"
        break
    endif
    echo "extracting atom $atom"
    cat ${atomdir}/smooth_vs_[xyzoB].txt >> state_vs_xyzoB${machinetag}.txt
    cat ${atomdir}/atom_noise.txt >> atom_noise${machinetag}.txt
end

# gather output states
set out_states = `awk 'seen[$1]{exit} {print $1;++seen[$1]}' state_vs_xyzoB${machinetag}.txt | sort -u | sort -g`


echo -n "" >! in_state_pdb.txt
foreach n ( `seq 1 $#in_states` )
    echo $in_states[$n] $pdbfiles[$n] >> in_state_pdb.txt
end


# now assemble the output pdb files
# gathering stats as we go
rm -f state_vs_smoothshift${machinetag}.txt
foreach state ( $out_states )
    # need a PDB file for reference?
    awk -v state=$state '{print sqrt(($1-state)^2),$2}' in_state_pdb.txt |\
    sort -g | awk '{print $2;exit}' >! inpdb.txt
    set inpdbfile = `cat inpdb.txt`
    rm -f inpdb.txt
    if(! -e "$inpdbfile") set inpdbfile = $refpdb

    # extract relevant smoothed values for this time point state
    awk '/^CRYST1/{print;exit}' $pdbfiles[1] | head -n 1 >! cryst.txt
    egrep "^$state " state_vs_xyzoB${machinetag}.txt |\
    cat - cryst.txt $refpdb |\
    awk '$NF=="xyzoB"{atom=$2;x=$6;v=$5;if(x=="x"){X[atom]=v};if(x=="y"){Y[atom]=v};if(x=="z"){Z[atom]=v};\
               if(x=="o"){occ[atom]=v};if(x=="B"){B[atom]=v};next}\
        $NF=="abcalbega"{x=$6;v=$5;if(x=="a"){cell_a=v};if(x=="b"){cell_b=v};if(x=="c"){cell_c=v};\
               if(x=="al"){cell_al=v};if(x=="be"){cell_be=v};if(x=="ga"){cell_ga=v};next}\
        /^CRYST1/{atom=0;printf("CRYST1%9.3f%9.3f%9.3f%7.2f%7.2f%7.2f%s\n",\
          cell_a,cell_b,cell_c,cell_al,cell_be,cell_ga,substr($0,55))}\
        /^ATOM|^HETAT/{++atom;\
          #pass thru anything this node didnt smooth \
          if(X[atom]=="")X[atom]=substr($0,31,8);\
          if(Y[atom]=="")Y[atom]=substr($0,39,8);\
          if(Z[atom]=="")Z[atom]=substr($0,47,8);\
          if(occ[atom]=="")occ[atom]=substr($0,55,6);\
          if(B[atom]=="")B[atom]=substr($0,61,6);\
          printf("%s%8.3f%8.3f%8.3f%6.2f%6.2f%s\n",substr($0,1,30),X[atom],Y[atom],Z[atom],occ[atom],B[atom],substr($0,67))}'|\
    cat >! smooth_all_${state}${machinetag}.pdb

    awk '{printf("%-85s SMOOTHED\n",substr($0,1,85))}' smooth_all_${state}${machinetag}.pdb |\
    cat - $inpdbfile |\
    awk '{id=substr($0,12,15)} $NF=="SMOOTHED"{smth[id]=substr($0,31,36);next}\
      ! /^ATOM|^HETAT|^CRYST/{print;next}\
        {print substr($0,1,30) smth[id] substr($0,67)}' |\
    cat >! smooth_${state}${machinetag}.pdb

    echo -n "$state   " | tee -a state_vs_smoothshift${machinetag}.txt
    rmsd -v xlog=1 $inpdbfile smooth_${state}${machinetag}.pdb | tee -a state_vs_smoothshift${machinetag}.txt
end

echo "noisiest atoms:"
echo "atom p X rmsvar final_value smooth_value"
sort -k4gr atom_noise${machinetag}.txt |\
awk 'seen[$2]<3{print;++seen[$2]}' |\
cat - $refpdb |\
awk '/^ATOM|^HETAT/{++n} \
     /^[0-9]/{++sel[$1];stuff[$1]=$0}\
     sel[n]{print stuff[n],substr($0,12,15)}' |\
tee noisy_atoms.txt

set atom_par = `tail -n 1 noisy_atoms.txt | awk '{print $1"_"$2}'`
set n = 0
foreach atom_par ( 0_1 0_2 0_3 `tac noisy_atoms.txt | awk '! seen[$2]{print;++seen[$2]}' | awk '{print $1"_"$2}'` )
    @ n = ( $n + 1 )
    set atom = `echo $atom_par | awk -F "_" '{print $1}'`
    set par  = `echo $atom_par | awk -F "_" '{print $2}'`
    set atomname = `awk -v atom=$atom '/^ATOM|^HETAT/{++n} n==atom{print substr($0,12,15);exit}' $refpdb`
    if("$atom" == "0") set atomname = "cell $par"
    echo $atom $par $atomname |\
    cat - state_vs_xyzoB.txt |\
    awk 'NR==1{atom=$1;par=$2;name=$3" "$4" "$5" "$6" "$7;next}\
         $2==atom && $3==par{print $0,name}' >! noisy${n}_plotme.txt
    set parname = `awk '{print $6;exit}' noisy${n}_plotme.txt`
    echo "set title 'atom $atom $atomname $parname' ; plot 'noisy${n}_plotme.txt' using 1:4, 'noisy${n}_plotme.txt' using 1:5 smooth csplines lt 3 "
end

if($?DEBUG) exit

rm -f tempfile$$_ref.pdb >&! /dev/null
rm -f cryst.txt in_state_pdb.txt 

exit


foreach state ( `seq -f%03.0f 0 100` )

    cp smooth_${state}.pdb minimizeme.pdb

    phenix.geometry_minimization minimizeme.pdb

    mv minimizeme_minimized.pdb state${state}.pdb

end


