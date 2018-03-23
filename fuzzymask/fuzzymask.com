#! /bin/tcsh -f
#
#   create a solvent mask by averaging over refmac-derived solvent masks
#   with PDB file coordinates randomly shifted using B and occupancy
#
#   put any extra refmac keywords into a file "refmac_opts.txt" before running
#
#   run with no arguments for online help
#
#   James Holton 3-18-18
#
#========================================================================
#    Setting defaults :

# bulk solvent density
set ksol = 0.35824

# solvent mask options
set vdwprobe = 1.1
set ionprobe = 0.5
set rshrink = 0.5

# number of refmac cycles to refine
set ncyc_ideal = 5
set ncyc_data = 0

# number of CPUs to use
set seeds = 500
set user_CPUs  = auto

# output map file
set mapout = "fuzzysolvent.map"

# output mtz file
set mtzout  = "Fparted.mtz"


if($#argv != 0) goto Setup
# come back at after_Setup:

#========================================================================
#    help message if run with no arguments
Help:
cat << EOF 
usage: $0 refme.pdb refme.mtz [ligand.cif] \
     [ksol=${ksol}] \
     [vdwprobe=$vdwprobe] [ionprobe=$ionprobe] [rshrink=$rshrink] \
     [ncyc_ideal=${ncyc_ideal}] [ncyc_data=${ncyc_data}]\
     [seeds=${seeds}] [CPUs=auto] \
     [${mapout}] [output=${mtzout}]

where:
refme.pdb      PDB file being refined
refme.mtz      data being used in refinement
ligand.cif     is the geometry info for any ligands (must be one file)

ksol           electron density of bulk solvent far from any protein in electrons/A^3
vdwprobe       van der Walls radius for solvent probe in refmac 
ionprobe       vdwprobe for ionic species in refmac 
rshrink        mask shrinkage radius in refmac 

ncyc_ideal     number of geometry minimization refmac cycles to perform after jiggling (default: $ncyc_ideal)
ncyc_data      number of refmac cycles vs x-ray data to perform before taking solvent mask (default: $ncyc_data)

seeds          number of random maps to average (default: $seeds)
CPUs           number of CPUs to use in parallel (default: $user_CPUs)
$mapout map file of the fuzzy solvent to output in CCP4 format
$mtzout    partial structure factors for solvent added to input mtz file

EOF

exit 9


# read command line, set defaults, deploy scripts
after_Setup:

cat << EOF
generating $seeds random masks with:
vdwprobe=$vdwprobe ionprobe=$ionprobe rshrink=$rshrink
ncyc_ideal=${ncyc_ideal} ncyc_data=${ncyc_data}
ksol=${ksol}
mapout=${mapout} mtzout=${mtzout}
EOF

set fastmp = ${tempfile}
if("$CLUSTER" != "") set fastmp = "./"

# create the refmac script we will run on each cpu
cat << EOF-script >! refmac_cpu.com
#! /bin/tcsh -f
set seed = \$1

# mess it up
cat $pdbfile |\
jigglepdb.awk -v shift=byB -v seed=\$seed |\
awk '! /^ATOM|^HETAT/ || substr(\$0,55)+0>0' >! ${tempfile}seed\${seed}.pdb

# clean it up
refmac5 xyzin ${tempfile}seed\${seed}.pdb $LIBSTUFF \
        xyzout ${tempfile}seed\${seed}minimized.pdb << EOF-refmac
vdwrestraints 0
$otheropts
refi type ideal
ncyc $ncyc_ideal
EOF-refmac

# forget it if it didnt minimize
if(! -e ${tempfile}seed\${seed}minimized.pdb) then
    cp ${tempfile}seed\${seed}.pdb ${tempfile}seed\${seed}minimized.pdb
endif

# map it out
refmac5 xyzin ${tempfile}seed\${seed}minimized.pdb \
        xyzout ${tempfile}seed\${seed}out.pdb \
        hklin $mtzfile  $LIBSTUFF \
    mskout ${fastmp}mask_seed\${seed}.map \
    hklout ${tempfile}seed\${seed}out.mtz << EOF-refmac
vdwrestraints 0
$otheropts
ncyc $ncyc_data
solvent vdwprobe $vdwprobe ionprobe $ionprobe rshrink $rshrink
solvent yes
EOF-refmac

# signal that map is ready
touch ${fastmp}seed\${seed}done.txt

EOF-script
chmod a+x refmac_cpu.com


# launch refmac jobs in parallel
if("$CLUSTER" == "TORQ") goto launch_qsub

set jobs = 0
set lastjobs = 0
foreach seed ( `seq 1 $seeds` )
    if($quiet) then
        ( ./refmac_cpu.com $seed >! ${tempfile}seed${seed}.log & ) >& /dev/null
    else
        ./refmac_cpu.com $seed >! ${tempfile}seed${seed}.log &
    endif

    # now make sure we dont overload the box
    @ jobs = ( $jobs + 1 )
    while ( $jobs >= $CPUs )
        sleep 4
        set jobs = `ps -fu $USER | grep refmac_cpu.com | grep -v grep | wc -l`
        if($jobs != $lastjobs && ! $quiet) echo "$jobs jobs running..."
        set lastjobs = $jobs
    end
end
#wait
goto sum_maps



# launch jobs on a torq cluster, like pxproc
launch_qsub:
set pwd = `pwd`
if(! $quiet) echo "submitting jobs..."
foreach seed ( `seq 1 $seeds` )
    qsub -e /dev/null -o ${tempfile}seed${seed}.log -d $pwd ./refmac_cpu.com -F "$seed" > /dev/null
end
goto sum_maps

sum_maps:
if(! $quiet) then
    echo "all jobs launched."
    if (! -e ${fastmp}seed1done.txt) echo "waiting for 1 to finish..."
endif
while (! -e ${fastmp}seed1done.txt)
#   ls -l ${fastmp}seed1done.txt
   sleep 1
end
while (! -s ${fastmp}mask_seed${seed}.map)
   sleep 2
end

# now start adding up the maps...
rm -f ${tempfile}sum.map
if(! $quiet) echo -n "summing maps: "
foreach seed ( `seq 1 $seeds` )
    if(! $quiet) echo -n "$seed "
    while(! -e ${fastmp}seed${seed}done.txt)
        sleep 3
        wait
    end
    if(! -e ${tempfile}sum.map) then
        cp -p ${fastmp}mask_seed${seed}.map ${tempfile}sum.map
        if(! $?debug) rm -f ${fastmp}mask_seed${seed}.map ${fastmp}seed${seed}done.txt
        continue
    endif
    echo maps add |\
    mapmask mapin1 ${fastmp}mask_seed${seed}.map mapin2 ${tempfile}sum.map \
       mapout ${tempfile}new.map >> $logfile
    if(! -e ${tempfile}new.map) then
        set BAD = "failed to make seed $seed "
        goto exit
    endif
    mv ${tempfile}new.map ${tempfile}sum.map
    if(! $?debug) then
        rm -f ${fastmp}mask_seed${seed}.map ${fastmp}seed${seed}done.txt
    endif
end
echo ""
# wait for SMP jobs
wait

# wait for queued jobs?


# final check.  Did it work
if(! -e ${tempfile}sum.map) then
    set BAD = "map summation failed"
    goto exit
endif

# put on the appropriate scale, and expand to cell
set max = `echo | mapdump mapin ${tempfile}sum.map | awk '/Maximum density/{print $NF}'`
set scale = `echo $ksol $max | awk '$2+0==0{print $1;exit} {print $1/$2}'`

set axis = "Z X Y"

reaxis:
# reorganize map for SFALL
mapmask mapin ${tempfile}sum.map mapout ${tempfile}ksol.map << EOF >> $logfile
scale factor $scale 0
xyzlim cell
AXIS $axis
EOF
if("$mapout" != "") then
    cp ${tempfile}ksol.map $mapout
    echo | mapdump mapin $mapout | grep density
    echo "solvent map: $mapout"
endif

# first one will crash?
echo "sfall..."
sfall mapin ${tempfile}ksol.map hklout ${tempfile}sfalled.mtz << EOF | tee -a ${tempfile}crash.log >> $logfile
mode sfcalc mapin
SFSG 1
resolution $reso
EOF

# try to recover from SFALL crash?
if(! -e ${tempfile}sfalled.mtz && ! $?newaxis) then
    # get the axis order that SFALL wants
    set newaxis = `awk '/Check Iuvw/{gsub("1","X");gsub("2","Y");gsub("3","Z");print $6,$7,$8}' ${tempfile}crash.log`
    if("$newaxis" != "$axis") then
        set axis = ( $newaxis )
        goto reaxis
    endif
endif

if(! -e ${tempfile}sfalled.mtz) then
    cat ${tempfile}crash.log
    set BAD = "SFALL failed"
    goto exit
endif

# combine with refinement mtz
echo "combining $mtzfile with Fpart PHIpart"
echo "" |\
mtzdump hklin $mtzfile |\
awk 'NF>10' | awk '$(NF-1)~/^[FQIP]$/{++n;print $NF" "}' |\
egrep -v "part" |\
awk '{++n;print "E"n"="$1}' >! ${tempfile}tokens.txt
set tokens = `cat ${tempfile}tokens.txt`

cad hklin1 $mtzfile hklin2 ${tempfile}sfalled.mtz \
    hklout ${tempfile}cadded.mtz << EOF >> $logfile
labin file 1 $tokens
labin file 2 E1=FC E2=PHIC
labou file 2 E1=Fpart E2=PHIpart
EOF
if(! -e ${tempfile}cadded.mtz) then
    set BAD = "failed to make $mtzout"
    goto exit
endif
mv ${tempfile}cadded.mtz $mtzout
if(-e $mtzout) then
    echo "output mtz file: $mtzout"
else
    set BAD = "failed to make $mtzout"
    goto exit
endif


cat << EOF
add this to refmac input:
LABIN  FPART1=Fpart PHIPART1=PHIpart
SCPART 1
SOLVENT NO
EOF


exit:

if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif

if($?debug) exit

rm -f ${tempfile}* >& /dev/null

exit




















#========================================================================
#    initial setup routines down here and out of the way
Setup:

# default file names
set pdbfile = ""
set mtzfile = ""
set libfile = ""

set quiet = 0

# pick temp filename location
set logfile = /dev/null
mkdir -p ${CCP4_SCR} >&! /dev/null
set tempfile = ${CCP4_SCR}/fuzzymask$$temp
if(-w /dev/shm/ ) then
    set tempfile = /dev/shm/fuzzymask$$temp
endif

# some platforms dont have these?
if(! $?USER) then
    setenv USER `whoami`
endif

#========================================================================
#    Reading command-line arguments:

foreach arg ( $* )
    if("$arg" =~ *.pdb) then
        if(! -e "$arg") then
            echo "ERROR: $arg does not exist"
            exit 9
        endif
        set pdbfile = "$arg"
        continue
    endif
    if("$arg" =~ *.map && "$arg" !~ *=*) then
        set mapout = "$arg"
    endif
    if("$arg" =~ *.mtz && "$arg" !~ *=*) then
        if(! -e "$arg") then
            echo "ERROR: $arg does not exist"
            exit 9
        endif
        set mtzfile = "$arg"
    endif
    if("$arg" =~ *.cif || "$arg" =~ *.lib) then
        if(! -e "$arg") then
            echo "ERROR: $arg does not exist"
            exit 9
        endif
        set libfile = "$arg"
    endif
    if("$arg" == debug) then
        set debug = 1
    endif
    if("$arg" == quiet) then
        set quiet = 1
    endif
    if("$arg" =~ ksol=*) set ksol = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ CPUs=*) set user_CPUs = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ seeds=*) set seeds = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ ncyc=*) set ncyc = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ vdwprobe=*) set vdwprobe = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ ionprobe=*) set ionprobe = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ rshrink=*) set rshrink = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ mtzout=*mtz) set mtzout = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ output=*mtz) set mtzout = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ mapout=*) set mapout = `echo $arg | awk -F "=" '{print $2}'`
    if("$arg" =~ pdbfile=*) set pdbfile = `echo $arg | awk -F "=" '{print $2}'`
