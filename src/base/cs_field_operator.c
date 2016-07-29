/*============================================================================
 * Field based algebraic operators.
 *============================================================================*/

/*
  This file is part of Code_Saturne, a general-purpose CFD tool.

  Copyright (C) 1998-2016 EDF S.A.

  This program is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free Software
  Foundation; either version 2 of the License, or (at your option) any later
  version.

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
  details.

  You should have received a copy of the GNU General Public License along with
  this program; if not, write to the Free Software Foundation, Inc., 51 Franklin
  Street, Fifth Floor, Boston, MA 02110-1301, USA.
*/

/*----------------------------------------------------------------------------*/

#include "cs_defs.h"

/*----------------------------------------------------------------------------*/

/*----------------------------------------------------------------------------
 * Standard C library headers
 *----------------------------------------------------------------------------*/

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*----------------------------------------------------------------------------
 * Local headers
 *----------------------------------------------------------------------------*/

#include "bft_mem.h"
#include "bft_error.h"
#include "bft_printf.h"

#include "cs_field.h"
#include "cs_gradient.h"
#include "cs_gradient_perio.h"
#include "cs_halo.h"
#include "cs_mesh.h"
#include "cs_log.h"
#include "cs_map.h"
#include "cs_parameters.h"
#include "cs_parall.h"
#include "cs_mesh.h"
#include "cs_mesh_location.h"
#include "cs_mesh_quantities.h"

/*----------------------------------------------------------------------------
 * Header for the current file
 *----------------------------------------------------------------------------*/

#include "cs_field_operator.h"

/*----------------------------------------------------------------------------*/

BEGIN_C_DECLS

/*=============================================================================
 * Additional doxygen documentation
 *============================================================================*/

/*!
  \file cs_field_operator.c
        Field based algebraic operators.

  \enum cs_field_interpolate_t

  \brief Field interpolation modes

  \var CS_FIELD_INTERPOLATE_MEAN
       Mean element value (P0 interpolation)
  \var CS_FIELD_INTERPOLATE_GRADIENT
       Mean element value + gradient correction (pseudo-P1)
*/

/*! \cond DOXYGEN_SHOULD_SKIP_THIS */

/*=============================================================================
 * Macro definitions
 *============================================================================*/

/*============================================================================
 * Type definitions
 *============================================================================*/

/*============================================================================
 * Static global variables
 *============================================================================*/

/*============================================================================
 * Prototypes for functions intended for use only by Fortran wrappers.
 * (descriptions follow, with function bodies).
 *============================================================================*/

void
cs_f_field_gradient_scalar(int                    f_id,
                           int                    use_previous_t,
                           int                    imrgra,
                           int                    inc,
                           int                    recompute_cocg,
                           cs_real_3_t  *restrict grad);

void
cs_f_field_gradient_potential(int                    f_id,
                              int                    use_previous_t,
                              int                    imrgra,
                              int                    inc,
                              int                    recompute_cocg,
                              int                    hyd_p_flag,
                              cs_real_3_t            f_ext[],
                              cs_real_3_t  *restrict grad);

void
cs_f_field_gradient_vector(int                     f_id,
                           int                     use_previous_t,
                           int                     imrgra,
                           int                     inc,
                           cs_real_33_t  *restrict grad);

void cs_f_field_gradient_tensor(int                     f_id,
                                int                     use_previous_t,
                                int                     imrgra,
                                int                     inc,
                                cs_real_63_t  *restrict grad);

/*! (DOXYGEN_SHOULD_SKIP_THIS) \endcond */

/*============================================================================
 * Private function definitions
 *============================================================================*/

/*----------------------------------------------------------------------------
 * Interpolate field values at a given set of points using P0 interpolation.
 *
 * parameters:
 *   f                  <-- pointer to field
 *   n_points           <-- number of points at which interpolation
 *                          is required
 *   point_location     <-- location of points in mesh elements
 *                          (based on the field location)
 *   val                --> interpolated values
 *----------------------------------------------------------------------------*/

