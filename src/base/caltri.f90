!-------------------------------------------------------------------------------

! This file is part of Code_Saturne, a general-purpose CFD tool.
!
! Copyright (C) 1998-2016 EDF S.A.
!
! This program is free software; you can redistribute it and/or modify it under
! the terms of the GNU General Public License as published by the Free Software
! Foundation; either version 2 of the License, or (at your option) any later
! version.
!
! This program is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
! FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
! details.
!
! You should have received a copy of the GNU General Public License along with
! this program; if not, write to the Free Software Foundation, Inc., 51 Franklin
! Street, Fifth Floor, Boston, MA 02110-1301, USA.

!-------------------------------------------------------------------------------

subroutine caltri
!================

!===============================================================================
! Purpose:
! --------

! Main solver subroutine (read, time loop, write)

!-------------------------------------------------------------------------------
! Arguments
!__________________.____._____.________________________________________________.
! name             !type!mode ! role                                           !
!__________________!____!_____!________________________________________________!
!__________________.____._____.________________________________________________.

!     Type: i (integer), r (real), s (string), a (array), l (logical),
!           and composite types (ex: ra real array)
!     mode: <-- input, --> output, <-> modifies data, --- work array
!===============================================================================

!===============================================================================
! Module files
!===============================================================================

use paramx
use dimens
use pointe
use optcal
use numvar
use cstphy
use cstnum, only: epzero
use entsor
use albase
use parall
use period
use ppppar
use ppthch
use ppincl
use coincl
use cpincl
use lagran
use vorinc
use ihmpre
use radiat
use cplsat
use atincl
use cfpoin
use mesh
use field
use post
use atchem
use atimbr
use siream
use ptrglo
use turbomachinery
use cs_c_bindings
use cs_f_interfaces

use, intrinsic :: iso_c_binding

use cs_tagmr
use cs_tagms
use cs_nz_condensation
use cs_nz_tagmr

!===============================================================================

implicit none

! Arguments


! Local variables

integer          iiii

integer          modhis, iappel, modntl, iisuit, iwarn0
integer          ivar
integer          iel

integer          inod   , idim, ifac
integer          itrale , ntmsav

integer          nent

integer          stats_id, restart_stats_id, lagr_stats_id, post_stats_id

double precision titer1, titer2

integer          ivoid(1)
double precision rvoid(1)

double precision, save :: ttchis

character        ficsui*32

integer, allocatable, dimension(:) :: isostd

double precision, pointer, dimension(:)   :: dt => null()
double precision, pointer, dimension(:)   :: porosi => null()
double precision, pointer, dimension(:,:) :: propce => null()
double precision, pointer, dimension(:,:) :: disale => null()

double precision, pointer, dimension(:,:) :: frcxt => null()
double precision, pointer, dimension(:)   :: prhyd => null()

!===============================================================================
! Interfaces
!===============================================================================

interface

  subroutine tridim &
  ( itrale , nvar   , nscal  ,                                     &
    isostd ,                                                       &
    dt     , propce ,                                              &
    frcxt  , prhyd  )

    use dimens, only: ndimfb
    use mesh, only: nfabor

    implicit none

    integer                                   :: itrale, nvar, nscal
    integer, dimension(nfabor+1)              :: isostd

    double precision, pointer, dimension(:)   :: dt
    double precision, pointer, dimension(:,:) :: propce
    double precision, pointer, dimension(:,:) :: frcxt
    double precision, pointer, dimension(:)   :: prhyd

  end subroutine tridim

  !=============================================================================

end interface

!===============================================================================

!===============================================================================
! Initialization
!===============================================================================

! Initialize random number generator
! (not always necessary, but not at all costly)

! If parallelized particle-tracking is in use,
! seed the random number generator with
! (rank number+1) to avoid potential statistical bias

if ((iilagr.gt.0).and.(irangp.ge.0)) then
  call zufalli(irangp + 1)
else
  call zufalli(1)
endif

!--> Probes output tracking
ttchis = -1.d0

! Test presence of control_file to modify ntmabs if required
!

ntmsav = ntmabs

call cs_control_check_file

if (idtvar.eq.1 .and. ntmsav.gt.ntmabs .and. ntmabs.eq.ntcabs) then
  call cplact(ivoid(1))
  if (ivoid(1).gt.0) ntmabs = ntmabs+1
endif

! Define timer stats based on options

if (iilagr.gt.0) then
  lagr_stats_id = timer_stats_create("stages", &
                                     "lagrangian_stage", &
                                     "Lagrangian Module")
  stats_id = timer_stats_create("lagrangian_stage", &
                                "particle_displacement_stage", &
                                "particle displacement")