end

# bug out here if we cant run
if(! $?CCP4_SCR) then
    set BAD = "CCP4 is not set up."
    goto exit
endif
if(! -e "$pdbfile") then
    echo "please specify an existing PDB file."
    goto Help
endif
if(! -e "$mtzfile") then
    echo "please specify an existing MTZ file."
    goto Help
endif


# examine the MTZ file
echo | mtzdump hklin $mtzfile >&! ${tempfile}mtzdump.txt
set reso = `awk '/Resolution Range/{getline;getline;print $6}' ${tempfile}mtzdump.txt`
if("$reso" == "") then
    echo "cannot read $mtzfile as mtz"
    goto Help
endif


# get cell dimensions and space group
set CELL = `awk '/CRYST1/{print $2,$3,$4,$5,$6,$7}' $pdbfile`
set pdbSG = `awk '/^CRYST/{print substr($0,56,12)}' $pdbfile | head -1`
if("$pdbSG" == "R 32") set pdbSG = "R 3 2"
if("$pdbSG" == "P 21") set pdbSG = "P 1 21 1"
if("$pdbSG" == "R 3 2" && $CELL[6] == 120.00) set pdbSG = "H 3 2"
set SG = `awk -v pdbSG="$pdbSG" -F "[\047]" 'pdbSG==$2{print;exit}' ${CLIBD}/symop.lib | awk '{print $4}'`
if("$SG" == R3 && $CELL[6] == 120.00) set SG = H3
if("$SG" == "") set SG = P1