static void
_field_interpolate_by_mean(cs_field_t         *f,
                           cs_lnum_t           n_points,
                           const cs_lnum_t     point_location[],
                           cs_real_t          *val)
{
  for (cs_lnum_t i = 0; i < n_points; i++) {

    cs_lnum_t cell_id = point_location[i];

    for (cs_lnum_t j = 0; j < f->dim; j++)
      val[i*f->dim + j] =  f->val[cell_id*f->dim + j];

  }
}

/*----------------------------------------------------------------------------
 * Interpolate field values at a given set of points using gradient-corrected
 * interpolation.
 *
 * parameters:
 *   f                  <-- pointer to field
 *   n_points           <-- number of points at which interpolation
 *                          is required
 *   point_location     <-- location of points in mesh elements
 *                          (based on the field location)
 *   point_coords       <-- point coordinates
 *   val                --> interpolated values
 *----------------------------------------------------------------------------*/

static void
_field_interpolate_by_gradient(cs_field_t         *f,
                               cs_lnum_t           n_points,
                               const cs_lnum_t     point_location[],
                               const cs_real_3_t   point_coords[],
                               cs_real_t          *val)
{
  const cs_lnum_t dim = f->dim;
  const cs_lnum_t n_cells_ext = cs_glob_mesh->n_cells_with_ghosts;
  const cs_real_3_t *cell_cen
    = (const cs_real_3_t *)(cs_glob_mesh_quantities->cell_cen);

  /* Currently possible only for fields on cell location */

  if (f->location_id != CS_MESH_LOCATION_CELLS)
    bft_error(__FILE__, __LINE__, 0,
              _("Field gradient interpolation for field %s :\n"
                " not implemented for fields on location %s."),
              f->name, cs_mesh_location_type_name[f->location_id]);

  /* Get the calculation option from the field */

  cs_halo_type_t halo_type = CS_HALO_STANDARD;
  cs_gradient_type_t gradient_type = CS_GRADIENT_ITER;

  static int key_cal_opt_id = -1;
  if (key_cal_opt_id < 0)
    key_cal_opt_id = cs_field_key_id("var_cal_opt");

  if (key_cal_opt_id >= 0) {
    cs_var_cal_opt_t var_cal_opt;
    cs_field_get_key_struct(f, key_cal_opt_id, &var_cal_opt);
    cs_gradient_type_by_imrgra(var_cal_opt.imrgra,
                               &gradient_type,
                               &halo_type);
  }

  cs_real_t *grad;
  BFT_MALLOC(grad, 3*dim*n_cells_ext, cs_real_t);

  if (dim == 1)
    cs_field_gradient_scalar(f,
                             true, /* use_previous_t */
                             gradient_type,
                             halo_type,
                             1,    /* inc */
                             true, /* recompute_cocg */
                             (cs_real_3_t *)grad);
  else if (dim == 3)
    cs_field_gradient_vector(f,
                             true, /* use_previous_t */
                             gradient_type,
                             halo_type,
                             1,    /* inc */
                             (cs_real_33_t *)grad);

  else
    bft_error(__FILE__, __LINE__, 0,
              _("Field gradient interpolation for field %s of dimension %d:\n"
                " not implemented."),
              f->name, f->dim);

  /* Now interpolated values */

  for (cs_lnum_t i = 0; i < n_points; i++) {

    cs_lnum_t cell_id = point_location[i];

    cs_real_3_t d = {point_coords[i][0] - cell_cen[cell_id][0],
                     point_coords[i][1] - cell_cen[cell_id][1],
                     point_coords[i][2] - cell_cen[cell_id][2]};

    for (cs_lnum_t j = 0; j < f->dim; j++) {
      cs_lnum_t k = (cell_id*dim + j)*3;
      val[i*dim + j] =   f->val[cell_id*dim + j]
                       + d[0] * grad[k]
                       + d[1] * grad[k+1]
                       + d[2] * grad[k+2];
    }

  }

  BFT_FREE(grad);
}

