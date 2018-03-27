#! /usr/bin/awk -f
#
#
#        Jiggles a pdb file's coordinates by some random value
#        run like this:
#
#        jigglepdb.awk seed=2343 shift=1.0 old.pdb >! jiggled.pdb
#         (use a different seed when you want a different output file)
#
BEGIN {

    if(! shift)  shift = 0.5
    if(! Bshift) Bshift = shift
    if(shift == "byB") Bshift = 0
    if(shift == "Lorentz") Bshift = 0
    if(! drykick_scale) drykick_scale = 1
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

    if(debug) print tolower($0)

#######################################################################################
    electrons = substr($0, 67,6)
    XPLORSegid = substr($0, 73, 4)            # XPLOR-style segment ID
    split(XPLORSegid, a)
    XPLORSegid = a[1];
    Element = substr($0, 67)

    Atomnum= substr($0,  7, 5)+0
    Element= substr($0, 13, 2);
    Greek= substr($0, 15, 2);
    split(Element Greek, a)
    Atom   = a[1];
    Conf   = substr($0, 17, 1)                # conformer letter
    Restyp = substr($0, 18, 3)
    Segid  = substr($0, 22, 1)            # O/Brookhaven-style segment ID
    Resnum = substr($0, 23, 4)+0
    X      = substr($0, 31, 8)+0
    Y      = substr($0, 39, 8)+0
    Z      = substr($0, 47, 8)+0
    Occ    = substr($0, 55, 6)+0
    Bfac   = substr($0, 61, 6)+0
#   rest   = substr($0, 67)
    ATOM   = toupper(substr($0, 1, 6))
#######################################################################################

    if(shift_opt=="byB" || shift_opt=="LorentzB"){
        # switch on "thermal" shift magnitudes
        shift=sqrt(Bfac/8)/pi*sqrt(3);

        # kick them more if they are not water
        if(Restyp != "HOH" && drykick_scale != 1){
            shift *= drykick_scale;
        }

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
    printf("%s%8.3f%8.3f%8.3f %5.2f%6.2f%s\n",substr($0,1,30),X,Y,Z,Occ,Bfac,substr($0,67));        
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
