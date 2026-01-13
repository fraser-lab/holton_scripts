#! /bin/tcsh -f
#
#        measure XDS data processing performance on current system          -James Holton 11-27-18
#
#        download test data if its not already here
#        download XDS if its not already here
#
# requires:
# wget or curl
# gcc
#
# get latest version of this script from:
# wget http://smb.slac.stanford.edu/~holton/xds_bench/xds_bench.com
# chmod a+x xds_bench.com
# ./xds_bench.com
#

set dlurl = http://smb.slac.stanford.edu/~holton/xds_bench/
set dlurl = https://bl831.als.lbl.gov/~jamesh/benchmarks/xds/

# probe machine for defaults
set uname = `uname`
set test = `uname -a | egrep "86_64|ARM64_" | wc -l`
if("$test" != "1") then
    set BAD = "XDS only runs on 64-bit machines.  Sorry."
    goto exit
endif

if("$uname" == "Linux") then
    set CPUs = `awk '/^processor/' /proc/cpuinfo | wc -l`
    set chips = `awk '/^physical/' /proc/cpuinfo | sort -u | wc -l`
    set cores_per_chip = `awk '/^core/' /proc/cpuinfo | sort -u | wc -l`
    set cores = `echo $chips $cores_per_chip | awk '{print $1*$2}'`
    set threads_per_chip = `awk '/^siblings/{print $NF;exit}' /proc/cpuinfo`
    set threads_per_core = `echo $threads_per_chip $cores_per_chip | awk '{threads=int($1/$2+0.001)} threads==0{threads=1} {print threads}'`
    echo "found $CPUs CPUs on $chips chips with $cores_per_chip cores each ($threads_per_core threads/core)"

    set freeCPUs = `w | cat - /proc/cpuinfo - | awk '/^processor/{++p} /load aver/{l=$(NF-2)+0} END{print int(p-l+0.5)}'`
    echo "found $freeCPUs free CPUs"

    # guestimate optimal memory usage
    set freemem = `free -m | awk '/^Mem:/{print $4+$7;exit}'`
    set totalmem = `free -m | awk '/^Mem:/{print $2;exit}'`
    echo "$totalmem MB RAM total"
endif
if("$uname" == "Darwin") then
    # for some reason on macs: don't have wget
    alias wget 'curl -o `basename \!:1` \!:1'

    set cores = `sysctl hw.physicalcpu | awk '/^hw./{print $NF}'`
    set CPUs = `sysctl hw.logicalcpu | awk '/^hw./{print $NF}'`
    set threads = `echo $CPUs $cores | awk '{threads=int($1/$2+0.001)} threads==0{threads=1} {print threads}'`
    set chips = 1
    set cores_per_chip = `echo $cores $chips | awk '{print $1/$2}'`
    set threads_per_chip = `echo $threads $chips | awk '{print $1/$2}'`
    set threads_per_core = `echo $threads $cores | awk '{print $1/$2}'`
    echo "found $CPUs CPUs in $cores cores ($threads threads/core)"

    set freeCPUs = `w | awk -v p=$CPUs '/load aver/{l=$(NF-2)+0} END{print int(p-l+0.5)}'`
    echo "found $freeCPUs free CPUs"

    # guestimate optimal memory usage
    set totalmem = `sysctl hw.memsize | awk '/hw.memsize/ && $NF+0>0{print $NF/1024/1024;exit}'`
    echo "$totalmem MB RAM available"
endif
if(! $?CPUs) then
    ehco "WARNING: unknown platform! "
endif
echo ""

# smart defaults
set itrs = 3
set DELPHI = 50
set njobs = default
set nprocs = default
set imgcache = default
set user_njobs = ""
set user_nprocs = ""
set user_imgcache = ""
set max_imgcache = `echo $CPUs $totalmem | awk '{print int($2/20/$1/2)}' | awk '$1<51{$1=51} {print}'`
set stages = ""
set default_njobs = $cores
set default_nprocs = $DELPHI
set default_stages = ( XYCORR INIT COLSPOT IDXREF DEFPIX INTEGRATE CORRECT )