/*============================================================================
 * Fortran wrapper function definitions
 *============================================================================*/

/*! \cond DOXYGEN_SHOULD_SKIP_THIS */

/*----------------------------------------------------------------------------
 * Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * parameters:
 *   f_id           <-- field id
 *   use_previous_t <-- should we use values from the previous time step ?
 *   imrgra         <-- gradient reconstruction mode
 *   inc            <-- if 0, solve on increment; 1 otherwise
 *   recompute_cocg <-- should COCG FV quantities be recomputed ?
 *   grad           --> gradient
 *----------------------------------------------------------------------------*/

void
cs_f_field_gradient_scalar(int                    f_id,
                           int                    use_previous_t,
                           int                    imrgra,
                           int                    inc,
                           int                    recompute_cocg,
                           cs_real_3_t  *restrict grad)
{
  cs_halo_type_t halo_type = CS_HALO_STANDARD;
  cs_gradient_type_t gradient_type = CS_GRADIENT_ITER;
  bool _use_previous_t = use_previous_t ? true : false;
  bool _recompute_cocg = recompute_cocg ? true : false;

  const cs_field_t *f = cs_field_by_id(f_id);

  cs_gradient_type_by_imrgra(imrgra,
                             &gradient_type,
                             &halo_type);

  cs_field_gradient_scalar(f,
                           _use_previous_t,
                           gradient_type,
                           halo_type,
                           inc,
                           _recompute_cocg,
                           grad);
}

/*----------------------------------------------------------------------------
 * Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * parameters:
 *   f_id           <-- field id
 *   use_previous_t <-- should we use values from the previous time step ?
 *   imrgra         <-- gradient reconstruction mode
 *   halo_type      <-- halo type
 *   inc            <-- if 0, solve on increment; 1 otherwise
 *   recompute_cocg <-- should COCG FV quantities be recomputed ?
 *   hyd_p_flag     <-- flag for hydrostatic pressure
 *   f_ext          <-- exterior force generating the hydrostatic pressure
 *   grad           --> gradient
 *----------------------------------------------------------------------------*/

void
cs_f_field_gradient_potential(int                    f_id,
                              int                    use_previous_t,
                              int                    imrgra,
                              int                    inc,
                              int                    recompute_cocg,
                              int                    hyd_p_flag,
                              cs_real_3_t            f_ext[],
                              cs_real_3_t  *restrict grad)
{
  cs_halo_type_t halo_type = CS_HALO_STANDARD;
  cs_gradient_type_t gradient_type = CS_GRADIENT_ITER;
  bool _use_previous_t = use_previous_t ? true : false;
  bool _recompute_cocg = recompute_cocg ? true : false;

  if (imrgra < 0)
    imrgra = 0;

  const cs_field_t *f = cs_field_by_id(f_id);

  cs_gradient_type_by_imrgra(imrgra,
                             &gradient_type,
                             &halo_type);

  cs_field_gradient_potential(f,
                              _use_previous_t,
                              gradient_type,
                              halo_type,
                              inc,
                              _recompute_cocg,
                              hyd_p_flag,
                              f_ext,
                              grad);
}

/*----------------------------------------------------------------------------
 * Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * parameters:
 *   f_id           <-- field id
 *   use_previous_t <-- should we use values from the previous time step ?
 *   imrgra         <-- gradient reconstruction mode
 *   inc            <-- if 0, solve on increment; 1 otherwise
 *   recompute_cocg <-- should COCG FV quantities be recomputed ?
 *   grad           --> gradient
 *----------------------------------------------------------------------------*/

