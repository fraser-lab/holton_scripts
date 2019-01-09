#! /bin/tcsh -f
#
#    handy script for backing up ALS-ENABLE data
#
# local directory
set dir = "$1"
# beamline to use (i.e. BL831)
set beamline = "$2"
# remote subdir
set rdir = "$3"

if(! -d "$dir") then
    set dir = /data/mailinsaxs/
endif
if("$beamline" == "") then
    set beamline = BL1231
endif
if("$rdir" == "") then
    set rdir = "$dir"
endif

# place for temporary file list
mkdir -p /tmp/${USER}/
set tempfile = /tmp/${USER}/rsync_temp$$
setenv RSYNC_PASSWORD blahblahblah

# retrieve the date cutoff file
echo "getting too-old cutoff date file from server..."
rsync -a alsenable@bl831.als.lbl.gov::ALS-ENABLE/date_cutoff.txt ${tempfile}date_cutoff.txt

# make sure it has the right date stamp
set date = `cat ${tempfile}date_cutoff.txt`
if("$date" == "") then
    set BAD = "unable to retrieve remote date cutoff.  Ask James."
    goto exit
endif
touch --date="$date" ${tempfile}date_cutoff.txt
echo "looking for files in $dir created after $date"

# find new files worth backing up
find $dir -name .snapshot -prune -o \
    -newer ${tempfile}date_cutoff.txt -type f -printf "%T@ %P\n" |\
egrep '.gz$|.cbf$|.img$|.scan$|.jpg$|.jpeg$|[0-9]_[0-9][0-9][0-9][0-9][0-9].txt$|ExptParams|Izero.txt$|ASC$|.dat$' |\
awk '( /.cbf$/ || /.cbf.gz$/ ) && / FRAME| GAIN| ABS| ABSORP| BKGINIT| BKGPIX| BLANK| DECAY| MODPIX|-CORRECTIONS/{next}\
    {print}' |\
sort -g |\
awk '{print $NF}' >! ${tempfile}2bxfered.txt
rm -f ${tempfile}date_cutoff.txt
set files = `cat ${tempfile}2bxfered.txt | wc -l`
echo "$files candidates for transfer"

if( 0 ) then
    # this should help, but in reality only makes things slower for some reason
    mv ${tempfile}2bxfered.txt ${tempfile}newenough.txt

    # get files that are already there
    echo "getting remote list of filenames"
    rsync --list-only -r alsenable@bl831.als.lbl.gov::ALS-ENABLE/${beamline}/${rdir} >! ${tempfile}remote_files.txt

    echo "reconciling local and remote files."
    cat ${tempfile}remote_files.txt ${tempfile}newenough.txt |\
    awk 'NF==1 && ! seen[$NF]{print} /^-/{++seen[$NF]}' |\
    cat >! ${tempfile}2bxfered.txt
endif

# now do the actual transfer
echo "launching rsync"
rsync -av --files-from=${tempfile}2bxfered.txt --ignore-existing \
   $dir alsenable@bl831.als.lbl.gov::ALS-ENABLE/${beamline}/${rdir}
if($status) then
    set BAD = "rsync error"
    goto exit
endif

rm -f ${tempfile}* > /dev/null

exit:
if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif
echo "done"

exit


###########################

