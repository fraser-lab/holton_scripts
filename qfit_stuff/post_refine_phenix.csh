#!/bin/tcsh

if(! $?PHENIX) then
    source /home/sw/rhel6/x86_64/phenix/phenix-1.14-3260/phenix_env.csh
endif

set pdb = $1
set mtz = $2
set F = $3
set SF = $4
set elbow = $5

set bspdb = `basename $pdb .pdb`

# DETERMINE RESOLUTION AND (AN)ISOTROPIC REFINEMENT
set resrange = `phenix.mtz.dump $mtz | grep "Resolution range:"`
set res = `echo $resrange[4] | cut -c 1-5`
set res1000 = `echo $res | awk '{tot = $1*1000}{print tot }'`

if ( $res1000 < 1550 ) then
  set adp = 'adp.individual.anisotropic="not (water or element H)"' 
else
  set adp = 'adp.individual.isotropic=all'
endif

# REFINE COORDINATES ONLY
phenix.refine $mtz\
             $pdb\
             strategy=individual_sites\
             output.prefix=${bspdb}\
             output.serial=2\
             main.number_of_macro_cycles=5\
             refinement.input.xray_data.labels=$F,$SF\
             $elbow\
             write_maps=false\
             --overwrite

# REFINE UNTIL OCCUPANCIES CONVERGE
set zeroes = 50

while ($zeroes > 10 )
   phenix.refine $mtz\
              ${bspdb}_002.pdb\
              output.prefix=${bspdb}\
              output.serial=3\
              strategy="*individual_sites *individual_adp *occupancies"\
              main.number_of_macro_cycles=5\
              refinement.input.xray_data.labels=$F,$SF\
              $elbow\
              write_maps=false\
              --overwrite

   set z  = `awk '{ if(substr($0,1,6)=="CRYST1"||(substr($0,1,4)=="ATOM"||substr($0,1,6)=="HETATM")&&substr($0,57,4)+0<0.09) print $0}' ${bspdb}_003.pdb | wc` 
   set zeroes = $z[1]

   normalize_occupancies -occ 0.09 ${bspdb}_003.pdb
   awk '/^ATOM|^HETAT/ && substr($0,55)+0<0.09{next} {print}' ${bspdb}_003_norm.pdb >! ${bspdb}_002.pdb
   rm -f ${bspdb}_003_norm.pdb
end

# ADD HYDROGENS
phenix.reduce ${bspdb}_002.pdb > ${bspdb}_004.pdb

# FINAL REFINEMENT
phenix.refine $mtz\
              ${bspdb}_004.pdb\
              "$adp"\
              output.prefix=${bspdb}\
              output.serial=5\
              strategy="*individual_sites *individual_adp *occupancies"\
              main.number_of_macro_cycles=5\
              refinement.input.xray_data.labels=$F,$SF\
              $elbow\
              write_maps=false\
              --overwrite

cp multiconformer_model2_005.pdb qFit.pdb
cp multiconformer_model2_005.mtz qFit.mtz
cp multiconformer_model2_005.log qFit.log

exit 