void
cs_f_field_gradient_vector(int                     f_id,
                           int                     use_previous_t,
                           int                     imrgra,
                           int                     inc,
                           cs_real_33_t  *restrict grad)
{
  cs_halo_type_t halo_type = CS_HALO_STANDARD;
  cs_gradient_type_t gradient_type = CS_GRADIENT_ITER;
  bool _use_previous_t = use_previous_t ? true : false;

  const cs_field_t *f = cs_field_by_id(f_id);

  cs_gradient_type_by_imrgra(imrgra,
                             &gradient_type,
                             &halo_type);

  cs_field_gradient_vector(f,
                           _use_previous_t,
                           gradient_type,
                           halo_type,
                           inc,
                           grad);
}

/*----------------------------------------------------------------------------
 * Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * parameters:
 *   f_id           <-- field id
 *   use_previous_t <-- should we use values from the previous time step ?
 *   imrgra         <-- gradient reconstruction mode
 *   inc            <-- if 0, solve on increment; 1 otherwise
 *   recompute_cocg <-- should COCG FV quantities be recomputed ?
 *   grad           --> gradient
 *----------------------------------------------------------------------------*/

void cs_f_field_gradient_tensor(int                     f_id,
                                int                     use_previous_t,
                                int                     imrgra,
                                int                     inc,
                                cs_real_63_t  *restrict grad)
{
  cs_halo_type_t halo_type = CS_HALO_STANDARD;
  cs_gradient_type_t gradient_type = CS_GRADIENT_ITER;
  bool _use_previous_t = use_previous_t ? true : false;

  const cs_field_t *f = cs_field_by_id(f_id);

  cs_gradient_type_by_imrgra(imrgra,
                             &gradient_type,
                             &halo_type);

  cs_field_gradient_tensor(f,
                           _use_previous_t,
                           gradient_type,
                           halo_type,
                           inc,
                           grad);
}
/*! (DOXYGEN_SHOULD_SKIP_THIS) \endcond */

/*=============================================================================
 * Public function definitions
 *============================================================================*/

/*----------------------------------------------------------------------------*/
/*!
 * \brief Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * \param[in]       f               pointer to field
 * \param[in]       use_previous_t  should we use values from the previous
 *                                  time step ?
 * \param[in]       gradient_type   gradient type
 * \param[in]       halo_type       halo type
 * \param[in]       inc             if 0, solve on increment; 1 otherwise
 * \param[in]       recompute_cocg  should COCG FV quantities be recomputed ?
 * \param[out]      grad            gradient
 */
/*----------------------------------------------------------------------------*/

void
cs_field_gradient_scalar(const cs_field_t          *f,
                         bool                       use_previous_t,
                         cs_gradient_type_t         gradient_type,
                         cs_halo_type_t             halo_type,
                         int                        inc,
                         bool                       recompute_cocg,
                         cs_real_3_t      *restrict grad)
{
  int tr_dim = 0;
  int w_stride = 1;
  int key_cal_opt_id = cs_field_key_id("var_cal_opt");
  cs_real_t *weight = NULL;
  cs_var_cal_opt_t var_cal_opt;

  /* Get the calculation option from the field */
  cs_field_get_key_struct(f, key_cal_opt_id, &var_cal_opt);
  if (f->type & CS_FIELD_VARIABLE && var_cal_opt.iwgrec == 1) {
    if (var_cal_opt.idiff > 0) {
      int key_id = cs_field_key_id("gradient_weighting_id");
      int diff_id = cs_field_get_key_int(f, key_id);
      if (diff_id > -1) {
        cs_field_t *weight_f = cs_field_by_id(diff_id);
        weight = weight_f->val;
        w_stride = weight_f->dim;
      }
    }
  }

  cs_real_t *var = (use_previous_t) ? f->val_pre : f->val;

  cs_gradient_perio_init_rij(f, &tr_dim, grad);

  cs_gradient_scalar(f->name,
                     gradient_type,
                     halo_type,
                     inc,
                     recompute_cocg,
                     var_cal_opt.nswrgr,
                     tr_dim,
                     0, /* hyd_p_flag */
                     w_stride,
                     var_cal_opt.iwarni,
                     var_cal_opt.imligr,
                     var_cal_opt.epsrgr,
                     var_cal_opt.extrag,
                     var_cal_opt.climgr,
                     NULL, /* f_ext */
                     f->bc_coeffs->a,
                     f->bc_coeffs->b,
                     var,
                     weight,
                     grad);
}

