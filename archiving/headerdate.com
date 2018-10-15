#! /bin/tcsh -f
#
#   get date out of image header
#
#

set img = "$1"
set epoch = ""
set suffix = "000"

set fileepoch = `find "$img" -printf '%T@'`

set test = `head -512c "$img" | awk -F "=" '/HEADER_BYTES/ && $2+0>0{print $2+0;exit}'`
if("$test" != "") then
    set date = `head -${test}c "$img" | awk -F "[=;]" '/DATE/{print $2}'`
else
    set date = `head -512c "$img" | awk '/^# Detector:/{getline;gsub("\r","");print $NF}'`
endif
if("$date" == "") then
    set prefix = `echo "$img" | awk '{while(gsub("[img.cbf]$",""));while(gsub("[0-9]$",""));print}'`
    set txt = `ls -1 ${prefix}*.txt | head -n 1`
    if(-e "$txt") then
        set test = `awk '/^hutchDoorStatus/' $txt`
    endif
endif
if("$date" != "") then
    set epoch = `echo 'puts [clock scan "'$date'"]' | tclsh |& awk '$1+0>0{print}'`
endif
if("$date" == "") then
    # give up and hope file date is ok
    set epoch = "$fileepoch"
endif
if("$epoch" == "") then
    set newdate = `echo $date | awk -F "." '{gsub("T"," ");print $1}'`
    set suffix = `echo $date | awk -F "." '{gsub("T"," ");print $2}'`
    set epoch = `echo 'puts [clock scan "'$newdate'"]' | tclsh |& awk '$1+0>0{print}'`
endif
if("$epoch" == "") then
    set newdate = `echo $newdate | awk '{print $2,$3,$5,$4}'`
    set epoch = `echo 'puts [clock scan "'$newdate'"]' | tclsh |& awk '$1+0>0{print}'`
endif
if("$epoch" == "") set epoch = "unk"

echo ${epoch}.${suffix} $date   $fileepoch $img

exit


# see fix_image_date_notes.com


