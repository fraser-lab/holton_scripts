#! /bin/awk -f
#
#
#        Jiggles a pdb file's coordinates by some random value                 -James Holton 1-18-20
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
    if(! shift_scale) shift_scale = 1
    if(! dry_shift_scale) dry_shift_scale = 1
    pshift = shift
    shift_opt = shift
    if(pshift == "byB") pshift = "sqrt(B/8)/pi"
    if(pshift == "LorentzB") pshift = "Lorentzian B"
    if(seed) srand(seed+0)
    if(! keepocc) keepocc=0
    if(! independent_confsel) independent_confsel=0
    if(! disulfide_links) disulfide_links=0
    if(! distribution) distribution="gaussian";
    if(! frac_thrubond) frac_thrubond=0.5
    if(! ncyc_thrubond) ncyc_thrubond=0
    if(! frac_magnforce) frac_magnforce=5.0
    if(! ncyc_magnforce) ncyc_magnforce=ncyc_thrubond/2

    pi=4*atan2(1,1);

    # random number between 1 and 0 to select conformer choices
    global_confsel=rand();

    print "REMARK jiggled by dXYZ=", pshift, "dB=", Bshift
    print "REMARK shift_scale=",shift_scale,"dry_shift_scale=",dry_shift_scale
    print "REMARK frac_thrubond=",frac_thrubond,"ncyc_thrubond=",ncyc_thrubond
    print "REMARK frac_magnforce=",frac_magnforce,"ncyc_magnforce=",ncyc_magnforce
    print "REMARK random number seed: " seed+0
    if(! keepocc && ! independent_confsel) print "REMARK global conf sel: " global_confsel
}

# count all lines
{++n;line[n]=$0}

/^ATOM|^HETAT/{
    if(debug) print tolower($0)

#######################################################################################
#    electrons = substr($0, 67,6)
#    XPLORSegid = substr($0, 73, 4)            # XPLOR-style segment ID
#    split(XPLORSegid, a)
#    XPLORSegid = a[1];
    Element = substr($0, 67)

#    Atomnum= substr($0,  7, 5)+0
    if(Element !~ /^[A-Z]/) Element= substr($0, 13, 2);
    Greek= substr($0, 15, 2);
    split(Element Greek, a)
    Atomtype[n]   = a[1];
    if(length(a[1])==4 && Element ~ /^H/)Element="H";
    gsub(" ","",Element);
    Ee[n] = Element;
    #main[n]=(Atom[n] ~ /^[NCO]$/ || Atom[n] ~ /^C[AB]$/);
    prefix[n] = substr($0,  1,30)
    Conf[n]   = substr($0, 17, 1)                # conformer letter
    Restyp[n] = substr($0, 18, 3)
    Segid[n]  = substr($0, 22, 1)            # O/Brookhaven-style segment ID
    Resnum[n] = substr($0, 23, 4)+0
    Insert[n] = substr($0, 27, 1)
    X[n]      = substr($0, 31, 8)+0
    Y[n]      = substr($0, 39, 8)+0
    Z[n]      = substr($0, 47, 8)+0
    Occ[n]    = substr($0, 55, 6)+0
    Bfac[n]   = substr($0, 61, 6)+0
    rest[n]   = substr($0, 67)
    # keep track of groupings
    atomtype = Atomtype[n]" "Restyp[n]
    residue = Restyp[n]" "Segid[n]" "Resnum[n] Insert[n];
    ++atoms_in[residue];
    sr = Segid[n]" "Resnum[n];
    csr = Conf[n]" "Segid[n]" "Resnum[n];

    if(Restyp[n]=="CYS") {
        ++has[sr];
        ++has[csr];
    }
#    ATOM   = toupper(substr($0, 1, 6))
#######################################################################################
}

# may want to "link" disulfide bonds
/^SSBOND/{
    ++found_disulfides

    s1=substr($0,16,1)
    r1=substr($0,18,4)+0
    s2=substr($0,30,1)
    r2=substr($0,32,4)+0

    sr1=s1" "r1
    sr2=s2" "r2
    disulfide_mate[sr2] = sr1
    disulfide_mate[sr1] = sr2
}
/^LINK/{
    ++found_disulfides

    c1=substr($0,17,1)
    s1=substr($0,22,1)
    r1=substr($0,23,4)+0
    c2=substr($0,47,1)
    s2=substr($0,52,1)
    r2=substr($0,53,4)+0
    sr1=s1" "r1
    sr2=s2" "r2
    csr1=c1" "s1" "r1
    csr2=c2" "s2" "r2
    disulfide_mate[sr2] = sr1
    disulfide_mate[sr1] = sr2
    disulfide_mate[csr2] = csr1
    disulfide_mate[csr1] = csr2
}