if("$freeCPUs" != "$CPUs") then
    echo "WARNING: not useful to run benchmarks on computers that are busy (${freeCPUs}/${CPUs} CPUs free)."
endif

# allow user override of parameters
foreach arg ( $* )
    if("$arg" =~ *=*) then
        set values = `echo $arg | awk -F "=" '{print $2}' | awk 'BEGIN{RS=","} {print}'`
        if("$values" =~ *-*) then
            set range = `echo $values | awk -F "-" '{for(i=$1+0;i<=$2+0;++i)print i}'`
            if("$range" != "") set values = ( $range )
        endif
        if("$arg" =~ *job* ) then
            set user_njobs = ( $values )
        endif
        if("$arg" =~ *proc* ) then
            set user_nprocs = ( $values )
        endif
        if("$arg" =~ *cache*) then
            set user_imgcache = ( $values )
        endif
        if("$arg" =~ itr*) then
            set itrs = `echo $arg | awk -F "=" '{print $2+0}'`
        endif
        if("$arg" =~ delphi*) then
            set DELPHI = `echo $arg | awk -F "=" '{print $2+0}'`
        endif
    endif
    if("$arg" =~ stage=*) then
        set test = `echo $arg | awk -F "=" '$2~/^XYCOR|^INIT|^COLSPOT|^IDXREF|^DEFPIX|^INTEGRATE|^CORRECT/{print $2}' | awk 'BEGIN{RS=","} {print}'`
        if("$test" != "") set stages = ( $stages $test )
    endif
    if("$arg" == "skip") then
        set SKIP_DONE
    endif
    if("$arg" == "send") then
        unset NOSEND
        goto send
    endif
    if("$arg" == "nosend") then
        set NOSEND
    endif
end

# fill in defaults
if("$stages" == "") set stages = ( $default_stages )
if("$user_njobs" != "") set njobs = ( $user_njobs )
if("$user_nprocs" != "") set nprocs = ( $user_nprocs )
if("$user_imgcache" != "") set imgcache = ( $user_imgcache )

set test = `echo $imgcache $max_imgcache | awk '{print ($1+0 > $2+0)}'`
if($test) then
    echo "WARNING: imgcache=$imgcache using too much memory may crash this machine. "
    echo "         continuing anyway..."
endif

if("$*" == "") then
    cat << EOF

you may also want to try changing defaults for xds parameters:
 max_number_of_jobs, max_number_of_processes and images_in_cache with:
$0 njobs=${njobs} nprocs=${nprocs} imgcache=${imgcache}

EOF
endif

set test = `df -k . | tail -n 1 | awk 'NF>4{print ( $(NF-2)/1024/1024 > 5 )}'`
if("$test" != "1" && ! -e ./data/core_360.cbf) then
    echo "WARNING: need at least 5 GB of free space for test data in `pwd`"
    echo "proceeding anyway..."
    sleep 5
endif


set test = `ls ./XDS-*/xds_par |& grep -vi match | wc -l`
if("$test" == "1") then
    echo "using local copy of XDS:./XDS-*/xds_par "
    set path = ( `pwd`/XDS-*/ $path )
    rehash
endif

# check if xds_par is installed
mkdir -p empty
cd empty
set test = `xds_par |& egrep "CANNOT OPEN OR READ XDS.INP" | wc -l`
cd ..
rmdir empty

if ("$test" != "1") then
    echo " need xds binary! "
    set prefix = XDS-INTEL64_Linux_x86_64
    if($uname == Darwin) set prefix = XDS-OSX_64
    if(! -e ${prefix}.tar.gz) then
        wget https://xds.mr.mpg.de/${prefix}.tar.gz
    endif
    tar xzvf ${prefix}.tar.gz 
    set path = ( `pwd`/$prefix $path )
    rehash
endif