endif

!===============================================================================
! Geometry
!===============================================================================

call cregeo

!===============================================================================
! End of modules initialization
!===============================================================================

call initi2

!===============================================================================
! Zone definition for head-loss, mass sources term,
!   condensation sources term and 1D-wall module
!===============================================================================

! First pass for every subroutine
iappel = 1

! Allocate temporary arrays for zones definition
allocate(izcpdc(ncel))
allocate(izctsm(ncel))
allocate(izftcd(ncel)) ! should be in init_pcond only
allocate(izft1d(nfabor))

! ---------
! Head-loss
! ---------

if (iihmpr.eq.1) then
  call uikpdc &
( iappel ,          &
  ncepdc ,          &
  ivoid  ,          &
  rvoid  )
endif

call cs_user_head_losses &
( ncepdc , iappel ,                                              &
  ivoid  , izcpdc ,                                              &
  rvoid  ,                                                       &
  rvoid  )

! Total number of cells with head-loss
ncpdct = ncepdc
if (irangp.ge.0) then
  call parcpt(ncpdct)
endif

if (iflow .eq. 1) then
  if (ncpdct.eq.0) then
    ncepdc = ncel
    ncpdct = ncel
  endif
  if (irangp.ge.0) then
    call parcpt(ncpdct)
  endif
endif

if (ncpdct.gt.0) then
  write(nfecra,2001) ncpdct
  write(nfecra,3000)
  ! Add matching field if not already done
  if (idtten.lt.0) then
    call field_create('dttens', FIELD_INTENSIVE, 1, 6, .false., idtten)
  endif
else if (iporos.eq.2) then
  ! Add matching field if not already done
  if (idtten.lt.0) then
    call field_create('dttens', FIELD_INTENSIVE, 1, 6, .false., idtten)
  endif
endif

! -----------------
! Mass source terms
! -----------------

call cs_user_mass_source_terms &
( nvar   , nscal  , ncepdc ,                                     &
  ncetsm , iappel ,                                              &
  ivoid  ,                                                       &
  ivoid  , ivoid  , izctsm ,                                     &
  rvoid  ,                                                       &
  ckupdc , rvoid  )

! Total number of cells with mass source term
nctsmt = ncetsm
if (irangp.ge.0) then
  call parcpt(nctsmt)
endif

if (nctsmt.gt.0) then
  write(nfecra,2002) nctsmt
  write(nfecra,3000)
endif

! Condensation mass source terms
! ------------------------------

call cs_user_boundary_mass_source_terms &
( nvar   , nscal  ,                                              &
  nfbpcd , iappel ,                                              &
  ivoid  , ivoid  , izftcd ,                                     &
  rvoid  , rvoid(1)  )

! Total number of cells with condensation source term
nftcdt = nfbpcd
if (irangp.ge.0) then
  call parcpt(nftcdt)
endif

if (nftcdt.gt.0) then
  write(nfecra,2003) nftcdt
  write(nfecra,3000)
endif

! --------------
! 1D-wall module
! --------------

call uspt1d &
 ( nvar   , nscal  , nfpt1d , iappel ,                            &
   ivoid  , izft1d , ivoid  , ivoid  ,                            &
   rvoid  , rvoid  , rvoid  ,                                     &
   rvoid  , rvoid  , rvoid  ,                                     &
   rvoid  , rvoid  , rvoid  ,                                     &
   rvoid  )

nfpt1t = nfpt1d
if (irangp.ge.0) then
  call parcpt(nfpt1t)
endif

if (nfpt1t.gt.0) then
  write(nfecra,2004) nfpt1t, nfpt1d
  write(nfecra,3000)
endif

call vert1d &
( nfabor , nfpt1d , iappel ,                                      &
  ivoid  , ivoid  , ivoid  ,                                      &
  rvoid  , rvoid  ,                                               &
  rvoid  , rvoid  , rvoid  )

! Free memory if relevant
if (ncpdct.eq.0) deallocate(izcpdc)
if (nctsmt.eq.0) deallocate(izctsm)
if (nftcdt.eq.0) deallocate(izftcd)
if (nfpt1t.eq.0) deallocate(izft1d)

