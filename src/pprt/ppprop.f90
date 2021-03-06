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

subroutine ppprop
!================

!===============================================================================
!  FONCTION  :
!  ---------

! INIT DES POSITIONS DES VARIABLES D'ETAT SELON
!   LE TYPE DE PHYSIQUE PARTICULIERE

!-------------------------------------------------------------------------------
! Arguments
!__________________.____._____.________________________________________________.
! name             !type!mode ! role                                           !
!__________________!____!_____!________________________________________________!
!__________________!____!_____!________________________________________________!

!     Type: i (integer), r (real), s (string), a (array), l (logical),
!           and composite types (ex: ra real array)
!     mode: <-- input, --> output, <-> modifies data, --- work array
!===============================================================================

!===============================================================================
! Module files
!===============================================================================

use paramx
use dimens
use numvar
use optcal
use cstphy
use entsor
use cstnum
use ppppar
use ppthch
use coincl
use cpincl
use atincl
use ppincl

!===============================================================================

implicit none

! Local variables

character(len=80) :: name_d, label_d

integer          idim1
logical       :: has_previous

!===============================================================================

! ---> Physique particuliere : Combustion Gaz

if (ippmod(icod3p).ge.0 .or. ippmod(icoebu).ge.0                 &
                        .or. ippmod(icolwc).ge.0) then
  call coprop
endif

! ---> Physique particuliere :  Combustion Charbon Pulverise

if (ippmod(iccoal).ge.0) then
  call cs_coal_prop
endif

! ---> Physique particuliere :  Combustion Charbon Pulverise
!      Couplee Transport Lagrangien des particules de charbon

if (ippmod(icpl3c).ge.0) then
  call cplpro
endif

! ---> Physique particuliere : Combustion Fuel

if (ippmod(icfuel).ge.0) then
  call cs_fuel_prop
endif

! ---> Physique particuliere : Compressible

if (ippmod(icompf).ge.0) then
  call cfprop
endif

! ---> Physique particuliere : Versions electriques

if (ippmod(ieljou).ge.1 .or.                                     &
    ippmod(ielarc).ge.1) then
  call elprop(ippmod(ieljou), ippmod(ielarc))
endif

! ---> Physique particuliere : Atmospherique

! ---> Atmospheric modules:
!      dry and humid atmosphere (ippmod(iatmos) = 1,2)
if (ippmod(iatmos).ge.1) then
  call atprop
endif

! Add the mixture molar mass fraction field
if (ippmod(igmix).ge.0) then
  call add_property_field('mix_mol_mas', 'Mix_mol_mass', igmxml)

  ! Gas mixtures with Air/Helium and the Helium gas deduced
  if (ippmod(igmix).eq.0) then
    name_d = 'y_he'
    label_d = 'Y_He'
   ! Gas mixtures with Air/Hydrogen and the Hydrogen gas deduced
  else if (ippmod(igmix).eq.1) then
    name_d = 'y_h2'
    label_d = 'Y_H2'
  ! Gas mixtures with steam with/without condensation modelling
  ! the steam gas will be deduced from the gas species transported
  else if (ippmod(igmix).ge.2.and.ippmod(igmix).le.4) then
    name_d = 'y_h2o_g'
    label_d = 'Y_H2O_g'
  ! Gas mixtures with Helium/Air Helium and the O2 from the air deduced
  else if (ippmod(igmix).eq.5) then
    name_d = 'y_o2'
    label_d = 'Y_O2'
  endif

  idim1 =  1
  has_previous = .true.
  call add_property_field_owner(name_d, label_d, idim1, has_previous, iddgas)
endif

end subroutine ppprop