/*----------------------------------------------------------------------------*/
/*!
 * \brief  Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * \param[in]       f               pointer to field
 * \param[in]       use_previous_t  should we use values from the previous
 *                                  time step ?
 * \param[in]       gradient_type   gradient type
 * \param[in]       halo_type       halo type
 * \param[in]       inc             if 0, solve on increment; 1 otherwise
 * \param[in]       recompute_cocg  should COCG FV quantities be recomputed ?
 * \param[in]       hyd_p_flag      flag for hydrostatic pressure
 * \param[in]       f_ext           exterior force generating
 *                                  the hydrostatic pressure
 * \param[out]      grad            gradient
 */
/*----------------------------------------------------------------------------*/

void
cs_field_gradient_potential(const cs_field_t          *f,
                            bool                       use_previous_t,
                            cs_gradient_type_t         gradient_type,
                            cs_halo_type_t             halo_type,
                            int                        inc,
                            bool                       recompute_cocg,
                            int                        hyd_p_flag,
                            cs_real_3_t                f_ext[],
                            cs_real_3_t      *restrict grad)
{
  int w_stride = 1;
  cs_real_t *var = (use_previous_t) ? f->val_pre : f->val;

  int key_cal_opt_id = cs_field_key_id("var_cal_opt");
  cs_real_t *weight = NULL;
  cs_var_cal_opt_t var_cal_opt;

  /* Get the calculation option from the field */
  cs_field_get_key_struct(f, key_cal_opt_id, &var_cal_opt);
  if (f->type & CS_FIELD_VARIABLE && var_cal_opt.iwgrec == 1) {
    if (var_cal_opt.idiff > 0) {
      int key_id = cs_field_key_id("gradient_weighting_id");
      int diff_id = cs_field_get_key_int(f, key_id);
      if (diff_id > -1) {
        cs_field_t *weight_f = cs_field_by_id(diff_id);
        weight = weight_f->val;
        w_stride = weight_f->dim;
      }
    }
  }

  cs_gradient_scalar(f->name,
                     gradient_type,
                     halo_type,
                     inc,
                     recompute_cocg,
                     var_cal_opt.nswrgr,
                     0, /* tr_dim */
                     hyd_p_flag,
                     w_stride,
                     var_cal_opt.iwarni,
                     var_cal_opt.imligr,
                     var_cal_opt.epsrgr,
                     var_cal_opt.extrag,
                     var_cal_opt.climgr,
                     f_ext,
                     f->bc_coeffs->a,
                     f->bc_coeffs->b,
                     var,
                     weight,
                     grad);
}

/*----------------------------------------------------------------------------*/
/*!
 * \brief  Compute cell gradient of scalar field or component of vector or
 * tensor field.
 *
 * \param[in]       f               pointer to field
 * \param[in]       use_previous_t  should we use values from the previous
 *                                  time step ?
 * \param[in]       gradient_type   gradient type
 * \param[in]       halo_type       halo type
 * \param[in]       inc             if 0, solve on increment; 1 otherwise
 * \param[out]      grad            gradient
 */
/*----------------------------------------------------------------------------*/

