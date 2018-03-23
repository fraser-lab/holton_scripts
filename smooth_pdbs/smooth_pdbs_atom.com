#! /bin/tcsh -f
#
#        smooth the coordinates, occupancies and B factor for a collection of PDBs                -James Holton  1-31-18
#        extract a given ordinal-numbered atom from a list of PDB files
#        smooth the coordinates, occupancies and B factor
#        output as text for later re-assembly
#       user may specify "in_states" and "out_states" as "x axis" numbers to assign to each pdb file
#       try to extract "x" coordinate variable from first number in PDB file name
#       otherwise will use ordinal number
#
#
#
help:
if("$*" == "" || "$*" =~ "-h*" || "$*" =~ "--h*" || $?HELPME) then
    cat << EOF
usage: $0 refined_00?.pdb atom=123 weight=1 smult=1

where:
*.pdb    list of PDB files to smooth over
atom     ordinal number of atom in first pdb file to extract and smooth its coordinates
weight   increase data weight in smoothing function, higher numbers make result less smooth
in_states  specify "x" axis for smoothing as comma-separated list or start-end:step range. default extract from filenames
out_states specify "x" axis for output files.  default: same as inputs
EOF
    exit 9
endif

set atom = 1
set weight = 1      
set def_wt = 0.01
set ext_wt = 1e-6
set in_states = ""		
set out_states = ""		
set min_occ = 0.01
set max_occ = 1.00

set logfile = /dev/null

set refpdb = ""
set pdbfiles = ""
foreach arg ( $* )
    if("$arg" == debug) set DEBUG
    if("$arg" =~ ref=*.pdb) then
        set pdb = `echo $arg | awk '{print substr($0,5)}'`
        if(! -e "$pdb") set pdb = "../$pdb"
        set refpdb = "$pdb"
        continue
    endif
    if("$arg" =~ *.pdb) then
        set pdb = "$arg"
        if(! -e "$pdb") set pdb = "../$pdb"
        set pdbfiles = ( $pdbfiles "$pdb" )
    endif
    if("$arg" == "cell") set atom = 0
    if("$arg" =~ atom=*) set atom = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ weight=*) set weight = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ in_states=*) set in_states = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ out_states=*) set out_states = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ min_occ=*) set min_occ = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ max_occ=*) set max_occ = `echo $arg | awk -F "=" '{print $2}'`
end

if($?DEBUG) set logfile = /dev/tty
if("$refpdb" == "") set refpdb = $pdbfiles[1]


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

