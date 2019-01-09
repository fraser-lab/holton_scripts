#! /bin/tcsh -f
#
#   find images that are duplicates and replace them with symbolic links to the original
#
set dir = "$1"
set pretend = "$2"
set nosums = "$3"

if(! -d "$dir") then
    set dir = alsenable/
endif
if("$pretend" == "pretend") setenv PRETEND
if("$nosums" == "nosums") setenv NOSUMS


set CPUs = `grep proc /proc/cpuinfo | wc -l | awk '{print $NF/2+1}'`


if(! -x ./image_md5_extract.com) then
    cp ~jamesh/archiving/image_md5_extract.com .
endif
if(! -x ./image_md5_extract.com) then
    set BAD = "cannot find image_md5_extract.com"
    goto exit
endif

echo "finding all img and cbf files in $dir ..."
find $dir -name .snapshot -prune -o \
   -type f -size +0 \( -name '*.cbf' -o -name '*.img' \) -printf "%T@ %p\n" |\
  awk -v dir=$dir '{file=substr($0,index($0,dir));\
    print ( ! /OVERWRITTEN_FILES/ ),length(file),$1,file}' |\
  sort -g |\
  awk '{print substr($0,index($0,$3))}' >! image_files.txt
echo "finding all img and cbf links in $dir ..."
find $dir -name .snapshot -prune -o \
   -type l \( -name '*.cbf' -o -name '*.img' \) -printf "%T@ %p\n" |\
  awk -v dir=$dir '{file=substr($0,index($0,dir));\
    print ( ! /OVERWRITTEN_FILES/ ),length(file),$1,file}' |\
  sort -g |\
  awk '{print substr($0,index($0,$3))}'>! image_links.txt

# fix stupid filenames
awk 'NF>2' image_files.txt |\
awk -v dir="$dir" '{idx=index($0,dir);\
      oldfile=substr($0,idx);\
      gsub(" ","_");\
      newfile=substr($0,idx);\
   print "mv \""oldfile"\"",newfile}' |\
tee change_stupidnames.txt

set test = `cat change_stupidnames.txt | wc -l`
if($test) then
    set BAD = "files have stupid names: run change_stupidnames.txt if you dare"
    goto exit
endif


touch image_md5sums.txt
touch all_md5sums.txt

echo "updating all_md5sums.txt"
cat all_md5sums.txt image_md5sums.txt |\
awk '! seen[$0]{print;++seen[$0]}' |\
cat >! new.txt
mv new.txt all_md5sums.txt

# cull md5sum info with no file nor link on disk
echo "culling images from image_md5sums.txt that do not exist on disk "
awk '{print $2}' image_files.txt image_links.txt |\
cat - image_md5sums.txt |\
awk -v dir=$dir '{file=substr($0,index($0,dir))}\
  NF==1{++exist[file];next}\
  exist[file]{print}' |\
cat >! existing_image_md5sums.txt
wc -l image_md5sums.txt existing_image_md5sums.txt | grep -v total
mv existing_image_md5sums.txt image_md5sums.txt


# remove XDS-based CBF files from consideration
cat image_files.txt |\
awk '( /.cbf$/ || /.cbf.gz$/ ) && /\/FRAME|\/GAIN|\/ABS|\/ABSORP|\/BKGINIT|\/BKGPIX|\/BLANK|\/DECAY|\/MODPIX|-CORRECTIONS/{next}\
    {print}' |\
cat >! data_files.txt
mv image_files.txt all_image_files.txt
mv data_files.txt image_files.txt

# find images with no sum in database
echo "finding images that need md5 sums "
set parthing = image_md5sums
awk '{print $2}' image_files.txt |\
cat ${parthing}.txt - |\
awk -v dir=$dir '{file=substr($0,index($0,dir))}\
  NF==1 && ! seen[file]{print file} {++seen[file]}' |\
awk '{print "./image_md5_extract.com \""$0"\""}' |\
cat >! ${parthing}_todo.txt
wc -l ${parthing}_todo.txt

# see if there is any work to do
set test = `cat ${parthing}_todo.txt | wc -l`
if($test < 100) then
    echo "doing $parthing "
    if($?NOSUMS) goto sortsums
    cat ${parthing}_todo.txt | tcsh >> ${parthing}.txt
    sort -g ${parthing}.txt >! new.txt
    mv new.txt ${parthing}.txt
    goto sortsums
endif
if($?NOSUMS) goto sortsums

# split up work on multiple CPUs
echo "doing $parthing in parallel "
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    awk -v cpu=$cpu -v CPUs=$CPUs 'NR%CPUs==(cpu-1)' ${parthing}_todo.txt >! ${parthing}_todo_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_todo_${cpu}.txt | tcsh >! ${parthing}_${cpu}.txt &
end
wait
rm ${parthing}_todo*.txt
sort -g ${parthing}.txt ${parthing}_[1-9]*.txt | awk 'NF>=2' >! new.txt
wc -l ${parthing}.txt new.txt | grep -v total
mv new.txt ${parthing}.txt
rm ${parthing}_*.txt

# maybe go back and do this again?


sortsums:

# make list of files ordered in creation time
echo "ordering md5 sums..."
awk '{print "EPOCH",$0}' image_files.txt |\
cat image_md5sums.txt - |\
awk '! /^EPOCH/{md5[$2]=$1;next}\
     md5[$NF]!=""{print $2,md5[$NF],$NF}' |\
awk '{++seen[$0]} seen[$0]==1{print}' |\
tee ordered.txt | wc -l

# use last appearance of given MD5 sum as the "master"
echo "finding duplicates"
cat ordered.txt |\
awk '{++seen[$2]} seen[$2]>1{print prev[$2],$NF} {prev[$2]=$NF}' |\
cat >! duplicates.txt 

set duplicates = `cat duplicates.txt | wc -l`
echo "$duplicates duplicates found"
if("$duplicates" == "0") then
    goto checklinks
endif

# super magic script for creating relative links between duplicate files
echo "creating relative link logic"
cat duplicates.txt |\
awk '{file=$2;old=$1;\
       n=split(file,w,"/");\
       m=split(old,v,"/");\
       l=(m>n?m:n);\
       p=0;link=".";\
       for(i=1;i<=l;++i){\
         if(w[i]!=v[i])++p;\
         if(p && i<m)link="../"link;\
         if(p && w[i]!="")link=link"/"w[i];\
#print "DEBUG",w[i],v[i],link;\
       };\
       gsub("/\\./","/",link);\
       olddir=old;while(gsub("[^/]$","",olddir));\
       print "ls",old;\
       print "cd",olddir;\
       print "ls",link;\
       print "cd -"}' |\
cat >! check_image_duplicates.txt
# this will check that links will work before we delete files and make them
#cat check_image_duplicates.txt | tcsh | grep GOTHERE

# convert the checking script into the doing script
cat check_image_duplicates.txt |\
awk '/^cd/{print}\
     /^ls \./{print "ln -sf",$2,oldf;\
                print "touch -h --reference=\""$2"\"",oldf;\
                next}\
     /^ls /{old=$2;n=split(old,w,"/");oldf=w[n]}' |\
cat >! remove_image_duplicates.txt
#cat remove_image_duplicates.txt | tcsh | grep GOTHERE

# do this is parallel
set parthing = check_image_duplicates
echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    cat ${parthing}.txt |\
    awk -v cpu=$cpu -v CPUs=$CPUs 'int((NR-1)/4)%CPUs==(cpu-1)' >! ${parthing}_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    ( cat ${parthing}_${cpu}.txt | tcsh > /dev/null ) >&! ${parthing}_${cpu}_errors.txt &
end
wait
set errors = `cat ${parthing}_*_errors.txt | wc -l`
if($errors) then
    set BAD = "errors checking links!  you must investigate ${parthing} files"
    goto exit
endif
rm -f ${parthing}_*.txt


rmdup:
set parthing = remove_image_duplicates
# do this is parallel
echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    egrep -v "^echo GOTHERE" ${parthing}.txt |\
    awk -v cpu=$cpu -v CPUs=$CPUs 'int((NR-1)/4)%CPUs==(cpu-1)' >! ${parthing}_${cpu}.txt
end
if($?PRETEND) goto checklinks
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_${cpu}.txt | tcsh -e >&! ${parthing}_${cpu}_errors.txt &
end
wait
set errors = `cat ${parthing}_*_errors.txt | wc -l`
if($errors) then
    set BAD = "errors making links!  you must investigate ${parthing} files "
    goto exit
endif
rm -f ${parthing}_*.txt


checklinks:
set parthing = checklinks
# finally, see if it worked
echo "checking all links in $dir actually work"
find $dir -type l | tee links.txt | wc -l

cat links.txt |\
awk '{n=split($0,w,"/");file=w[n];dir=substr($0,1,length($0)-length(file));\
   print "( cd \""dir"\" ; ls \""file"\" ; cd - ) > /dev/null"}' |\
cat >! ${parthing}.txt
wc -l ${parthing}.txt

echo "doing $parthing in parallel"
foreach cpu ( `seq 1 $CPUs` )
#    echo $cpu
    cat ${parthing}.txt |\
    awk -v cpu=$cpu -v CPUs=$CPUs 'int((NR-1)/4)%CPUs==(cpu-1)' >! ${parthing}_${cpu}.txt
end
foreach cpu ( `seq 1 $CPUs` )
    cat ${parthing}_${cpu}.txt | tcsh  >&! ${parthing}_${cpu}_errors.txt &
end
wait
set errors = `cat ${parthing}_*_errors.txt | wc -l`
if($errors) then
    set BAD = " double-checking links!  you must investigate ${parthing} files "
    goto exit
endif
rm -f ${parthing}_*.txt

echo "checking if any links were missed. "
cat links.txt remove_image_duplicates.txt |\
awk 'NF==1{++got[$1];next} /^cd/{dir=$NF} /^ln/{file=dir $NF}\
   /^ln/ && ! got[file]{print}' |\
cat >! redo.txt
# should not be anything in this list!

set test = `cat redo.txt | wc -l`
echo "$test links were missed."
if( $test != 0 ) then
    set BAD = "some links were missed.  you must investigate redo.txt "
    goto exit
endif


exit:
if($?BAD) then
    echo "ERROR: $BAD"
    exit
endif

exit