void
cs_field_gradient_vector(const cs_field_t          *f,
                         bool                       use_previous_t,
                         cs_gradient_type_t         gradient_type,
                         cs_halo_type_t             halo_type,
                         int                        inc,
                         cs_real_33_t     *restrict grad)
{
  int key_cal_opt_id = cs_field_key_id("var_cal_opt");
  cs_var_cal_opt_t var_cal_opt;

  /* Get the calculation option from the field */
  cs_field_get_key_struct(f, key_cal_opt_id, &var_cal_opt);

  cs_real_3_t *var = (use_previous_t) ? (cs_real_3_t *)(f->val_pre)
                                      : (cs_real_3_t *)(f->val);

  cs_gradient_vector(f->name,
                     gradient_type,
                     halo_type,
                     inc,
                     var_cal_opt.nswrgr,
                     var_cal_opt.iwarni,
                     var_cal_opt.imligr,
                     var_cal_opt.epsrgr,
                     var_cal_opt.climgr,
                     (const cs_real_3_t *)(f->bc_coeffs->a),
                     (const cs_real_33_t *)(f->bc_coeffs->b),
                     var,
                     grad);
}

/*----------------------------------------------------------------------------*/
/*!
 * \brief  Compute cell gradient of tensor field.
 *
 * \param[in]       f               pointer to field
 * \param[in]       use_previous_t  should we use values from the previous
 *                                  time step ?
 * \param[in]       gradient_type   gradient type
 * \param[in]       halo_type       halo type
 * \param[in]       inc             if 0, solve on increment; 1 otherwise
 * \param[out]      grad            gradient
 */
/*----------------------------------------------------------------------------*/

void
cs_field_gradient_tensor(const cs_field_t          *f,
                         bool                       use_previous_t,
                         cs_gradient_type_t         gradient_type,
                         cs_halo_type_t             halo_type,
                         int                        inc,
                         cs_real_63_t     *restrict grad)
{
  int key_cal_opt_id = cs_field_key_id("var_cal_opt");
  cs_var_cal_opt_t var_cal_opt;

  /* Get the calculation option from the field */
  cs_field_get_key_struct(f, key_cal_opt_id, &var_cal_opt);

  cs_real_6_t *var = (use_previous_t) ? (cs_real_6_t *)(f->val_pre)
                                      : (cs_real_6_t *)(f->val);

  cs_gradient_tensor(f->name,
                     gradient_type,
                     halo_type,
                     inc,
                     var_cal_opt.nswrgr,
                     var_cal_opt.iwarni,
                     var_cal_opt.imligr,
                     var_cal_opt.epsrgr,
                     var_cal_opt.climgr,
                     (const cs_real_6_t *)(f->bc_coeffs->a),
                     (const cs_real_66_t *)(f->bc_coeffs->b),
                     var,
                     grad);
}

/*----------------------------------------------------------------------------*/
/*!
 * \brief Interpolate field values at a given set of points.
 *
 * \param[in]   f                   pointer to field
 * \param[in]   interpolation_type  interpolation type
 * \param[in]   n_points            number of points at which interpolation
 *                                  is required
 * \param[in]   point_location      location of points in mesh elements
 *                                  (based on the field location)
 * \param[in]   point_coords        point coordinates
 * \param[out]  val                 interpolated values
 */
/*----------------------------------------------------------------------------*/

void
cs_field_interpolate(cs_field_t              *f,
                     cs_field_interpolate_t   interpolation_type,
                     cs_lnum_t                n_points,
                     const cs_lnum_t          point_location[],
                     const cs_real_3_t        point_coords[],
                     cs_real_t               *val)
{
  switch (interpolation_type) {

  case CS_FIELD_INTERPOLATE_MEAN:
    _field_interpolate_by_mean(f,
                               n_points,
                               point_location,
                               val);
    break;

  case CS_FIELD_INTERPOLATE_GRADIENT:
    _field_interpolate_by_gradient(f,
                                   n_points,
                                   point_location,
                                   point_coords,
                                   val);
    break;

  default:
    assert(0);
    break;
  }
}

/*----------------------------------------------------------------------------*/

END_C_DECLS