! Formats
#if defined(_CS_LANG_FR)
 2001 format(                                                   &
 /,/,'TRAITEMENT DES PERTES DE CHARGES ACTIVE ',/,              &
 '                 SUR  UN TOTAL DE NCEPDC = ',I10,' CELLULES',/)
 2002 format(                                          &
 /,/,'TRAITEMENT DES SOURCES DE MASSE ACTIVE ',/,      &
   '                 SUR  UN TOTAL DE ',I10,' CELLULES')
 2003 format(                                           &
 /,/,'TRAITEMENT DES SOURCES DE CONDENSATION ACTIVE ',/,&
   '                 SUR  UN TOTAL DE ',I10,' CELLULES')
 2004 format(                                                     &
    /,'MODULE THERMIQUE 1D EN PAROI ACTIVE     ',/,&
      '   SUR UN TOTAL DE ',I10,' FACES DE BORD',/,               &
      '   (',I10,' FACES DE BORD EN LOCAL)',/)
#else
 2001 format(                                               &
 /,/,'HEAD LOSS TERMS TREATMENT ACTIVATED ',/,              &
 '                 ON   A TOTAL OF NCEPDC = ',I10,' CELLS',/)
 2002 format(                                    &
 /,/,'MASS SOURCE TERMS TREATMENT ACTIVATED ',/, &
   '                 ON A TOTAL OF ',I10,' CELLS')
 2003 format(                                            &
 /,/,'CONDENSATION SOURCE TERMS TREATMENT ACTIVATED ',/, &
   '                 ON A TOTAL OF ',I10,' CELLS')
 2004 format(                                               &
 /,'1D-WALL THERMAL MODULE ACTIVATED ',/,     &
   '   ON A TOTAL OF ',I10,' BOUNDARY FACES',/,             &
   '   (',I10,' LOCAL BOUNDARY FACES)',/)
#endif


!===============================================================================
! Memory management
!===============================================================================

! Allocate main arrays

allocate(dt(ncelet))
allocate(propce(ncelet,nproce))

! Allocate arrays on boundary faces

allocate(isostd(nfabor+1))
if (iphydr.eq.1) then
  allocate(frcxt(3, ncelet))
else
  frcxt => rvoid2
endif

if (iphydr.eq.2) then
  allocate(prhyd(ncelet))
else
  prhyd => rvoid1
endif

call boundary_conditions_init

call init_aux_arrays(ncelet, nfabor)

call turbomachinery_init

if (ippmod(iatmos).ge.0) then

  call init_meteo

  if (imbrication_flag) then
    call activate_imbrication
  endif

  if (ifilechemistry.ge.1) then
    call init_chemistry
  endif

  if (iaerosol.eq.1) then
    call init_aerosols
  endif

endif

if (ippmod(icompf).ge.0) then
  call init_compf (nfabor)
endif

if (iale.eq.1.or.imobil.eq.1) then
  call init_ale (nfabor, nnod)
endif

if (ncpdct.gt.0) then
  call init_kpdc
endif

if (nctsmt.gt.0) then
  call init_tsma ( nvar )
endif

if (nftcdt.gt.0) then
  call init_pcond ( nvar )
  call init_nz_pcond
endif

if (icond.eq.1) then
  call init_vcond ( nvar, ncelet )
endif

if (nfpt1t.gt.0) then
  call init_pt1d
endif

! Map arrays from Lagrangian module
if (iilagr.gt.0) then
  call init_lagr_arrays(tslagr)
endif

!===============================================================================
! Default initializations
!===============================================================================

call fldtri(nproce, dt, propce)

call field_allocate_or_map_all

call iniva0(nvar, nscal, dt, propce, frcxt, prhyd)

! Compute the porosity if needed
if (iporos.ge.1) then

  if (iihmpr.eq.1) then
    call uiporo(iporos)
  endif
  call usporo

  call field_get_val_s(ipori, porosi)

  if (irangp.ge.0.or.iperio.eq.1) then
    call synsca(porosi)
  endif

  do iel = 1, ncelet
    cell_f_vol(iel) = volume(iel) * porosi(iel)
  enddo

  ! For integral formulation, in case of 0 fluid volume, clip fluid faces
  if (iporos.eq.3) then
    do ifac = 1, nfac
      if (porosi(ifacel(1, ifac)).lt.epzero) then
        porosi(ifacel(1, ifac)) = 0.d0
        isolid_0(ifacel(1, ifac)) = 1

        suffac(1, ifac) = 0.d0
        suffac(2, ifac) = 0.d0
        suffac(3, ifac) = 0.d0
        suffan(ifac) = 0.d0
      else if (porosi(ifacel(2, ifac)).lt.epzero) then
        porosi(ifacel(2, ifac)) = 0.d0
        isolid_0(ifacel(2, ifac)) = 1

        suffac(1, ifac) = 0.d0
        suffac(2, ifac) = 0.d0
        suffac(3, ifac) = 0.d0
        suffan(ifac) = 0.d0
      endif
    enddo

    do ifac = 1, nfabor
      if (porosi(ifabor(ifac)).lt.epzero) then
        porosi(ifabor(ifac)) = 0.d0
        isolid_0(ifabor(ifac)) = 1

        suffbo(1, ifac) = 0.d0
        suffbo(2, ifac) = 0.d0
        suffbo(3, ifac) = 0.d0
        suffbn(ifac) = 0.d0
      endif
    enddo
  endif

