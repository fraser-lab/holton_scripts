#! /bin/tcsh -f
#
#	measure dials data processing performance on current system
#
#	download test data if its not already here
#   download DIALS if it is not already installed
#
# requires:
# wget or curl
# gcc
#
# get latest version of this script from:
# wget http://smb.slac.stanford.edu/~holton/dials_bench/dials_bench.com
# chmod a+x dials_bench.com
# ./dials_bench.com
#

set dlurl = http://bl831.als.lbl.gov/~jamesh/benchmarks/dials/
#set dlurl = http://smb.slac.stanford.edu/~holton/benchmarks/dials/

# probe machine for defaults
set uname = `uname`

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
set nprocs = default
set user_nprocs = ""
set stages = ""
set default_nprocs = $cores



if("$freeCPUs" != "$CPUs") then
    echo "WARNING: not useful to run benchmarks on computers that are busy (${freeCPUs}/${CPUs} CPUs free)."
endif

# allow user override of parameters
foreach arg ( $* )
    if("$arg" =~ *=*) then
        if("$arg" =~ *proc* ) then
            set nprocs = `echo $arg | awk -F "=" '{print $2}' | awk 'BEGIN{RS=","} {print}'`
        endif
        if("$arg" =~ itr*) then
            set itrs = `echo $arg | awk -F "=" '{print $2+0}'`
        endif
    endif
    if("$arg" == "send") then
        unset NOSEND
        goto send
    endif
    if("$arg" == "nosend") then
        set NOSEND
    endif
end

if("$*" == "") then
    cat << EOF

you may also want to try changing defaults for dials parameters:
 nproc=${nprocs}

EOF
endif

set test = `df -k . | tail -n 1 | awk 'NF>4{print ( $(NF-2)/1024/1024 > 5 )}'`
if("$test" != "1" && ! -e ./data/core_360.cbf) then
    echo "WARNING: need at least 5 GB of free space for test data in `pwd`"
    echo "proceeding anyway..."
    sleep 5
endif



# check if dials is installed
set test = `dials.version |& egrep "DIALS" | wc -l`

if ("$test" == "1") goto checkimages

# need to install dials
set platform = linux-x86_64
if($uname == Darwin) set platform = macosx
rm -f dials-*/
wget https://dials.github.io/installation.html
set url = `awk 'BEGIN{RS="\""} /^https/ && /tar/{print}' installation.html | grep $platform | head -n 1`
set file = `echo $url | awk -F "/" '{print $NF}'`
if(! -r "$file") wget $url
tar xf $file

cd dials-installer
./install --prefix=../
cd ..
rm -rf dials-installer
source dials-*/dials_env.csh 

# see if all that was worth it...
set test = `dials.version |& egrep "DIALS" | wc -l`

if ("$test" != "1") then
    set BAD = "please manually install DIALS first ! "
    goto exit
endif
dials.version >&! version.log
set progversion = `cat version.log`

checkimages:
set images = `ls -l data/core_*.cbf |& awk '$5>6000000' |& wc -l`
if($images != 360) then
    echo "need to generate test data."
    if(! -x ./get_test_data.com) then
        wget ${dlurl}/get_test_data.com
        chmod a+x get_test_data.com
    endif
    ./get_test_data.com
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

echo ""
echo "running dials with nproc: $nprocs "
echo "nproc     rawxfer rate   import find index refine integ export"

foreach nproc ( $nprocs )

if("$nproc" == "default") set nproc = $default_nprocs

foreach itr ( `seq 1 $itrs` ) 

#echo "measuring raw disk transfer rate"
set xferrate = `( tar cf - data/ | dd bs=10485760 of=/dev/null ) |& awk 'END{gsub("[)(]","");print $(NF-1),$NF}'`
#echo "$xferrate"

dials.version >&! version.log
set progversion = `cat version.log`

set datablock = datablock.json
set datablock = imported_experiments.json
set datablock = imported.expt
set indexed   = experiments.json
set indexed   = indexed_experiments.json
set indexed   = indexed.expt
set refined   = experiments.json
set refined   = refined_experiments.json
set refined   = refined.expt
set integrated = integrated_experiments.json
set integrated = integrated.expt
set strongpickle = strong.pickle
set strongpickle = strong.refl
set indexedpickle = indexed.pickle
set indexedpickle = indexed.refl
set refinedpickle = refined.pickle
set refinedpickle = refined.refl
set integratedpickle = integrated.pickle
set integratedpickle = integrated.refl
set outputmtz  = integrated.mtz

rm -f $datablock
dials.import template=data/test_\#\#\#\#\#.cbf                       |&  $timestamper >! import.log
if(! -s $datablock) set datablock = datablock.json
if(! -s $datablock) set datablock = imported.expt
if(! -s $datablock) then
    rm -f import.log
    set BAD = "import failed"
    goto exit
endif
rm -f $strongpickle
dials.find_spots $datablock nproc=$nproc                         |& $timestamper >! findspots.log
if(! -s $strongpickle) set strongpickle = strong.pickle
if(! -s $strongpickle) then
    rm -f findspots.log
    set BAD = "find_spots failed"
    goto exit
