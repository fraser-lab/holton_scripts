#! /bin/tcsh -f
#
#
#
set dir = "$1"
set pretend = "$2"

if(! -d "$dir") then
    set dir = /data/mailinsaxs/
endif
if("$pretend" == "pretend") setenv PRETEND


set CPUs = `grep proc /proc/cpuinfo | wc -l`

#cd /local
if(! -x ./headerdate.com) then
    cp ~jamesh/archiving/headerdate.com .
endif
if(! -x ./headerdate.com) then
    set BAD = "cannot find headerdate.com"
    goto exit
endif


echo "finding all cbf and img files in $dir ..."
find $dir -name .snapshot -prune -o \
    \( -name '*.cbf' -o -name '*.img' \) -printf "%T@ %p\n" |\
sort -g >! image_files.txt

# fix stupid filenames
awk 'NF>2' image_files.txt |\
awk '{idx=index($0,$1);\
      oldfile=substr($0,idx);\
      gsub(" ","_");\
      newfile=substr($0,idx);\
   print "mv \""oldfile"\"",newfile}' |\
tee change_stupidnames.txt

set test = `cat change_stupidnames.txt | wc -l`
if($test) then
    set BAD = "files have stupid names: run change_stupidnames.txt"
    goto exit
endif


update_header_dates:

touch image_header_dates.txt

# dont bother with things we know dont have dates
#append_file_date.com image_header_dates.txt
egrep -v "dose_slice_sim" image_header_dates.txt >&! new.txt
mv new.txt image_header_dates.txt
egrep -v "dose_slice_sim" image_files.txt >&! new.txt
mv new.txt image_files.txt

# put current file date stamps alongside header date stamp
echo "updating date-stamp file: image_header_dates.txt "
cat image_files.txt image_header_dates.txt |\
awk -v dir=$dir '{file=substr($0,index($0,dir));epoch=$1}\
  NF==2{diskepoch[file]=epoch;next}\
  diskepoch[file]!=""{$(NF-1)=diskepoch[file];}\
  ! seen[file]{print;++seen[file]}' |\
cat >! new.txt
wc -l image_header_dates.txt new.txt | grep -v total
mv new.txt image_header_dates.txt

# cull headerdate info with no file on disk
echo "culling images that do not exist on disk "
cat image_files.txt image_header_dates.txt |\
awk -v dir=$dir '{file=substr($0,index($0,dir))}\
  NF==2{++exist[file];next}\
  exist[file]{print}' |\
cat >! existing_image_header_dates.txt
wc -l image_header_dates.txt existing_image_header_dates.txt | grep -v total
mv existing_image_header_dates.txt image_header_dates.txt

# find images with no info on header date
echo "finding images that need their headers probed "
set parthing = image_header_dates
cat ${parthing}.txt image_files.txt |\
awk -v dir=$dir '{file=substr($0,index($0,dir))}\
  NF==2 && ! seen[file]{print file} {++seen[file]}' |\
awk '{print "./headerdate.com \""$0"\""}' |\
cat >! ${parthing}_todo.txt
wc -l ${parthing}_todo.txt

# see if there is any work to do
set test = `cat ${parthing}_todo.txt | wc -l`
if($test < 100) then
    head -n 3 ${parthing}_todo.txt
    set file = `awk '{gsub("\"","");print $NF}' ${parthing}_todo.txt`
    if("$file" != "") then
        ls -l $file
        ls -lL $file
    endif
    echo "doing ${parthing}"
    if($?PRETEND) goto redate
    cat ${parthing}_todo.txt | tcsh >> ${parthing}.txt
    sort -g ${parthing}.txt >! new.txt
    mv new.txt ${parthing}.txt
    goto redate
endif
if($?PRETEND) goto redate

# split up work on multiple CPUs
echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    awk -v cpu=$cpu -v CPUs=$CPUs 'NR%CPUs==(cpu-1)' ${parthing}_todo.txt >! ${parthing}_todo_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_todo_${cpu}.txt | tcsh >! ${parthing}_${cpu}.txt &
end
wait
rm ${parthing}_todo*.txt
sort -g ${parthing}*.txt | awk 'NF>=3' >! new.txt
mv new.txt ${parthing}.txt
rm ${parthing}_*.txt

#goto update_ger_dates
redate:
set parthing = redate