# decide on a grid spacing
set default_res = `awk '/^REMARK   2 RESOLUTION/{print $4}' $pdbfile`
if("$default_res" == "") then
    set minB = `awk '/^ATOM/ || /^HETATM/{print substr($0, 61, 6)+0}' $pdbfile | sort -n | awk '{v[++n]=$1} END{print v[int(n/2)]}'`
    set default_res = `echo $minB | awk '$1>0{print 3*sqrt($1/80)}'`
endif
if("$default_res" == "") set default_res = 1.5

# reduce default resolution if it will overload sftools
set megapoints = `echo $CELL $default_res | awk '{printf "%d", 27*($1 * $2 * $3)/($NF*$NF*$NF)/900000}'`
if("$megapoints" > 100) then
    set default_res = `echo $CELL 100000000 | awk '{print ($1*$2*$3*27/$NF)^(1/3)}'`
endif
if("$reso" == "") then
    set reso = $default_res
endif




# system setup
set CLUSTER = ""
set pwd = `pwd`
set uname = `uname`

if("$uname" == "Linux") then
    set CPUs = `awk '/^processor/' /proc/cpuinfo | wc -l`
    set chips = `awk '/^physical/' /proc/cpuinfo | sort -u | wc -l`
    set cores_per_chip = `awk '/^core/' /proc/cpuinfo | sort -u | wc -l`
    set cores = `echo $chips $cores_per_chip | awk '{print $1*$2}'`
    set threads_per_chip = `awk '/^siblings/{print $NF;exit}' /proc/cpuinfo`
    set threads_per_core = `echo $threads_per_chip $cores_per_chip | awk '{threads=int($1/$2+0.001)} threads==0{threads=1} {print threads}'`