endif

!==============================================================================
! On appelle cs_user_boundary_mass_source_terms lorqu'il y a sur un processeur
! au moins des cellules avec terme source de condensation.
! On ne fait que remplir le tableau d'indirection des cellules
! On appelle cependant cs_user_condensation avec tous les processeurs,
! au cas ou l'utilisateur aurait mis en oeuvre des operations globales.
!==============================================================================

if (nftcdt.gt.0) then

  iappel = 2

  call init_tagmr

  call init_nz_tagmr

  call cs_user_boundary_mass_source_terms &
( nvar   , nscal  ,                                              &
  nfbpcd , iappel ,                                              &
  ifbpcd , itypcd , izftcd ,                                     &
  spcond , rvoid(1) )

  call init_nz_mesh_tagmr

  ! the Condensation model coupled with a 0-D thermal model
  ! to take into account the metal mass structures effects.
  if(itagms.eq.1) then

    call init_tagms
  endif

endif

!===============================================================================
! Possible restart
!===============================================================================

! Timer statistics

restart_stats_id = timer_stats_id_by_name("checkpoint_restart_stage")
post_stats_id = timer_stats_id_by_name("postprocessing_stage")

if (isuite.eq.1) then

  call timer_stats_start(restart_stats_id)

  call lecamo(frcxt, prhyd)

  ! Using ALE, geometric parameters must be recalculated
  if (iale.eq.1) then

    call field_get_val_v(fdiale, disale)

    do inod = 1, nnod
      do idim = 1, ndim
        xyznod(idim,inod) = xyzno0(idim,inod) + disale(idim,inod)
      enddo
    enddo

    call algrma(volmin, volmax, voltot)

    ! Abort at the end of the current time-step if there is a negative volume
    if (volmin.le.0.d0) ntmabs = ntcabs

  endif

  call timer_stats_stop(restart_stats_id)

endif

!===============================================================================
! Initializations (user and additional)
!    dt rom romb viscl visct viscls (tpucou with periodicity)
!===============================================================================

call inivar(nvar, nscal, dt)

!===============================================================================
! Radiative transfer: possible restart
!===============================================================================

if (iirayo.gt.0) then
   call cs_rad_transfer_read
endif

!===============================================================================
! Initialize particles for Lagrangian module
!===============================================================================

if (iilagr.gt.0) then
  call laglec()
endif

!===============================================================================
! Initializations for the 1D thermal wall module
!===============================================================================

! On suppose que toutes les phases voient la meme temperature de paroi
! USPT1D a un fonctionnement similaire a USKPDC et USTSMA, mais comme
! on ecrit des infos dans un fichier suite, on a besoin d'une partie de
! la memoire meme apres la boucle en temps -> IFPT1D et TPPT1D
!                                            (IFNIA1 et IFNRA1)

! On appelle uspt1d lorqu'il y a sur un processeur au moins des faces de
!     bord avec module thermique 1D.

if (nfpt1t.gt.0) then
! Deuxieme appel : remplissage des tableaux de definition de la geometrie
!            et de l'initialisation (IFPT1D,NPPT1D,EPPT1D,RGPT1D,TPPT1D)
  iappel = 2
  call  uspt1d &
 ( nvar   , nscal  , nfpt1d , iappel ,                            &
   ifpt1d , izft1d , nppt1d , iclt1d ,                            &
   tppt1d , rgpt1d , eppt1d ,                                     &
   tept1d , hept1d , fept1d ,                                     &
   xlmbt1 , rcpt1d , dtpt1d ,                                     &
   dt     )

  iappel = 2
  call vert1d &
( nfabor , nfpt1d , iappel ,                                      &
  ifpt1d , nppt1d , iclt1d ,                                      &
  rgpt1d , eppt1d ,                                               &
  xlmbt1 , rcpt1d , dtpt1d )

