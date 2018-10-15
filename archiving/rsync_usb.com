#! /bin/tcsh -f
#
#	Put files onto a USB device as fast as we can
#
#
set datadir = "$1"
set usbthing = "$2"
set alreadythere = "$3"

if("$usbthing" == "") set usbthing = /media/usbthing/

set compressor = "cat"
if("$3" == "compress") set compressor = "pigz -c"
if("$3" == "nocompress") set compressor = "cat"

set ext = ".gz"
if("$compressor" == "cat") set ext = ""

set tempdir = /dev/shm/${USER}_$$
mkdir -p $tempdir

onintr umount

set mountpoint = `( cd "$usbthing" ; pwd ) | awk '{gsub("/$","");print}'`
while ( "$mountpoint" != "" && "$mountpoint" != "/" && "$mountpoint" != "." )
    set test = `df | awk -v mountpoint="$mountpoint" '{mp=substr($0,index($0,"%")+2)} mp==mountpoint{print}' | wc -l`
    if("$test" == "0") then
        set mountpoint = `dirname "$mountpoint"`
    else
        break
    endif
end
if("$mountpoint" == "" || "$mountpoint" == "/" || "$mountpoint" == "." ) then
    set mountpoint = `echo $usbthing | awk -F "/" '{print "/"$2"/"$3}'`
endif

echo "mount point is: $mountpoint"

# check if we won't be able to unmount
set test = `pwd | egrep "^$mountpoint" | wc -l`
if( $test ) then
    set BAD = "do not run rsync_usb.com in the mount point directory. Wont be able to unmount. "
    goto exit
endif

set test = `df | awk -v mountpoint="$mountpoint" '{mp=substr($0,index($0,"%")+2)} mp==mountpoint{print}' | wc -l`
while ( "$test" == "0" ) 
    echo "mounting $mountpoint"
    mount $mountpoint
    set test = `df | awk -v mountpoint="$mountpoint" '{mp=substr($0,index($0,"%")+2)} mp==mountpoint{print}' | wc -l`
    if("$test" == "0") then
        echo "you may need to unplug and plug in the USB again..."
        sleep 2
    endif
end
echo "$mountpoint is mounted"

if(! -d "${usbthing}") then
    mkdir -p $usbthing
    if($status) then
        set BAD = "unable to create $usbthing"
        goto exit
    endif
endif

set fstype = `grep $mountpoint /etc/mtab | awk '{print $3}' | tail -1`
echo "file system is: $fstype"


while ( 1 )

find ${datadir} -type f -printf "%T@ %s %P\n"  | sort -g >! ${tempdir}/here.txt
find "${usbthing}" -type f -printf "%T@ %s %P\n" | sort -g | awk '{gsub(".gz$","");print $0,"THERE"}' >! ${tempdir}/there.txt

if(-e "$alreadythere") then
    echo "accounting for files in $alreadythere"
    awk '{gsub(".gz$","");print $0,"THERE"}' $alreadythere >> ${tempdir}/there.txt
endif

set here = `cat ${tempdir}/here.txt | wc -l`
set there = `cat ${tempdir}/there.txt | wc -l`
echo "$here here, $there there"

# head ${tempdir}/there.txt ${tempdir}/here.txt
cat ${tempdir}/there.txt ${tempdir}/here.txt |\
awk '$NF=="THERE" && $2!=0{++there[$3];epoch[$3]=$1;rsize[$3]=$2}\
     $NF=="THERE"{next};\
   ! there[$3]{print}' >! ${tempdir}/2bxferred_name.txt
set count = `cat ${tempdir}/2bxferred_name.txt | wc -l`
awk '{sum+=$2} END{print sum}' ${tempdir}/2bxferred_name.txt |\
  awk '$1>1024{$1/=1024;suff="k"}\
       $1>1024{$1/=1024;suff="M"}\
       $1>1024{$1/=1024;suff="G"}\
       $1>1024{$1/=1024;suff="T"}\
    {printf("%.1f %sB\n",$1,suff)}' >! ${tempdir}/size.txt
set size = `cat ${tempdir}/size.txt`
echo "$count files ($size) still need to be transferred based on names"

cat ${tempdir}/there.txt ${tempdir}/here.txt |\
awk '$NF=="THERE" && $2!=0{++there[$3];epoch[$3]=$1;rsize[$3]=$2;next}\
     $NF=="THERE"{next};\
   ! there[$3] || sqrt((rsize[$3]-$2)**2)>2{print}' >! ${tempdir}/2bxferred_size.txt
set count = `cat ${tempdir}/2bxferred_size.txt | wc -l`
awk '{sum+=$2} END{print sum}' ${tempdir}/2bxferred_size.txt |\
  awk '$1>1024{$1/=1024;suff="k"}\
       $1>1024{$1/=1024;suff="M"}\
       $1>1024{$1/=1024;suff="G"}\
       $1>1024{$1/=1024;suff="T"}\
    {printf("%.1f %sB\n",$1,suff)}' >! ${tempdir}/size.txt
set size = `cat ${tempdir}/size.txt`
echo "$count files ($size) still need to be transferred based on size"

cat ${tempdir}/there.txt ${tempdir}/here.txt |\
awk '$NF=="THERE" && $2!=0{++there[$3];epoch[$3]=$1;rsize[$3]=$2}\
     $NF=="THERE"{next}\
   ! there[$3] || sqrt((epoch[$3]-$1)**2)>2{print}' >! ${tempdir}/2bxferred_time.txt