mkdir -p empty
cd empty
set test = `xds_par |& egrep "CANNOT OPEN OR READ XDS.INP" | wc -l`
cd ..
rmdir empty
if ("$test" != "1") then
    set BAD = "unable to find xds_par binary."
    goto exit
endif


set images = `ls -l data/core_*.cbf |& awk '$5>6000000' |& wc -l`
if($images != 360) then
    echo "need to generate test data."
    if(! -x ./get_test_data.com) then
        wget ${dlurl}/get_test_data.com
        chmod a+x get_test_data.com
    endif
    ./get_test_data.com
endif
set images = `ls -l data/core_*.cbf |& awk '$5>6000000' |& wc -l`
if($images != 360) then
    set BAD = "test data generation failed."
    goto exit
endif

# see if image is binary identical to expectations
set test = `md5sum data/core_001.cbf | awk '{print ($1 == "6dc7547f81cf7ada0b69db3e91cd0792" )}'`
if("$test" != "1") set test = `sum data/core_001.cbf | awk '{print ($1 == "29901" || $1 == "36476" || $1 == "28925" || $1 == "53125")}'`
if("$test" != "1" && ! $?MD5CHECKED) then
        md5sum data/core_001.cbf
        sum data/core_001.cbf
        set BAD = "data/core_001.cbf does not match expected MD5 sum. corrupted?"
        echo "WARNING: $BAD"
        echo "continue anyway? [Yn]"
        set test = "no"
        # ignore if output is not a terminal
        test -t 1
        if(! $status) then
            set test = ( $< )
        endif
        if( "$test" !~ n*) goto skip_md5
        goto exit
    endif
endif
skip_md5:

if (! -x ./log_timestamp.tcl) then
    cat << EOF >! log_timestamp.tcl
#! /bin/sh
# use tclsh in the path \
exec tclsh "\$0" "\$@"
#
#       encode a logfile stream with time stamps
#
#
#
set start [expr [clock clicks -milliseconds]/1000.0]

while { ! [eof stdin] } {
    set line "[gets stdin]"
    puts "[clock format [clock seconds] -format "%a %b %d %T %Z %Y"] [clock seconds] [format "%12.3f" [expr [clock clicks -milliseconds]/1000.0 - \$start]] \$line"

}
EOF
    chmod a+x log_timestamp.tcl
endif


set test = `echo | ./log_timestamp.tcl | awk '{print ( $7+0>1000000 )}' | tail -n 1`
if("$test" == "1") then
    set timestamper = ./log_timestamp.tcl
else
    echo "WARNING: tcl does not work, resorting to low-precision timer"
    # hmm.  Maybe tcl not installed
    cat << EOF >! timer.csh