endif
rm -f $indexedpickle
dials.index $datablock $strongpickle space_group=P43212          |& $timestamper >! index.log
if(! -s $indexedpickle) set indexedpickle = indexed.pickle
if(! -s $indexedpickle) then
    rm -f index.log
    set BAD = "index failed"
    goto exit
endif
if(! -s $indexed ) set indexed   = experiments.json 
if(! -s $indexed ) set indexed   = indexed.expt 
rm -f $refinedpickle
dials.refine $indexed $indexedpickle                                |& $timestamper >! refine.log
if(! -s $refinedpickle) then
    rm -f refine.log
    set BAD = "refine failed"
    goto exit
endif
if(! -s $refined ) set refined   = refined_experiments.json
if(! -s $refined ) set refined   = refined.expt 
rm -f $integratedpickle
dials.integrate $refined $refinedpickle nproc=$nproc |& $timestamper >! integrate.log
if(! -s $integratedpickle) set integratedpickle = integrated.pickle
if(! -s $integratedpickle) set integratedpickle = integrated.refl
if(! -s $integratedpickle) then
    rm -f integrate.log
    set BAD = "integrate failed"
    goto exit
endif
if(! -s $integrated ) set integrated   = integrated_experiments.json
if(! -s $integrated ) set integrated   = integrated.expt 
rm -f $outputmtz
dials.export $integrated $integratedpickle           |& $timestamper >!  export.log
if(! -s $outputmtz) set outputmtz = integrated.mtz
if(! -s $outputmtz) then
    rm -f export.log
    set BAD = "export failed"
    goto exit
endif

set progversion = `cat version.log`
set importtime = `awk 'END{print $8}' import.log`
set findtime = `awk '/Time Taken:/{print $NF}' dials.find_spots.log`
set indextime = `awk 'END{print $8}' index.log`
set refinetime = `awk '/Total time taken:/{print $NF}' dials.refine.log`
set integtime = `awk '/Total time taken:/{print $NF}' dials.integrate.log`
set exporttime = `awk 'END{print $8}' export.log`

if("$findtime" == "") set findtime = `awk 'END{print $8}' findspots.log`
if("$refinetime"  == "") set refinetime = `awk 'END{print $8}' refine.log`
if("$integtime" == "") set integtime = `awk 'END{print $8}' integrate.log`

if("$importtime"  == "") set importtime = "n/d"
if("$findtime" == "") set findtime = "n/d"
if("$indextime"  == "") set indextime = "n/d"
if("$refinetime"  == "") set refinetime = "n/d"
if("$integtime" == "") set integtime = "n/d"
if("$exporttime"  == "") set exporttime = "n/d"

echo "$nproc      $xferrate     ${importtime}s ${findtime}s ${indextime}s ${refinetime} ${integtime}s ${exporttime}s  $progversion" |\
   tee -a timings.txt

 end
 # end of nproc loop
end
# end of itr loop

sendstats:
onintr
# now that CPUs are hot, collect machine data
uname -a >! machineinfo.txt
set uname = `awk '{print $1;exit}' machineinfo.txt`
uptime >> machineinfo.txt

# try to heat up at least one CPU
awk 'BEGIN{for(i=1;i<1e7;++i)exp(i/1e6)}' 

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
    curl https://bl831.als.lbl.gov/dials_bench$sanskrit > /dev/null
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
foreach root ( /dev/shm/ /tmp/${USER} `pwd` )
set dir = ${root}/dials_bench/
mkdir -p $dir
if(! -w $dir) continue
cd $dir
set test = `df -k . | tail -n 1 | awk 'NF>4{print ( $(NF-2)/1024/1024 > 8 )}'`
echo "$dir $test"
if("$test" != "1") continue
cd $dir
break
end
pwd
rm -f ./dials_bench.com
wget http://bl831.als.lbl.gov/~jamesh/benchmarks/dials/dials_bench.com
chmod a+x dials_bench.com

cp ~jamesh/projects/benchmarks/dials/dials_bench.com .

set CPUs = `awk '/^processor/' /proc/cpuinfo | wc -l`
foreach nproc ( `seq 1 $CPUs | shuffle.com` )

     ./dials_bench.com nproc=$nproc

end
./dials_bench.com send




# run this back home
grep "File name too long" /var/log/httpd/error_log | tail -n 1 |\
awk '{for(i=1;i<=NF;++i)if(length($i)>100)print substr($i,2)}' |\
base64 --decode |\
tee -a ~jamesh/projects/benchmark_dials/raw_results.txt

su - jamesh
cd ~jamesh/projects/benchmark_dials/
sort -u results.txt raw_results.txt | sort -k7g |\
awk '$6+0>0 && $7+0>9 && $8+0>0' |\
awk '{mchn=substr($0,index($0,$9))} \
  ! seen[mchn]{++seen[mchn];print}' | tee tempfile.txt 
mv tempfile.txt results.txt




set CPUs = `awk '/^processor/' /proc/cpuinfo | wc -l`

foreach nproc ( `seq 1 $CPUs | shuffle.com` )

     ./dials_bench.com nproc=$nproc
     cp results.txt ~/projects/benchmarks/dials/results_`hostname -s`.txt

end