#    echo "found $CPUs CPUs on $chips chips with $cores_per_chip cores each ($threads_per_core threads/core)"

    set freeCPUs = `w | cat - /proc/cpuinfo - | awk '/^processor/{++p} /load aver/{l=$(NF-2)+0} END{print int(p-l+0.5)}'`
#    echo "found $freeCPUs free CPUs"

    # guestimate optimal memory usage
    set freemem = `free -m | awk '/^Mem:/{print $4+$7;exit}'`
    set totalmem = `free -m | awk '/^Mem:/{print $2;exit}'`
#    echo "$totalmem MB RAM total"
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
#    echo "found $CPUs CPUs in $cores cores ($threads threads/core)"

    set freeCPUs = `w | awk -v p=$CPUs '/load aver/{l=$(NF-2)+0} END{print int(p-l+0.5)}'`
#    echo "found $freeCPUs free CPUs"

    # guestimate optimal memory usage
    set totalmem = `sysctl hw.memsize | awk '/hw.memsize/ && $NF+0>0{print $NF/1024/1024;exit}'`
#    echo "$totalmem MB RAM available"
endif
if(! $?CPUs) then
    ehco "WARNING: unknown platform! "
endif
# allow user to override
if("$user_CPUs" == "cores") set user_CPUs = $cores
if("$user_CPUs" == "free") set user_CPUs = $freeCPUs
if("$user_CPUs" == "all") set user_CPUs = $CPUs
if("$user_CPUs" != "auto") set CPUs = $user_CPUs
echo "will use $CPUs CPUs"