#! /bin/csh -f
#
set starttime = \`date +%s\`

cat

set endtime = \`date +%s\`
@ deltaT = ( \$endtime - \$starttime )
echo "\`date\` \$endtime \$deltaT"
EOF
    chmod a+x timer.csh
    set timestamper = ./timer.csh
endif


cat << EOF >! XPARM.XDS
 XPARM.XDS    VERSION May 1, 2016  BUILT=20160617
     1        0.0000    1.0000  1.000000  0.000000  0.000000
       1.000000       0.000000       0.000000       1.000000
    96     78.8947     78.8947     36.7982  90.000  90.000  90.000
      26.969313      37.058762     -64.215904
     -12.864723      69.634857      34.783112
      34.056843      -0.661887      13.921180
         1      2463      2527    0.172000    0.172000
    1264.000000    1232.000000     400.114624
       1.000000       0.000000       0.000000
       0.000000       1.000000       0.000000
       0.000000       0.000000       1.000000
         1         1      2463         1      2527
    0.00    0.00    0.00  1.00000  0.00000  0.00000  0.00000  1.00000  0.00000
EOF

cat << EOF >! XDS.INP
DETECTOR= PILATUS MINIMUM_VALID_PIXEL_VALUE=0 OVERLOAD= 1048576  !PILATUS
NAME_TEMPLATE_OF_DATA_FRAMES=data/test_?????.cbf
DATA_RANGE= 1 3600
SPOT_RANGE= 1 3600
BACKGROUND_RANGE= 1 $DELPHI
STARTING_ANGLE= 0
OSCILLATION_RANGE= 1                    
DELPHI= $DELPHI

ORGX= 1264 ORGY= 1232
DETECTOR_DISTANCE= 400
X-RAY_WAVELENGTH= 1                      

INCLUDE_RESOLUTION_RANGE=50 0
TRUSTED_REGION=0.0 1.99
VALUE_RANGE_FOR_TRUSTED_DETECTOR_PIXELS=6000. 30000.
SIGNAL_PIXEL=4
MINIMUM_NUMBER_OF_PIXELS_IN_A_SPOT=3
NX= 2463 NY= 2527 QX= 0.172 QY= 0.172
SENSOR_THICKNESS= 0.001
DIRECTION_OF_DETECTOR_X-AXIS=1 0 0
DIRECTION_OF_DETECTOR_Y-AXIS=0 1 0
FRACTION_OF_POLARIZATION=0.98
POLARIZATION_PLANE_NORMAL=0 1 0
ROTATION_AXIS= 1 0 0
INCIDENT_BEAM_DIRECTION= 0 0 1

UNIT_CELL_CONSTANTS= 78.87 78.87 36.788 90 90 90
SPACE_GROUP_NUMBER= 96
FRIEDEL'S_LAW=TRUE ! '

NUMBER_OF_IMAGES_IN_CACHE= $imgcache
JOB= $stages
EOF


echo ""
onintr sendstats

foreach itr ( `seq 1 $itrs` ) 

 foreach stage ( $stages )

  # user may want to auto-scan
  set all_njobs = ( $njobs )
  if("$njobs" == "scan") then
     set all_njobs = `echo $CPUs | awk '{for(i=1;i<=$1*1.2;++i)print i}'`
  endif
  set all_nprocs = ( $nprocs )
  if("$nprocs" == "scan") then
     set max = `echo $CPUs | awk '{print int($1*1.2)}'`
     if($max > 99) set max = 99
     set all_nprocs = `echo $max | awk '{for(i=1;i<=$1;++i)print i}'`
  endif
  set all_imgcache = ( $imgcache )
  if("$imgcache" == "scan") then
     set all_imgcache = `echo $max_imgcache | awk '{for(i=1;i<=$1*1.2;++i)print i}'`
  endif

  # option to raster around previous optimum
  if("$njobs" == "opt" && -e timings.txt) then
      set opt_jobs  = `sort -g timings.txt | awk -v stage=$stage '$2==stage && $1+0>1 && $5+0>0{print $5;exit}' `
      echo "previous optimum jobs for $stage : $opt_jobs"
      if("$opt_jobs" != "") then
          set all_njobs = `echo $opt_jobs | awk '{for(i=$1-2;i<=$1+2;++i)print i}' | awk '$1>0{print}'`
      endif
  endif
  if("$nprocs" == "opt" && -e timings.txt) then
      set opt_procs = `sort -g timings.txt | awk -v stage=$stage '$2==stage && $1+0>1 && $6+0>0{print $6;exit}' `
      echo "previous optimum procs for $stage : $opt_procs"
      if("$opt_procs" != "") then
          set all_nprocs = `echo $opt_procs | awk '{for(i=$1-2;i<=$1+2;++i)print i}' | awk '$1>0 && $1<100{print}'`
      endif
  endif
  if("$imgcache" == "opt" && -e timings.txt) then
      set opt_cache = `sort -g timings.txt | awk -v stage=$stage '$2==stage && $1+0>1 && $7+0>0{print $7;exit}' `
      echo "previous optimum cache for $stage : $opt_cache"
      if("$opt_cache" != "") then
          set all_imgcache = `echo $opt_cache | awk '{for(m=$1*0.8;m<=$1*1.2;m*=1.1)print int(m)}' | awk '$1>0{print}'`
      endif
  endif

  if("$stage" =~ {XYCORR,INIT,IDXREF,DEFPIX,CORRECT}) then
      # these steps never have more than one JOB
      set all_njobs = 1
  endif

  # safety catch if above fails
  if("$all_njobs" == "opt") set all_njobs = auto
  if("$all_nprocs" == "opt") set all_nprocs = auto
  if("$all_imgcache" == "opt") set all_imgcache = default
 
  echo "selecting njobs from: $all_njobs"
  echo "selecting nproc from: $all_nprocs"
  echo "selecting img_cache from: $all_imgcache" 


  # generate parameter lists
  echo "" >!  tempfile_params.txt
  foreach j ( $all_njobs )
   foreach p ( $all_nprocs )
    foreach i ( $all_imgcache )

     if( "$user_njobs" == "scan" && "$user_nprocs" == "scan" ) then
         # skip things that would be more than twice the number of logical cpus, or less than half
         set test = `echo $j $p $cores | awk '{print ($1*$2 > 2*$3 || $1*$2 < $3/2)}'`
         if($test) then
             echo "skipping $j jobs, $p processors/job, and $i images in cache"
             continue
         endif
     endif
     echo "${j}_${p}_${i}" >> tempfile_params.txt
    end
   end
  end

  # scramble the order of parameters
  cat tempfile_params.txt |\
  awk 'NF>0{print rand(),$0}' | sort -g | awk '{print $NF}' >! tempfile.txt
  mv tempfile.txt tempfile_params.txt
  set paramsets = `cat tempfile_params.txt`
  echo "$#paramsets combinations of parameters"

  echo "measuring raw disk transfer rate"
  set xferrate = `( tar cf - data/core* | dd bs=10485760 of=/dev/null ) |& awk 'END{gsub("[)(]","");print $(NF-1),$NF}'`
  echo "$xferrate"

  foreach pset ( $paramsets )

   set pset_njobs     = `echo $pset | awk -F "_" '{print $1}'`
   set pset_nprocs    = `echo $pset | awk -F "_" '{print $2}'`
   set pset_imgcache  = `echo $pset | awk -F "_" '{print $3}'`

   echo "running xds_par $stage  with $pset_njobs jobs, $pset_nprocs processors/job, and $pset_imgcache images in cache"



   egrep -v "^JOB|^MAXIMUM_NUMBER|^NUMBER_OF_IMA" XDS.INP >! temp.txt
   mv temp.txt XDS.INP
   echo "JOB= $stage" >> XDS.INP

   set jobs = $pset_njobs
   set proc = $pset_nprocs
   set icache = $pset_imgcache
   # Holton empirical best choices
   if("$jobs" == "auto") then
       set jobs = $chips
       if("$stage" =~ {COLSPOT,INTEGRATE}) set jobs = $cores
   endif
   if("$stage" =~ {XYCORR,INIT,IDXREF,DEFPIX,CORRECT}) then
       # these steps never have more than one JOB
       set jobs = 1
   endif
   # balance jobs with procs...
   if("$pset_nprocs" == "auto") then
       #set proc = $DELPHI
       set proc = `echo $CPUs $jobs | awk '{print int(1.2*$1/$2+0.001)}'`
       if("$proc" == "" || "$proc" == 0) set proc = 1
   endif

   # avoid disasters
   set test = `echo $jobs $proc $CPUs | awk '{print ( $1*$2 > 1.5*$3 )}'`
   if($test && "$stage" == "INTEGRATE") then
        echo "skipping $jobs jobs and $proc procs because there are only $CPUs CPUs"
        continue
   endif

   if(-e timings.txt && $?SKIP_DONE) then
       set test = `echo $stage $jobs $proc $icache $DELPHI | cat - timings.txt | awk 'NR==1{s=$1;j=$2;p=$3;i=$4;d=$5;next} $2==s && $5==j && $6==p && $7==i && $8==d{print}' | wc -l`
echo "GOTHERE: $test   $stage $pset_njobs $pset_nprocs $pset_imgcache $DELPHI"
       if($test >= $itrs) then
           echo "already did: $pset_njobs jobs, $pset_nprocs processors/job, and $pset_imgcache images in cache"
           continue
       endif
   endif

   # restore any backups, in case previous runs failed
   if(-e X-CORRECTIONS.cbf.bak) mv X-CORRECTIONS.cbf.bak X-CORRECTIONS.cbf
   if(-e GAIN.cbf.bak)          mv GAIN.cbf.bak GAIN.cbf
   if(-e SPOT.XDS.bak)          mv SPOT.XDS.bak SPOT.XDS
   if(-e XPARM.XDS.bak)         mv XPARM.XDS.bak XPARM.XDS
   if(-e BKGPIX.cbf.bak)        mv BKGPIX.cbf.bak BKGPIX.cbf
   if(-e INTEGRATE.HKL.bak)     mv INTEGRATE.HKL.bak INTEGRATE.HKL
   # make sure output file is not there, so we can detect if run fails
   if("$stage" == "XYCORR"    && -e X-CORRECTIONS.cbf) mv X-CORRECTIONS.cbf X-CORRECTIONS.cbf.bak
   if("$stage" == "INIT"      && -e GAIN.cbf)          mv GAIN.cbf GAIN.cbf.bak
   if("$stage" == "COLSPOT"   && -e SPOT.XDS)          mv SPOT.XDS SPOT.XDS.bak
   if("$stage" == "IDXREF"    && -e XPARM.XDS)         mv XPARM.XDS XPARM.XDS.bak
   if("$stage" == "DEFPIX"    && -e BKGPIX.cbf)        mv BKGPIX.cbf BKGPIX.cbf.bak
   if("$stage" == "INTEGRATE" && -e INTEGRATE.HKL)     mv INTEGRATE.HKL INTEGRATE.HKL.bak
   if("$stage" == "CORRECT"   && -e GXPARM.XDS)        rm -f GXPARM.XDS 

   echo "specifying $jobs jobs, $proc procs, $icache images/cache for $stage"

   set test = `echo $jobs | awk '{print ($1+0>0)}'`
   if($test) then
       echo "MAXIMUM_NUMBER_OF_JOBS= $jobs" >> XDS.INP
   endif
   set test = `echo $proc | awk '{print ($1+0>0)}'`
   if($test) then
       echo "MAXIMUM_NUMBER_OF_PROCESSORS= $proc" >> XDS.INP
   endif
   if("$icache" != "default" && "$icache" != "auto") then
       echo "NUMBER_OF_IMAGES_IN_CACHE= $icache" >> XDS.INP
   endif

   # actual XDS run! 
   xds_par |& $timestamper >! ${stage}.log

   set actual_jobs = $jobs
   set actual_proc = $proc
   set actual_cache = $icache
   # recover defaults
   if("$stage" == "INTEGRATE" || "$stage" == "INIT") then
       set test = `awk '/CACHE/{print $NF}' ${stage}.LP`
       if("$test" != "") set actual_cache = $test
       set test = `awk '/PROCESSORS/ && /USING/{print $2}' ${stage}.LP | tail -n 1`
       if("$test" != "") set actual_proc = $test
       set test = `awk '/MAXIMUM_NUMBER_OF_PROCESSORS=/{print $2}' ${stage}.LP | tail -n 1`
       if("$test" != "") set actual_proc = $test
       set test = `awk '/number of forked/{print $NF}' ${stage}.LP | tail -n 1`
       if("$test" != "") set actual_jobs  = $test
   endif
   if("$stage" == "COLSPOT") then
       set test = `awk '/NUMBER OF PROCESSES RUNNING IN PARALLEL/{print $NF}' ${stage}.LP | tail -n 1`
       if("$test" != "") set actual_proc = $test
        set test = `awk '/JOBS/ && $NF+0>0{print $NF}' ${stage}.LP`
       if("$test" != "") set actual_jobs = $test
   endif

   # now extract run time
   set runtime = "n/d"
   if(-s ${stage}.log)    set runtime = `tail -n 1 ${stage}.log | awk '{print $8}'`
   if("$runtime"  == ""  && -s ${stage}.LP) set runtime = `awk '/wall-clock/' ${stage}.LP | awk '$4+0>0{print $4} $5+0>0{print $5} $7+0>0{print $7}' | sort -g | tail -n 1`
   if("$runtime" == "") set runtime = "n/d"
   if("$stage" == "XYCORR"    && ! -s X-CORRECTIONS.cbf) set runtime = "n/d"
   if("$stage" == "INIT"      && ! -s GAIN.cbf)          set runtime  = "n/d"
   if("$stage" == "COLSPOT"   && ! -s SPOT.XDS)          set runtime   = "n/d"
   if("$stage" == "IDXREF"    && ! -s XPARM.XDS)         set runtime = "n/d"
   if("$stage" == "DEFPIX"    && ! -s BKGPIX.cbf)        set runtime   = "n/d"
   if("$stage" == "INTEGRATE" && ! -s INTEGRATE.HKL)     set runtime = "n/d"
   if("$stage" == "CORRECT"   && ! -s GXPARM.XDS)        set runtime  = "n/d"

   echo "runtime  stage   rawxfer rate  jobs procs imgcache delphi"
   echo "${runtime}s $stage    $xferrate   $actual_jobs $actual_proc $actual_cache $DELPHI" | tee -a timings.txt
  end
  # end param loop
 end
 # end stage loop
end
# end itr loop

sendstats:
onintr
# now that CPUs are hot, collect machine data
uname -a >! machineinfo.txt
set uname = `awk '{print $1;exit}' machineinfo.txt`
uptime >> machineinfo.txt

# try to heat up at least one CPU
awk 'BEGIN{for(i=1;i<1e6;++i)exp(i/1e6)}' 

# now quickly read the cpuinfo
if("$uname" == "Linux" || "$uname" =~ CYGWIN*) then
    cat /proc/cpuinfo >> machineinfo.txt
    free -m >> machineinfo.txt
endif
if("$uname" == "Darwin") then
    sysctl hw >> machineinfo.txt
endif
set test = `cat machineinfo.txt | wc -l | awk '{print ($1<10)}'`
if($test) then
    echo "WARNING: unknown platform! "
endif

# make this cumulative
touch results.txt
sort -u timings.txt | awk '{print "runtime: ",$0}' >> results.txt
hostname >> results.txt
awk '! seen[$0]{print;++seen[$0]}' machineinfo.txt >> results.txt


send:
if($?NOSEND) then
    echo "please send in your results by running: $0 send"
    goto exit
endif
echo "sending results..."
set sanskrit = `gzip -c results.txt | base64 | awk '{gsub("/","_");gsub("[+]","-");printf("%s",$0)}'`
if("$sanskrit" != "") then
    curl https://bl831.als.lbl.gov/xds_bench$sanskrit > /dev/null
endif
if($status || "$sanskrit" == "") then
    echo "ERROR: please send file results.txt manually to JMHolton@lbl.gov"
endif


exit:

if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif

exit


#end





# run this on test machine
tcsh
set uname = `uname`
if("$uname" == "Darwin") then
    alias wget 'curl -o `basename \!:1` \!:1'
endif
foreach root ( /dev/shm/ /tmp/${USER} /local/${USER} `pwd` )
set dir = ${root}/xds_bench/
mkdir -p $dir
if(! -w $dir) continue
cd $dir
set test = `df -k . | tail -n 1 | awk 'NF>4{print ( $(NF-2)/1024/1024 > 5 )}'`
echo "$dir $test"
if("$test" != "1") continue
cd $dir
break
end
pwd
rm -f ./xds_bench.com
wget http://smb.slac.stanford.edu/~holton/benchmarks/xds/xds_bench.com
chmod a+x xds_bench.com
./xds_bench.com nosend itrs=5


rsync -av --exclude '*.HKL' --exclude '*.txt' dataserver4:/dev/shm/xds_bench/ ./
cp ~/projects/benchmarks/xds/xds_bench.com .
./xds_bench.com nosend itrs=5
./xds_bench.com nosend jobs=scan
./xds_bench.com nosend proc=scan
./xds_bench.com nosend cache=scan
cp -f results.txt ~/projects/benchmarks/xds/results_`hostname -s`.txt





# run this back home
grep "File name too long" /var/log/httpd/error_log | tail -n 1 |\
awk '{for(i=1;i<=NF;++i)if(length($i)>100)print substr($i,2)}' |\
base64 --decode |\
tee -a ~jamesh/projects/benchmark_xds/raw_results.txt

su - jamesh
cd ~jamesh/projects/benchmark_xds/
sort -u results.txt raw_results.txt | sort -k7g |\
awk '$6+0>0 && $7+0>9 && $8+0>0' |\
awk '{mchn=substr($0,index($0,$9))} \
  ! seen[mchn]{++seen[mchn];print}' | tee tempfile.txt 
mv tempfile.txt results.txt



foreach i ( `seq 1 7` )
sort -k${i}g timings.txt | head -n 1
end


# more thorough
set CPUs = `awk '/^processor/' /proc/cpuinfo | wc -l`
foreach jobs ( `seq 1 $CPUs | shuffle.com` )
    set nproc = `echo $CPUs $jobs | awk '{print int(2*$1/$2)}'`
    set test = `awk -v j=$jobs -v p=$nproc '$10==j && $11==p' timings.txt | wc -l`
    if($test >= 3) continue
    ./xds_bench.com njobs=$jobs nproc=$nproc nosend
    cp -f results.txt ~/projects/benchmarks/xds/results_`hostname -s`.txt
end
set jobs = `awk '{print $1+$2+$3+$4+$5+$6+$7,$0}' timings.txt | sort -g | awk '{print $(NF-2);exit}'`
set nproc = `awk '{print $1+$2+$3+$4+$5+$6+$7,$0}' timings.txt | sort -g | awk '{print $(NF-1);exit}'`
foreach imgcache ( 10 20 50 100 120 150 200 )
    ./xds_bench.com njobs=$jobs nproc=$nproc imgcache=$imgcache nosend
    cp -f results.txt ~/projects/benchmarks/xds/results_`hostname -s`.txt
end


echo -n >! results.txt
sort -u timings.txt | awk '{print "runtime: ",$0}' >> results.txt
hostname >> results.txt
cat machineinfo.txt >> results.txt
cp -f results.txt ~/projects/benchmarks/xds/results_`hostname -s`.txt



set CPUs = 144
rm -f params.txt
foreach mem ( 2 6 10 20 50 100 150 180 )
foreach jobs ( `seq 1 160` )
foreach proc ( `seq 1 160` )
set test = `echo $jobs $proc $CPUs | awk '{print ($1*$2 > 2*$3 || $1*$2 < $3/2)}'`
if($test) continue
echo "${mem}_${jobs}_${proc}" | tee -a params.txt
end
end
end
foreach params ( `cat params.txt | shuffle.com` )
   set mem  = `echo $params | awk -F "_" '{print $1}'`
   set jobs = `echo $params | awk -F "_" '{print $2}'`
   set proc = `echo $params | awk -F "_" '{print $3}'`
   set test = `egrep "^$jobs $proc $mem " integ_timing.txt | wc -l`
   if($test) continue

   cat << EOF >> XDS.INP
NUMBER_OF_IMAGES_IN_CACHE= $mem
MAXIMUM_NUMBER_OF_JOBS= $jobs
MAXIMUM_NUMBER_OF_PROCESSORS= $proc
EOF
   xds_par > /dev/null
   set timing = `tail -n 1 INTEGRATE.LP | awk '{print $(NF-1)}'`
   echo "$jobs $proc $mem $timing" | tee -a integ_timing.txt
end