if( $#in_states != $#pdbfiles) then
    set BAD = "number of input states must match number of pdb files"
    goto exit
endif

# if all else fails, match input to output
if("$out_states" == "") then
    set out_states = ( $in_states )
endif

# now we need to establish extrapolation distance
echo " $in_states $out_states " |\
 awk -F "[, ]" '{for(i=1;i<=NF;++i) print $i}' |\
 awk 'NF!=0' |\
 sort -u |\
 sort -g >! states.txt

set state_lo = `head -n 1 states.txt`
set state_hi = `tail -n 1 states.txt`
if(! $?state_step) then
    set state_avgstep = `sort -g states.txt | awk 'NR==1{last=$1;next} {print $1-last;last=$1}' | awk '{++n;sum+=$1} END{if(n)print sum/n}'`
    set state_smallstep = `sort -g states.txt | awk 'NR==1{last=$1;next} {print $1-last;last=$1}' | sort -g | head -n 1`
    set state_range = `sort -g states.txt | awk 'NR==1{s=$1} END{print $1-s}'`
    set state_pctstep = `echo $state_range | awk '{print $1/100}'`
    set state_step = `echo $state_avgstep $state_smallstep $state_pctstep | awk '$2>$3{$1=$2} $1<$3{$1=$3} {print $1}'`
endif
echo "$state_lo $state_hi $state_step" >! state_stats.txt
set samples = `cat state_stats.txt | awk '{step=$3;range=$2-$1+4*step; print (range/step+1)}'`

# landmarks for output
echo " $out_states " |\
 awk -F "[, ]" '{for(i=1;i<=NF;++i) print $i}' |\
 awk 'NF!=0{print $1,"-"}' |\
 sort -u |\
 sort -g >! out_states.txt


rm -f state_vs_xyzoB.txt
echo "atom $atom  from $pdbfiles"

awk -v atom=$atom '! /^ATOM|^HETAT/{next} {++n}\
    n==atom{print;exit}' $refpdb >! id.txt

# presets for PDB file format
set params = ( x y z o B )
set offsets = ( 31 39 47 55 61 )
set widths  = (  8  8  8  6  6 )
set xyzoB = xyzoB
if("$atom" == "0") then
    # do unit cell
    set params = ( a b c al be ga )
    set offsets = ( 7 16 25 34 41 48 )
    set widths  = ( 9 9 9 7 7 7 )
    set xyzoB = abcalbega
    echo "CRYST1" >! id.txt
endif

foreach nX ( `seq 1 $#params` )
    set X = $params[$nX]
    set offset = $offsets[$nX]
    set width = $widths[$nX]
 
    rm -f state_vs_${X}.txt smooth_vs_${X}.txt
    foreach n ( `seq 1 $#pdbfiles` )
        set pdbfile = $pdbfiles[$n]
        set state = $in_states[$n]

        echo "FIRST $atom $offset $width $state" |\
        egrep -h "^ATOM|^HETAT|^CRYST1|^FIRST" - id.txt $pdbfile |&\
        awk 'NR==1{atom=$2;offset=$3;width=$4;state=$5;next}\
          {id=altid=substr($0,12,15)} \
           # include blank conf as belonging to all confs \
           substr(id,6,1)!=" "{altid=substr(id,1,5)" "substr(id,7)}\
           NR==2{id0=id;altid0=altid;next}\
          id==id0 || id==altid0 || atom==0 && /^CRYST1/{\
             print state,substr($0,offset,width);exit}' |\
        tee -a state_vs_${X}.txt >>& $logfile
    end
    # light restraints to average value?
    set default_value = `awk '{++n;sum+=$2} END{if(n) print sum/n}' state_vs_${X}.txt`
    if("$X" == "o") set default_value = 0

    cat state_vs_${X}.txt out_states.txt |\
    awk '! seen[$1]{print;++seen[$1]}' |\
    tee landmarks.txt |\
    awk -v def=$default_value -v def_wt=$def_wt \
       '$2=="-"{$2=def;$3=def_wt} {print}' |\
    cat >! defaults.txt

    sort -g defaults.txt |\
    cat state_stats.txt - |\
    awk -v ext_wt=$ext_wt 'NR==1{lo=$1;hi=$2;step=$3;next}\
        $3+0==0{$3=1} {print} \
        NR==2{$1=lo-step;$3=ext_wt;print;\
              $1=lo-2*step;$3=ext_wt;print;}\
          END{$1=hi+step;$3=ext_wt;print;\
              $1=hi+2*step;$3=ext_wt;print;}' |\
    sort -g >! smoothme.txt
    
    gnuplot << EOF >>& $logfile
    set samples $samples
    c(x) = column(x)
    set table 'table'
    set terminal table
    set output 'table'
    plot 'smoothme.txt' using 1:2:(c(3)*$weight) smooth acsplines
EOF

    awk -v step=$state_step '$3=="i"{print $1-step/100,$2,$3}' table |\
    sort -g - landmarks.txt |\
    awk '$3=="i"{v=$2;next}\
         {print $1,$2,v}' >! smooth.txt

    # enforce occupancy clipping
    if("$X" == "o") then
        echo "$min_occ $max_occ" |\
        cat - smooth.txt |\
        awk 'NR==1{min_occ=$1;max_occ=$2;next}\
            $3+0<min_occ{$3=min_occ}\
            $3+0>max_occ{$3=max_occ}\
            {print}' |\
        cat >! clipped.txt
        mv clipped.txt smooth.txt
    endif

    foreach state ( `awk '{print $1}' out_states.txt` )
        set data = `egrep "^${state} " smooth.txt | awk '{print $2,$3}'`
        if($#data != 2) set data = "- -"
        echo "$state $atom $nX $data $X $xyzoB" | tee -a smooth_vs_${X}.txt >>& $logfile
    end
    set rmsvar = `awk '$4!="-"{++n;sumd=($4-$5)^2} END{if(n)print sqrt(sumd/n)}' smooth_vs_${X}.txt`
    echo "$atom $nX $X $rmsvar $data" | tee -a atom_noise.txt
end

if(! $?DEBUG ) then
    rm -f smooth.txt smoothme.txt table state_vs_?.txt
    #rm -f id.txt
    rm -f states.txt in_states.txt out_states.txt state_stats.txt 
    rm -f landmarks.txt defaults.txt
endif

exit:

if( $?BAD ) then
    echo "ERROR: $BAD"
    exit 9
endif

exit