# test for torq cluster
cat << EOF >! test$$.csh
#! /bin/tcsh -f
touch \$1
EOF
chmod a+x test$$.csh
qsub -e /dev/null -o /dev/null -d $pwd test$$.csh -F "testtorq$$.txt" >& /dev/null
set queued = 1
while ( $queued )
    sleep 0.1
    set queued = `qstat |& awk '$(NF-1)~/[RQ]/{print}' | wc -l`
end
if(-e ${pwd}/testtorq$$.txt) then
    echo "detected torq-based cluster"
    set CLUSTER = TORQ
endif
rm -f test$$.csh testtorq$$.txt >& /dev/null


# change things for debug mode
if($?debug) then
    set tempfile = ./tempfile
    set logfile = fuzzymask_debug.log
endif




# see if there is a user-provided parameter file
set otheropts
if(-e refmac_opts.txt) then
    set otheropts = "@refmac_opts.txt"
endif
set LIBSTUFF
if(-e "$libfile") set LIBSTUFF = "LIBIN $libfile"
if(-e atomsf.lib) set LIBSTUFF = "$LIBSTUFF ATOMSF ./atomsf.lib"








# requires jigglepdb.awk
set path = ( $path `dirname $0` . )


# deploy scripts?
set test = `echo | jigglepdb.awk | awk '/jiggled by dXYZ/{print 1}'`
if("$test" == "1") goto after_Setup

echo "deploying jigglepdb.awk ..."
cat << EOF-script >! jigglepdb.awk
#! `which awk` -f
#! /bin/awk -f
#
#
#        Jiggles a pdb file's coordinates by some random value
#        run like this:
#
#        jigglepdb.awk -v seed=2343 -v shift=1.0 old.pdb >! jiggled.pdb
#         (use a different seed when you want a different output file)
#
BEGIN {

    if(! shift)  shift = 0.5
    if(! Bshift) Bshift = shift
    if(shift == "byB") Bshift = 0
    if(shift == "Lorentz") Bshift = 0
    pshift = shift
    shift_opt = shift
    if(pshift == "byB") pshift = "sqrt(B/8)/pi"
    if(pshift == "LorentzB") pshift = "Lorentzian B"
    if(seed) srand(seed+0)
    if(! keepocc) keepocc=0
    if(! distribution) distribution="gaussian";

    pi=4*atan2(1,1);

    # random number between 1 and 0 to select conformer choices
    global_confsel=rand();

    print "REMARK jiggled by dXYZ=", pshift, "dB=", Bshift
    print "REMARK random number seed: " seed+0
}

