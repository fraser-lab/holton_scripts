#! /bin/tcsh -f
#
#
#
set image = "$1"

set md5 = `awk 'BEGIN{RS="\f"} {print;exit}' $image |& awk '/Content-MD5:/{gsub("\r","");print $NF;exit}'`

if("$md5" != "") then
    echo "$md5 $image"
    exit
endif

md5sum $image