echo "looking for date stamps that need to change. "
sort -g image_header_dates.txt |\
awk 'NF>=3 && sqrt(($1-$(NF-1))**2)>1.1{print}' |\
awk -v dir=$dir '{split($1,w,".");\
      file=substr($0,index($0,dir));\
   print "puts \"[clock format "w[1]" -format \"%b %d %H:%M:%S."w[2]" %Z %Y\"] "file"\""}' |\
tclsh |\
awk -v dir=$dir '{file=substr($0,index($0,dir));\
    print "touch    --date=\""$1,$2,$3,$4,$5"\"","\""file"\"";\
    print "touch -h --date=\""$1,$2,$3,$4,$5"\"","\""file"\""}' |\
cat >! ${parthing}.txt
wc -l ${parthing}.txt | awk '{print $1/2,$2}'

# see if there is any work to do
set test = `cat ${parthing}.txt | wc -l`
if($test < 100) then
    head -n 3 ${parthing}.txt
    set file = `awk '{gsub("\"","");print $NF}' ${parthing}.txt`
    if("$file" != "") then
        ls -l $file
        ls -lL $file
    endif
    echo "doing $parthing "
    if($?PRETEND) goto retouch
    cat ${parthing}.txt | tcsh
    goto retouch
endif
if($?PRETEND) goto retouch

set parthing = redate
echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    egrep "^touch" ${parthing}.txt |\
    awk -v cpu=$cpu -v CPUs=$CPUs 'NR%CPUs==(cpu-1)' |\
    awk '{print} NR%1000==0{print "echo",NR}' >! ${parthing}_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_${cpu}.txt | tcsh &
end
wait
rm ${parthing}_*.txt


retouch:
set parthing = retouch
echo "double-checking for links with wrong date stamp"
find $dir -type l -printf "%T@ " -exec ls -lL --time-style="+%b %d %H:%M:%S.%N %Z %Y %s" \{\} \; |&\
awk -v dir="$dir" '{lepoch=$1;fepoch=$12;\
   link=substr($0,index($0,dir));\
   date=$7" "$8" "$9" "$10" "$11;\
   deltaT=sqrt((lepoch-fepoch)**2)}\
   lepoch ~ /[^0-9.]/ || fepoch ~ /[^0-9.]/{\
      print "BAD LINK:",link;next;}\
   deltaT>1{print "touch -h --date=\""date"\"","\""link"\""}' |\
cat >! ${parthing}.txt
egrep "^BAD LINK:" ${parthing}.txt | tee bad_links.txt
egrep -v "^BAD LINK:"  ${parthing}.txt >! temp.txt
mv -f temp.txt ${parthing}.txt
wc -l ${parthing}.txt

# see if there is any work to do
set test = `cat ${parthing}.txt | wc -l`
if($test < 100) then
    head -n 3 ${parthing}.txt
    set file = `awk '{gsub("\"","");print $NF}' ${parthing}.txt`
    if("$file" != "") then
        ls -l $file
        ls -lL $file
    endif
    echo "doing ${parthing}"
    if($?PRETEND) goto exit
    cat ${parthing}.txt | tcsh
    goto exit
endif
if($?PRETEND) goto exit

# do parthing in parallel
echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    egrep "^touch" ${parthing}.txt |\
    awk -v cpu=$cpu -v CPUs=$CPUs 'NR%CPUs==(cpu-1)' |\
    awk '{print} NR%1000==0{print "echo",NR}' >! ${parthing}_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_${cpu}.txt | tcsh &
end
wait
rm ${parthing}_*.txt

wc -l bad_links.txt
echo "re-touching done."


exit:
if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif

exit


find $dir -type l -printf "%T@ %p\n" | sort -g | tail


find $dir -type l -printf "%h/%l %p\n" |\
awk '{print "touch -h --reference=\""$1"\"",$2}' |\
tee retouch.txt | wc -l


cat /data/log/LTO/backup_LTO_alsenable_?????.log |\
awk '{print "-",substr($NF,11)}' |\
tee already_backed_up_files.txt | wc -l



set oldtape = `ls -1 /data/log/LTO/backup_LTO_alsenable_?????.log | tail -n 2 | head -n 1`
set oldepoch = `tail -n 1 $oldtape | awk '{print $1}'`
set olddate = `echo "puts [clock format $oldepoch]" | tclsh`
echo "$olddate" >! alsenable/date_cutoff.txt
touch --date="$olddate" alsenable/date_cutoff.txt
chmod og-w alsenable/date_cutoff.txt