set count = `cat ${tempdir}/2bxferred_time.txt | wc -l`
awk '{sum+=$2} END{print sum}' ${tempdir}/2bxferred_time.txt |\
  awk '$1>1024{$1/=1024;suff="k"}\
       $1>1024{$1/=1024;suff="M"}\
       $1>1024{$1/=1024;suff="G"}\
       $1>1024{$1/=1024;suff="T"}\
    {printf("%.1f %sB\n",$1,suff)}' >! ${tempdir}/size.txt
set size = `cat ${tempdir}/size.txt`
echo "$count files ($size) still need to be transferred based on time"

cp -p ${tempdir}/2bxferred_time.txt ${tempdir}/2bxferred.txt 

set xferred = 0
set xferstart = `msdate.com | awk '{print $NF}'`
set filesleft = $count
foreach file ( `awk '{print $NF}' ${tempdir}/2bxferred.txt` )

    echo -n "$file   "
    set parent = `dirname $file`
    if(! -d "${usbthing}/$parent") then
        mkdir -p "${usbthing}/$parent"
        if($status) then
            set BAD = "making directory ${usbthing}/$parent"
            break
        endif
        touch -r ${datadir}/$parent "${usbthing}/$parent"
        if($status) then
            set BAD = "date-stamping directory ${usbthing}/$parent"
            break
        endif
    endif

    $compressor ${datadir}/$file >! "${usbthing}/${file}${ext}"
    if($status) then
        if(-e ${datadir}/$file) then
            set BAD = "writing ${usbthing}/${file}${ext}"
            break
        else
            echo "oh, it went away..."
            break
        endif
    endif
    touch -r ${datadir}/$file "${usbthing}/${file}${ext}"
    if($status) then
        set BAD = "date-stamping ${usbthing}/${file}${ext}"
        break
    endif

    set size = `ls -l ${datadir}/$file | awk '{print $5}'`
    set xferred = `echo $xferred $size | awk '{print $1+$2}'`
    @ count = ( $count - 1 )
    set xfertime = `msdate.com $xferstart | awk '{print $NF}'`
    set xferrate = `echo $xferred $xfertime | awk '$2>0{print $1/$2/1024}' | awk 'BEGIN{s="k"} $1>1024{$1/=1024;s="M"} {printf("%.1f %sB/s",$1,s)}'`
    set eta = `echo $count $xferred $size $xfertime | awk '$3*$2*$4>0{print "puts [clock format [expr int([clock seconds] + "$1/($2/$3/$4)")]]"}' | tclsh`
    echo -n "$xferrate  $count    $eta"

    if( $count % 1000 == 0) then
        echo ""
        echo "synching..."
        sync
    endif
    echo -n "\r"
end
echo "syncing..."
sync
set xfertime = `msdate.com $xferstart | awk '{print $NF}'`
set xferrate = `echo $xferred $xfertime | awk '$2+0>0{print $1/$2/1024}' | awk 'BEGIN{s="k"} $1>1024{$1/=1024;s="M"} {printf("%.1f %sB/s",$1,s)}'`
echo "net: $xferrate"

if($?BAD) then
    echo "ERROR: $BAD"
    echo "you probably need to do something about this."
    sleep 300
    unset BAD
endif

#rsync -av --progress --modify-window=1 $datadir /media/usbthing/

echo "are you done?  press <Ctrl>-C if you are"
sleep 10


end


umount:
onintr
rm -rf ${tempdir}

set test = `df | awk -v mountpoint=$mountpoint '$NF==mountpoint' | wc -l`
while ( $test )
  echo "flushing buffers..."
  sync
  set xfertime = `msdate.com $xferstart | awk '{print $NF}'`
  set xferrate = `echo $xferred $xfertime | awk '{print $1/$2/1024}' | awk 'BEGIN{s="k"} $1>1024{$1/=1024;s="M"} {printf("%.1f %sB/s",$1,s)}'`
  echo "net: $xferrate"
  onintr
  echo "if you don't want to unmount $mountpoint on $HOST, press Ctrl-C now! "
  foreach s ( `seq 10 -1 1` )
      echo $s
      sleep 1
  end
  onintr umount
  echo "cleanly unmounting usb drive..."
  sudo umount $mountpoint
  set test = `df | awk -v mountpoint=$mountpoint '$NF==mountpoint' | wc -l`
  if( $test ) then
    echo "ARGH.  umount didn't work."
    echo "potentially offending programs that need to die: "
    /usr/sbin/lsof | grep " $mountpoint" | grep -v "^grep" | grep -v "^lsof" | tee ${tempdir}/killthese.txt
    set badpids = `grep -v " $$ " ${tempdir}/killthese.txt | awk '{print $2}'`
    if( "$badpids" != "" ) then
        echo "kill them? "
        set in = ( $< )
        if( "$in" != "no" ) then
            echo "killing $badpids"
            kill -9 $badpids
        endif
    endif
    sleep 5
  endif
end
echo "unmounted! you may unplug your drive."
onintr
rm -rf ${tempdir}

sleep 600

exit:
rm -rf ${tempdir}
if( $?BAD ) then
    echo "ERROR: $BAD"
    exit 9
endif

exit






format firewire drive with fat32

# delete any existing partitions and make the new partition type "b" Win95:FAT32
fdisk /dev/sde
d
n
p
1
<default>
<default>
t
b
w


mkdosfs -F 32 -n usbthing -v /dev/sdc1

sync

# unplug it





# use a GPT table instead


parted /dev/sde
mklabel gpt
mkpart primary fat32 0% 100%
print
quit

partprobe 

mkdosfs -F 32 -S 4096 -n usbthing -v /dev/sde1

sync
# unplug it




# use UFS format


parted /dev/sde
mklabel gpt
mkpart primary  0% 100%
print
quit

partprobe 

mkudffs  /dev/sde1

sync
# unplug it