!     Calcul du max des NPPT1D (pour les fichiers suite)
  nmxt1d = 0
  do iiii = 1, nfpt1d
    nmxt1d = max(nppt1d(iiii),nmxt1d)
  enddo
  if (irangp.ge.0) call parcmx(nmxt1d)

  if (isuit1.eq.1) then

    ficsui = '1dwall_module'
    call lect1d &
 ( ficsui , len(ficsui), nfpt1d , nfpt1t ,           &
   nmxt1d , nfabor     , nppt1d , ifpt1d , eppt1d , &
   rgpt1d , tppt1d )

  else
!     Creation du maillage, initialisation de la temperature.

    call mait1d &
 ( nfpt1d, nppt1d, eppt1d, rgpt1d, tppt1d )

  endif

endif

!     Les infos sur l'epaisseur de la paroi, le nombre de points de
!     discretisation et la raison geometrique ont ete transmises a
!     la structure C. Elles sont maintenant inutiles dans le Fortran.
!     -> on libere la memoire.

!===============================================================================
! Initialization for the Synthetic turbulence Inlets
!===============================================================================

nent = 0

call defsyn(nent)

if (isuisy.eq.1) then
  call lecsyn('les_inflow'//c_null_char)
endif

! ATMO MODULE : INITIALIZATION FOR THE SOIL MODEL (ippmo(iatmos) = 2)
!===============================================================================

if (ippmod(iatmos).ge.2.and.iatsoil.eq.1) then
  call atmsol()
endif

!===============================================================================
! Arrays for time block, to discard afterwards
!===============================================================================

! On appelle cs_user_head_losses lorqu'il y a sur un processeur au moins des
!     cellules avec terme source de masse.
!     On ne fait que remplir le tableau d'indirection des cellules
!     On appelle cependant cs_user_head_losses avec tous les processeurs,
!     au cas ou l'utilisateur aurait mis en oeuvre des operations globales.

if (ncpdct.gt.0) then

  iappel = 2

  if (iflow .eq.1) then
    do iel = 1, ncepdc
      icepdc(iel) = iel
    enddo
  endif

  if (iihmpr.eq.1) then
    call uikpdc(iappel, ncepdc, icepdc, ckupdc)
  endif

  call cs_user_head_losses &
( ncepdc , iappel ,                                              &
  icepdc , izcpdc ,                                              &
  dt     ,                                                       &
  ckupdc )

endif

! On appelle cs_user_mass_source_terms lorqu'il y a sur un processeur au moins
!     des cellules avec terme source de masse.
!     On ne fait que remplir le tableau d'indirection des cellules
!     On appelle cependant cs_user_mass_source_terms avec tous les processeurs,
!     au cas ou l'utilisateur aurait mis en oeuvre des operations globales.

if(nctsmt.gt.0) then

  iappel = 2
  call cs_user_mass_source_terms &
( nvar   , nscal  , ncepdc ,                                     &
  ncetsm , iappel ,                                              &
  icepdc ,                                                       &
  icetsm , itypsm , izctsm ,                                     &
  dt     ,                                                       &
  ckupdc , smacel )

endif


! -- Methode des vortex pour la L.E.S.
!    (dans verini on s'est deja assure que ITYTUR=4 si IVRTEX=1)

if (ivrtex.eq.1) then

  allocate(irepvo(nfabor))

  call vorin0(nfabor)

  iappel = 1

  call usvort &
 ( nvar   , nscal  , iappel ,                                     &
   dt     )

  call vorver (nfabor, iappel)

  call init_vortex

  call vorpre

endif

! -- Fin de zone Methode des vortex pour la L.E.S.

! -- Structures mobiles en ALE

if (iale.eq.1) then
  call strini(dt)
endif

! -- Fin de zone Structures mobiles en ALE

! -- Couplage Code_Saturne/Code_Saturne

call cscini(nvar)

!===============================================================================
! Start of time loop
!===============================================================================

write(nfecra,2000)

ntcabs = ntpabs
ttcabs = ttpabs

if (imobil.eq.1 .or. iturbo.eq.2)  ttcmob = ttpmob

iwarn0 = 1
do ivar = 1, nvar
  iwarn0 = max(iwarn0,iwarni(ivar))
enddo

if(iwarn0.gt.0) then
  write(nfecra,3000)
endif

if(inpdt0.eq.1) then
  ntmabs = ntcabs
endif

!     Nb d'iter ALE (nb relatif a l'execution en cours)
!     Si ITALIN=1, on fait une iteration d'initialisation
!     (si ITALIN=-999, c'est qu'on a fait une suite de calculs
!      sans relire lecamx -> comme si on faisait une suite
!      d'un calcul sans ALE)
if (italin.eq.-999) italin = 1
itrale = 1
if (italin.eq.1) then
  itrale = 0
  write(nfecra,3002) ttcabs
endif

!     En cas de couplage avec SYRTHES, on lit des maintenant l'entete
!     du premier message, au cas ou il s'agisse d'un message de
!     terminaison.

if (itrale.gt.0) then

  if (idtvar.eq.0) then
    call cplsyn (ntmabs, ntcabs, dt(1))
  else if (idtvar.ne.1) then ! synchronization in dttvar if idtvar = 1
    call cplsyn (ntmabs, ntcabs, dtref)
  endif

  if (ntmabs .eq. ntcabs .and. inpdt0.eq.0) then
    call csexit (1)
  endif

endif

 100  continue

if (inpdt0.eq.0 .and. itrale.gt.0) then
  ntcabs = ntcabs + 1
  call timer_stats_increment_time_step
  if(idtvar.eq.0.or.idtvar.eq.1) then
    ttcabs = ttcabs + dt(1)
  else
    ttcabs = ttcabs + dtref
  endif
  if (iwarn0.gt.0) then
    write(nfecra,3001) ttcabs,ntcabs
  endif
  if (imobil.eq.1 .or. iturbo.eq.2) then
    if(idtvar.eq.0.or.idtvar.eq.1) then
      ttcmob = ttcmob + dt(1)
    else
      ttcmob = ttcmob + dtref
    endif
  endif
endif


!===============================================================================
! Step forward in time
!===============================================================================

! Test presence of control_file to modify ntmabs if required
call cs_control_check_file

if (      (idtvar.eq.0 .or. idtvar.eq.1)                          &
    .and. (ttmabs.gt.0 .and. ttcabs.ge.ttmabs)) then
  ntmabs = ntcabs
endif

call dmtmps(titer1)

call tridim                                                       &
 ( itrale ,                                                       &
   nvar   , nscal  ,                                              &
   isostd ,                                                       &
   dt     ,                                                       &
   propce ,                                                       &
   frcxt  , prhyd  )


if (inpdt0.eq.0 .and. itrale.gt.0) then

  !===============================================================================
  ! Lagrangian module
  !===============================================================================

  if (iilagr.gt.0) then

    call timer_stats_start(lagr_stats_id)

    call cs_lagr_solve_time_step(itypfb, dt)

    call timer_stats_stop(lagr_stats_id)

  endif

  !===============================================================================
  ! Compute temporal means (accumulation)
  !===============================================================================
  call time_moment_update_all

endif

!===============================================================================
! Optional processing by user
!===============================================================================

if (itrale.gt.0) then

  call timer_stats_start(post_stats_id)

  ! Sortie postprocessing de profils 1D

  if (iihmpr.eq.1) then
    call uiprof()
  endif

  call cs_f_user_extra_operations &
 ( nvar   , nscal  ,                                              &
   dt     )

  call user_extra_operations()

  call timer_stats_stop(post_stats_id)

endif

!===============================================================================
! Update mesh (ALE)
!===============================================================================

if (iale.eq.1 .and. inpdt0.eq.0) then

  if (itrale.eq.0 .or. itrale.gt.nalinf) then

    call alemav &
  ( itrale ,                                               &
    impale , ialtyb ,                                      &
    dt     ,                                               &
    xyzno0 )

  endif

endif

!===============================================================================
! Stop tests
!===============================================================================

! Test for lack of remaining time

call armtps(ntcabs,ntmabs)

! Stop test for couplings

if (idtvar.eq.0) then
  call cplsyn (ntmabs, ntcabs, dt(1))
else if (idtvar.ne.1) then ! synchronization in dttvar if idtvar = 1
  call cplsyn (ntmabs, ntcabs, dtref)
endif

!===============================================================================
! Possible output of checkpoint files
!===============================================================================

call reqsui(iisuit)

if(ntcabs.lt.ntmabs .and.itrale.eq.0) iisuit = 0

if (iisuit.eq.1) then

  call timer_stats_start(restart_stats_id)

  if(ntcabs.lt.ntmabs) then
    if (iwarn0.gt.0) write(nfecra,3020) ntcabs, ttcabs
  else if(ntcabs.eq.ntmabs) then
    if(iwarn0.gt.0) write(nfecra,3021)ntcabs,ttcabs
  endif

  call ecrava(frcxt, prhyd)

  if (iturbo.eq.2 .and. iecaux.eq.1) then
    call trbsui
  endif

  if (nfpt1t.gt.0) then
    ficsui = '1dwall_module'
    call ecrt1d                                                   &
 ( ficsui   , len(ficsui), nfpt1d   ,  nmxt1d  ,                  &
   nfabor   , tppt1d     , ifpt1d )
  endif

  if (nent.gt.0) then
    call ecrsyn('les_inflow'//c_null_char)
  endif

  if (ippmod(iaeros).ge.0) then
    call ecrctw ('cooling_towers'//c_null_char)
  endif

  if (iilagr.gt.0) then
    call lagout()
  endif

  if (iirayo.gt.0) then
    call cs_rad_transfer_write
  endif

  call stusui

  call timer_stats_stop(restart_stats_id)

endif ! iisuit = 1

!===============================================================================
! Test to determine if a visualization output is generated
!===============================================================================

call post_activate_by_time_step

if (iihmpr.eq.1) then
  call uinpst(ntcabs, ttcabs)
endif

call cs_user_postprocess_activate(ntmabs, ntcabs, ttcabs)

!===============================================================================
! Standard visualization output
!===============================================================================

! If ITRALE=0, deactivate all writers, as geometry has not
!              been output yet.
if (itrale.eq.0) then
  call post_activate_writer(0, .false.)
endif

call timer_stats_start(post_stats_id)

call pstvar(ntcabs, nvar, nscal)

!===============================================================================
! Probes
!===============================================================================

if ((nthist.gt.0 .or.frhist.gt.0.d0) .and. itrale.gt.0) then

  modhis = -1
  if (frhist.gt.0.d0) then
    if ((ttcabs - ttchis) .gt. frhist*(1-1.0d-6)) then
      modhis = 1
    endif
  else if (nthist.gt.0 .and. mod(ntcabs, nthist).eq.0) then
    modhis = 1
  endif

  if (modhis.eq.1) then

    ttchis = ttcabs

    call ecrhis(modhis)

    ! if (iilagr.gt.0) then
    !   call laghis
    ! endif

    if (ihistr.eq.1) then
      call strhis(modhis)
    endif

  endif

endif

call ushist(nvar, nscal, dt)

!===============================================================================
! Write to "listing" every ntlist iterations
!===============================================================================

if (ntlist.gt.0) then
  modntl = mod(ntcabs,ntlist)
elseif(ntlist.eq.-1.and.ntcabs.eq.ntmabs) then
  modntl = 0
else
  modntl = 1
endif
if (modntl.eq.0) then

  call ecrlis &
  ( ncelet , ncel   ,                                    &
    dt     , volume )

  call log_iteration

endif

call timer_stats_stop(post_stats_id)

call dmtmps(titer2)

if (iwarn0.gt.0 .and. itrale.le.0) then
  write(nfecra,3012)titer2-titer1
endif

!===============================================================================
! End of time loop
!===============================================================================

itrale = itrale + 1

if (ntcabs.lt.ntmabs) goto 100

! Final synchronization for variable time step

if (idtvar.eq.1) then
  call cplsyn (ntmabs, ntcabs, dtref)
endif

! LIBERATION DES TABLEAUX INTERMEDIAIRES (PDC+TSM)

!===============================================================================
! Finalize probes
!===============================================================================

if(iwarn0.gt.0) then
  write(nfecra,4000)
endif

! Ici on sauve les historiques (si on en a stocke)

call timer_stats_start(post_stats_id)

modhis = 2
call ecrhis(modhis)

! if (iilagr.gt.0) then
!   call laghis
! endif

if (ihistr.eq.1) then
  call strhis(modhis)
endif

call timer_stats_stop(post_stats_id)

!     LE CAS ECHEANT, ON LIBERE LES STRUCTURES C DU MODULE THERMIQUE 1D
!     ET/OU ON FERME LE LISTING LAGRANGIEN

if (nfpt1d.gt.0) then
  call lbrt1d
endif

! Free main arrays
deallocate(dt, propce)

deallocate(isostd)
if (iphydr.eq.1) then
  deallocate(frcxt)
endif

if (iphydr.eq.2) then
  deallocate(prhyd)
endif

if (ivrtex.eq.1) then
  deallocate(irepvo)
endif

call turbomachinery_finalize

call radiat_finalize

call boundary_conditions_finalize

call finalize_aux_arrays

if (ippmod(iatmos).ge.0) then

  call finalize_meteo

  if(imbrication_flag)then
    call finalize_imbrication
  endif

  if (ifilechemistry.ge.1) then
    call finalize_chemistry
  endif

endif

if (ippmod(icompf).ge.0) then
  call finalize_compf
endif

if (iale.eq.1.or.imobil.eq.1) then
  call finalize_ale
endif

if (ncpdct.gt.0) then
  call finalize_kpdc
endif

if (nctsmt.gt.0) then
  call finalize_tsma
endif

if(nftcdt.gt.0) then
  call finalize_pcond
  call finalize_nz_pcond
  if (nztag1d.eq.1) then
    call finalize_nz_mesh_tagmr
    call finalize_nz_tagmr
    call finalize_tagmr
  endif
endif

if (icond.eq.1) then
  call finalize_vcond
  if (itagms.eq.1) then
    call finalize_tagms
  endif
endif

if (nfpt1d.gt.0) then
  call finalize_pt1d
endif

if (ivrtex.eq.1) then
  call finalize_vortex
endif

!===============================================================================
! Memory usage
!===============================================================================

!     Liberation des structures liees a la lecture du fichier xml

if (iihmpr.eq.1) then
  call memui2
  call memui1(ncharb)
endif

write(nfecra,7000)

!----
! Formats
!----

#if defined(_CS_LANG_FR)

 2000 format(/,/,                                                 &
'===============================================================',&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                       CORPS DU CALCUL                       ',/,&
'                       ===============                       ',/,&
                                                                /,&
                                                                /,&
'===============================================================',&
                                                              /,/,&
                                                                /)
 3000 format(/,                                                   &
'===============================================================',&
 /)
 3001 format(/,' INSTANT ',E18.9,        '   ITERATION NUMERO ',I15,/,  &
' ============================================================= ',&
 /,/)
 3002 format(/,' INSTANT ',E18.9,        '   INITIALISATION ALE ',/,    &
' ============================================================= ',&
 /,/)
 3012 format(/,' TEMPS POUR L''INITIALISATION ALE :    ',E14.5,/,/,     &
'===============================================================',&
 /)
 3020 format(/,/,                                                 &
 ' Sortie intermediaire de fichiers suite',/,                     &
 '   Sauvegarde a l''iteration ', I10, ', Temps physique ',E14.5,/,/)
 3021 format(/,/,                                                 &
 ' Sortie finale de fichiers suite',/,                     &
 '   Sauvegarde a l''iteration ', I10, ', Temps physique ',E14.5,/,/)

 4000 format(/,/,                                                 &
'===============================================================',&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                   ETAPES FINALES DU CALCUL                  ',/,&
'                   ========================                  ',/,&
                                                                /,&
                                                                /,&
' =========================================================== ',/,&
                                                                /,&
                                                                /)
 7000 format(/,/,                                                 &
' =========================================================== ',/,&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                 FIN DE L''EXECUTION DU CALCUL               ',/,&
'                 ============================                ',/,&
                                                                /,&
                                                                /,&
'===============================================================')

#else

 2000 format(/,/,                                                 &
'===============================================================',&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                       MAIN CALCULATION                      ',/,&
'                       ================                      ',/,&
                                                                /,&
                                                                /,&
'===============================================================',&
                                                              /,/,&
                                                                /)
 3000 format(/,                                                   &
'===============================================================',&
 /)
 3001 format(/,' INSTANT ',E18.9,        '   TIME STEP NUMBER ',I15,/,  &
' ============================================================= ',&
 /,/)
 3002 format(/,' INSTANT ',E18.9,        '   ALE INITIALIZATION ',/,    &
' ============================================================= ',&
 /,/)
 3012 format(/,' TIME FOR ALE INITIALIZATION:        ',E14.5,/,/, &
'===============================================================',&
 /)
 3020 format(/,/,                                                 &
 ' Write intermediate restart files',/,                           &
 '   checkpoint at iteration ',    I10,  ', Physical time ',E14.5,/,/)
 3021 format(/,/,                                                 &
 ' Write final restart files',/,                                  &
 '   checkpoint at iteration ',    I10,  ', Physical time ',E14.5,/,/)

 4000 format(/,/,                                                 &
'===============================================================',&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                 FINAL STAGE OF THE CALCULATION              ',/,&
'                 ==============================              ',/,&
                                                                /,&
                                                                /,&
' =========================================================== ',/,&
                                                                /,&
                                                                /)
 7000 format(/,/,                                                 &
' =========================================================== ',/,&
                                                              /,/,&
                                                                /,&
                                                                /,&
'                      END OF CALCULATION                     ',/,&
'                      ==================                     ',/,&
                                                                /,&
                                                                /,&
'===============================================================')

#endif

!----
! End
!----

return
end subroutine