/^ATOM/ || /^HETATM/ {

    if(debug) print tolower(\$0)

#######################################################################################
    electrons = substr(\$0, 67,6)
    XPLORSegid = substr(\$0, 73, 4)            # XPLOR-style segment ID
    split(XPLORSegid, a)
    XPLORSegid = a[1];
    Element = substr(\$0, 67)

    Atomnum= substr(\$0,  7, 5)+0
    Element= substr(\$0, 13, 2);
    Greek= substr(\$0, 15, 2);
    split(Element Greek, a)
    Atom   = a[1];
    Conf   = substr(\$0, 17, 1)                # conformer letter
    Restyp = substr(\$0, 18, 3)
    Segid  = substr(\$0, 22, 1)            # O/Brookhaven-style segment ID
    Resnum = substr(\$0, 23, 4)+0
    X      = substr(\$0, 31, 8)+0
    Y      = substr(\$0, 39, 8)+0
    Z      = substr(\$0, 47, 8)+0
    Occ    = substr(\$0, 55, 6)+0
    Bfac   = substr(\$0, 61, 6)+0
#   rest   = substr(\$0, 67)
    ATOM   = toupper(substr(\$0, 1, 6))
#######################################################################################

    if(shift_opt=="byB" || shift_opt=="LorentzB"){
        # switch on "thermal" shift magnitudes
        shift=sqrt(Bfac/8)/pi*sqrt(3);

        # randomly "skip" conformers with occ<1
        if(Occ+0<1){
            # remember all occupancies
            if(conf_hi[Conf,Segid,Resnum]==""){
                conf_lo[Conf,Segid,Resnum]=cum_occ[Segid,Resnum]+0;
                cum_occ[Segid,Resnum]+=Occ;
                conf_hi[Conf,Segid,Resnum]=cum_occ[Segid,Resnum];
            }
        }
    }
    # pick a random direction
#    norm = 0;
#    while(! norm)
#    {
#        dX = rand()-0.5;
#        dY = rand()-0.5;
#        dZ = rand()-0.5;
#        # calculate its length
#        norm = sqrt(dX*dX + dY*dY + dZ*dZ);
#    }
#    
#    # pick a (gaussian) random distance to move
#    dR = gaussrand(shift)
    
    # move the atom
#    X += dR * dX / norm;
#    Y += dR * dY / norm;
#    Z += dR * dZ / norm;
    if(shift_opt == "LorentzB")
    {
        distribution = "Lorentz"
    }
    if(distribution == "Lorentz")
    {
        dX = lorentzrand(shift/sqrt(3));
        dY = lorentzrand(shift/sqrt(3));
        dZ = lorentzrand(shift/sqrt(3));
    }
    if(distribution == "gaussian" || distribution == "Gauss")
    {
        dX = gaussrand(shift/sqrt(3));
        dY = gaussrand(shift/sqrt(3));
        dZ = gaussrand(shift/sqrt(3));
    }
    if(distribution == "uniform")
    {
        dR=2
        while(dR>1)
        {
            dX = (2*rand()-1);
            dY = (2*rand()-1);
            dZ = (2*rand()-1);
            dR = sqrt(dX^2+dY^2+dZ^2);
        }
        dX *= shift;
        dY *= shift;
        dZ *= shift;
    }

    X += dX;
    Y += dY;
    Z += dZ;

    # pick a random shift on B-factor
    if(Bshift+0>0) Bfac += gaussrand(Bshift)
    if(Oshift+0>0) Occ += gaussrand(Oshift)
    
    # use same occopancy for given conformer
    if(! keepocc && conf_hi[Conf,Segid,Resnum]!=""){
        # use same random number for all conformer choices
        confsel = global_confsel;
        # unless occupancies do not add up
        if(Conf==" "){
            # save this for later?
            confsel = rand();
        }
        Occ = 0;
        # atom only exists if it falls in the chosen interval
        lo=conf_lo[Conf,Segid,Resnum];
        hi=conf_hi[Conf,Segid,Resnum];
        if(lo < confsel && confsel <= hi) Occ=1;
    }

    # now print out the new atom
    printf("%s%8.3f%8.3f%8.3f %5.2f%6.2f%s\\n",substr(\$0,1,30),X,Y,Z,Occ,Bfac,substr(\$0,67));        
}

# also print everything else
! /^ATOM/ && ! /^HETATM/ {print}



#######################################################################################
# function for producing a random number on a gaussian distribution
function gaussrand(sigma){
    if(! sigma) sigma=1
    rsq=0
    while((rsq >= 1)||(rsq == 0))
    {
        x=2.0*rand()-1.0
        y=2.0*rand()-1.0
        rsq=x*x+y*y
    }
    fac = sqrt(-2.0*log(rsq)/rsq);
    return sigma*x*fac
}

# function for producing a random number on a Lorentzian distribution
function lorentzrand(fwhm){
    if(! fwhm) fwhm=1

    return fwhm/2*tan(pi*(rand()-0.5))
}

function tan(x){
    return sin(x)/cos(x)
}
EOF-script
chmod a+x jigglepdb.awk


goto after_Setup