END{
  if(disulfide_links && ! found_disulfides) {
      print "REMARK warning, no disulfides found"
  }

  # min/max bond lengths
  if(min_bond_d == "") min_bond_d = 1
  if(max_bond_d == "") max_bond_d = 2


  for(i=1;i<=n;++i)
  {
    if(prefix[i] !~ /^ATOM|^HETAT/ ) continue;

    # abbreviations
    atomtype = Atomtype[i]" "Restyp[i]
    residue = Restyp[i]" "Segid[i]" "Resnum[i] Insert[i];
    sr = Segid[i]" "Resnum[i];
    csr = Conf[i]" "Segid[i]" "Resnum[i];

    if(shift_opt=="byB" || shift_opt=="LorentzB"){
        # switch on "thermal" shift magnitudes
        shift=sqrt(Bfac[i]/8)/pi*sqrt(3);

        # kick them more than byB?
        if(shift_scale != 1){
            shift *= shift_scale;
        }

        # kick them more if they are not water
        if(Restyp[i] != "HOH" && dry_shift_scale != 1){
            shift *= dry_shift_scale;
        }

        # randomly "skip" conformers with occ<1
        if(Occ[i]+0<1){
            # remember all occupancies
            if(conf_hi[csr]==""){
                conf_lo[csr]=cum_occ[sr]+0;
                cum_occ[sr]+=Occ[i];
                conf_hi[csr]=cum_occ[sr];
            }
        }
    }
    if(shift_opt == "LorentzB")
    {
        distribution = "Lorentz"
    }
    
    if(distribution == "gaussian" || distribution == "Gauss")
    {
        dx = gaussrand(shift/sqrt(3));
        dy = gaussrand(shift/sqrt(3));
        dz = gaussrand(shift/sqrt(3));
    }
    if(distribution == "uniform")
    {
        dR=2
        while(dR>1)
        {
            dx = (2*rand()-1);
            dy = (2*rand()-1);
            dz = (2*rand()-1);
            dR = sqrt(dx^2+dy^2+dz^2);
        }
        dx *= shift;
        dy *= shift;
        dz *= shift;
    }
    if(distribution == "Lorentz")
    {
        mag = lorentzrand(shift); 
        dR=2
        while(dR>1 || dR < 0.1)
        {
            dx = (2*rand()-1);
            dy = (2*rand()-1);
            dz = (2*rand()-1);
            dR = sqrt(dx^2+dy^2+dz^2);
        }
        dx *= mag/dR;
        dy *= mag/dR;
        dz *= mag/dR;
    }

    dX[i] = dx;
    dY[i] = dy;
    dZ[i] = dz;

    # pick a random shift on B-factor
    if(Bshift+0>0) Bfac[i] += gaussrand(Bshift)
    if(Oshift+0>0) Occ[i] += gaussrand(Oshift)
    
    # use same occopancy for given conformer
    if(! keepocc && conf_hi[csr]!=""){
        # use same random number for all conformer choices
        confsel = global_confsel;
        # unless occupancies do not add up
        # or if user selected no correlation between conformer selections
        if(Conf[i]==" " || independent_confsel){
            # save this for later
            if(confsel_of[sr]=="") {
                confsel_of[sr] = rand();
                if(disulfide_links && disulfide_mate[sr] != "") {
                    confsel_of[disulfide_mate[sr]]=confsel_of[sr];
                }
            }
        }
        else
        {
            # assume "A" is most popular and all "A" confs go together
            confsel_of[sr] = global_confsel;
        }
        Occ[i] = 0;
        # atom only exists if it falls in the chosen interval
        confsel = confsel_of[sr];
        lo=conf_lo[csr];
        hi=conf_hi[csr];
        if(lo < confsel && confsel <= hi) Occ[i]=1;
    }
    # override all of the above if conformer is already selected
    if(confletter_of[sr]!="") 
    {
        Occ[i]=0;
        if(Conf[i] == confletter_of[sr]) Occ[i]=1;
    }
    if(disulfide_mate[sr]!="" && has[Conf[i]" "disulfide_mate[sr]])
    {
        confletter_of[disulfide_mate[sr]]=confletter_of[sr];
    }
    # lock in conformer letter
    if(Occ[i]==1) confletter_of[sr]=Conf[i];
  }


    if(frac_thrubond != 0 && ncyc_thrubond != 0)
    {
        print "REMARK measuring original bond lengths"
        # now, find all the bonds in the unperturbed structure that don't involve zero-occupancy members
        for(i=1;i<=n;++i){
            #skip zero occupancy
            if( Occ[i]==0 ) continue;
            for(j=1;j<i;++j){
                # skip big distances for speed
                if(X[i]>X[j]+10 || X[i]<X[j]-10) continue;
                if(Y[i]>Y[j]+10 || Y[i]<Y[j]-10) continue;
                if(Z[i]>Z[j]+10 || Z[i]<Z[j]-10) continue;
                # skip zero occupancy
                if( Occ[j]==0 ) continue;
                # skip nonsencial conformer relationships?
#                if( Conf[j] != Conf[i] && ! ( Conf[i] == " " || Conf[j] == " " || main[j] && main[i]) ) continue;
                mind=min_bond_d;maxd=max_bond_d;
                # hydrogen bonding lengths are shorter
                if( Ee[i] == "H" || Ee[j] == "H" ){
                    mind=0.5;maxd=1.5;
                    if(Ee[i]==Ee[j])maxd=0;
                };
                # recognize disulfides
                if( Ee[i]=="S" && Ee[j] == "S" && Restyp[i]=="CYS" && Restyp[j]=="CYS"){mind=1.5;maxd=2.5};
                # measure distance
                if(X[i]>X[j]+maxd || X[i]<X[j]-maxd) continue;
                if(Y[i]>Y[j]+maxd || Y[i]<Y[j]-maxd) continue;
                if(Z[i]>Z[j]+maxd || Z[i]<Z[j]-maxd) continue;
                d=sqrt((X[i]-X[j])^2+(Y[i]-Y[j])^2+(Z[i]-Z[j])^2);
                if(d>mind && d<maxd) {
                    # distance falls within range
                    newbond=1;
                    for(k=1;k<=nbonds[i]+0;++k){
                        # woops, this bond already exists
                        if(bond[i,k]==j){
                            newbond=0;
                            break;
                        }
                    }
                    if(newbond) {
                        # legitimate new bond, increment the list
                        ++nbonds[i];
                        bond[i,nbonds[i]]=j;
                        bondlen[i,j]=d;
                    }
                    newbond=1;
                    # check if reverse bond is already there
                    for(k=1;k<=nbonds[j]+0;++k){
                        if(bond[j,k]==i){
                            newbond=0;
                            break;
                        }
                    }
                    if(newbond) {
                        # also account for reverse bond
                        ++nbonds[j];
                        bond[j,nbonds[j]]=i;
                        bondlen[j,i]=d;
                    }
                }
            }
        }
        print "REMARK done measuring bond lengths"

        # now go through and force ideal bonds that we know about
        for(i=1;i<=n;++i){
            if(Occ[i]==0) continue;
        }

        # measure and store all currently applied displacement magnitudes
        for(i=1;i<=n;++i){
            master_dXYZ[i]=sqrt(dX[i]**2+dY[i]**2+dZ[i]**2);
        }

        # iterative application of thru-bond smoothing
        for(l=1;l<=ncyc_thrubond;++l)
        {
            print "REMARK thru-bond averaging cycle",l
            # loop over all atoms
            for(i=1;i<=n;++i){
                if(Occ[i]==0) continue;
                realbonds=ddX[i]=ddY[i]=ddZ[i]=0;
                # take every atom bonded to this atom
                for(u=1;u<=nbonds[i];++u){
                j = bond[i,u];
                if(i==j) continue;
                if(Occ[j]==0)continue;
                ++realbonds;
                ddX[i] += dX[j];
                ddY[i] += dY[j];
                ddZ[i] += dZ[j];
            }
            if(! realbonds) continue;
                ddX[i] /= realbonds;
                ddY[i] /= realbonds;
                ddZ[i] /= realbonds;
            }
            # second pass to update delta-positions
            for(i=1;i<=n;++i){
                if(Occ[i]==0) continue;
                bw=frac_thrubond;
                if(Ee[i]=="H") bw=1;
                dX[i] = (1-bw)*dX[i] + bw*ddX[i];
                dY[i] = (1-bw)*dY[i] + bw*ddY[i];
                dZ[i] = (1-bw)*dZ[i] + bw*ddZ[i];
            }
            # third pass to rescale shift magnitudes
            if(l<=ncyc_magnforce)
            {
                mw=(1-(l-1)/(ncyc_magnforce-1))
                ms=frac_magnforce
                if(l>ncyc_magnforce)mw=0;
                for(i=1;i<=n;++i){
                    if(Occ[i]==0) continue;
                    if(Ee[i]=="H") mw=0;
                    mag = sqrt(dX[i]**2+dY[i]**2+dZ[i]**2);
                    if(mag<=0.0) {
                        continue;
                        # make something up?
                        mag=1e-6;
                        dX[i]=mag*(rand()-0.5);
                        dY[i]=mag*(rand()-0.5);
                        dZ[i]=mag*(rand()-0.5);
                    }
                    # get difference between current and scaled version of originally prescribed shift magnitude
                    dmag = (ms*master_dXYZ[i]-mag);
                    # scale thet shift to be more like original magnitude
                    scale = (mag+mw*dmag)/mag;
                    dX[i] = scale*dX[i];
                    dY[i] = scale*dY[i];
                    dZ[i] = scale*dZ[i];
#if(i==456) print "GOTHERE1",dX[i],dY[i],dZ[i],"    ",master_dXYZ[i],mag,"    ",dmag,scale,mw
                }
            }
        }
    }


    for(i=1;i<=n;++i)  
    {
        if(prefix[i] !~ /^ATOM|^HETAT/ )
        {
            print line[i];
            continue;
        }
      
        X[i] += dX[i];
        Y[i] += dY[i];
        Z[i] += dZ[i];
      
        # now print out the new atom
        printf("%s%8.3f%8.3f%8.3f %5.2f%6.2f%s\n",prefix[i],X[i],Y[i],Z[i],Occ[i],Bfac[i],rest[i]);        
    }
}



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
