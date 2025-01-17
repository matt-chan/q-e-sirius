!
! Copyright (C) 2001-2007 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!-----------------------------------------------------------------------
SUBROUTINE stres_cc_gpu( sigmaxcc )
  !-----------------------------------------------------------------------
  !
  USE kinds,                ONLY : DP
  USE atom,                 ONLY : rgrid, msh
  USE uspp_param,           ONLY : upf
  USE ions_base,            ONLY : ntyp => nsp
  USE cell_base,            ONLY : alat, omega, tpiba, tpiba2
  USE fft_base,             ONLY : dfftp
  USE fft_rho,              ONLY : rho_r2g
  USE gvect,                ONLY : ngm, gstart, ngl, gl, igtongl, igtongl_d
  USE ener,                 ONLY : etxc, vtxc
  USE lsda_mod,             ONLY : nspin
  USE scf,                  ONLY : rho, rho_core, rhog_core
  USE vlocal,               ONLY : strf
  USE control_flags,        ONLY : gamma_only
  USE mp_bands,             ONLY : intra_bgrp_comm
  USE mp,                   ONLY : mp_sum
  !
  USE gvect,                ONLY : g_d, gg_d
#if defined(__CUDA)
  USE device_fbuff_m,         ONLY : dev_buf
  USE device_memcpy_m,        ONLY : dev_memcpy
#endif
  !
  IMPLICIT NONE
  !
  ! output
  REAL(DP) :: sigmaxcc(3,3)
  ! local variables
  !
  INTEGER :: nt, ng, l, m, ir
  ! counters
  REAL(DP) :: fact
  REAL(DP), ALLOCATABLE :: vxc(:,:)
  COMPLEX(DP), ALLOCATABLE :: vaux(:,:)
  !
  REAL(DP), POINTER :: rhocg_d(:), r_d(:), rab_d(:), rhoc_d(:), gl_d(:)
  COMPLEX(DP), POINTER :: strf_d(:)
  !
  INTEGER :: maxmesh, ierrs(6)
  REAL(DP) :: sigma_rid, sigmadiag
  REAL(DP) :: sigma1, sigma2, sigma3, &
              sigma4, sigma5, sigma6
  !
#if defined(__CUDA)
  attributes(DEVICE) :: rhocg_d, r_d, rab_d, rhoc_d, gl_d, strf_d
  !
  sigmaxcc(:,:) = 0._DP
  IF ( ANY( upf(1:ntyp)%nlcc ) ) GOTO 15
  !
  RETURN
  !
15 CONTINUE
  !
  ! recalculate the exchange-correlation potential
  !
  ALLOCATE( vxc(dfftp%nnr,nspin), vaux(dfftp%nnr,1) )
  !
  CALL v_xc( rho, rho_core, rhog_core, etxc, vtxc, vxc )
  !
  !$acc data copyin(vxc) create(vaux)
  !
  IF ( nspin==2 ) THEN
     !$acc parallel loop
     DO ir = 1, dfftp%nnr
        vxc(ir,1) = 0.5d0 * ( vxc(ir,1) + vxc(ir,2) )
     ENDDO
  ENDIF
  !
  CALL rho_r2g( dfftp, vxc(:,1), vaux(:,1:1) ) 
  !
  ! vaux contains now Vxc(G)
  !
  sigmadiag = 0._DP
  !
  fact = 1._DP
  IF (gamma_only) fact = 2._DP
  !
  maxmesh = MAXVAL(msh(1:ntyp)) 
  CALL dev_buf%lock_buffer( gl_d, ngl, ierrs(1) )
  CALL dev_memcpy( gl_d, gl, (/ 1, ngl /) )
  CALL dev_buf%lock_buffer( rhocg_d,   ngl, ierrs(2) )
  CALL dev_buf%lock_buffer( r_d,   maxmesh, ierrs(3) )
  CALL dev_buf%lock_buffer( rab_d, maxmesh, ierrs(4) )
  CALL dev_buf%lock_buffer( rhoc_d,maxmesh, ierrs(5) )
  CALL dev_buf%lock_buffer( strf_d,    ngm, ierrs(6) )
  IF (ANY(ierrs /= 0)) CALL errore( 'stres_cc_gpu', 'cannot allocate buffers', -1 )
  !
  sigma1 = 0._DP ;  sigma4 = 0._DP
  sigma2 = 0._DP ;  sigma5 = 0._DP
  sigma3 = 0._DP ;  sigma6 = 0._DP
  !
  DO nt = 1, ntyp
     IF ( upf(nt)%nlcc ) THEN
        !
        CALL dev_memcpy( strf_d, strf(:,nt),  (/1, ngm/)     )
        CALL dev_memcpy( r_d,    rgrid(nt)%r, (/1, msh(nt)/) )
        CALL dev_memcpy( rab_d,  rgrid(nt)%rab,   (/1, msh(nt)/) )
        CALL dev_memcpy( rhoc_d, upf(nt)%rho_atc, (/1, msh(nt)/) )
        !
        CALL drhoc_gpu( ngl, gl_d, omega, tpiba2, msh(nt), r_d, &
                        rab_d, rhoc_d, rhocg_d )
        !
        ! diagonal term
        IF (gstart==2) THEN
          !$acc kernels
          sigmadiag = sigmadiag + DBLE(CONJG(vaux(1,1))*strf_d(1)) * &
                                  rhocg_d(igtongl_d(1))
          !$acc end kernels
        ENDIF
        !
        !$acc parallel loop
        DO ng = gstart, ngm
           sigmadiag = sigmadiag + DBLE(CONJG(vaux(ng,1)) * strf_d(ng)) * &
                                   rhocg_d(igtongl_d(ng)) * fact
        ENDDO
        !
        CALL deriv_drhoc_gpu( ngl, gl_d, omega, tpiba2, msh(nt), &
                              r_d, rab_d, rhoc_d, rhocg_d )
        !
        ! non diagonal term (g=0 contribution missing)
        !
        !$acc parallel loop reduction(+:sigma1,sigma2,sigma3,sigma4,sigma5,sigma6)
        DO ng = gstart, ngm
          !
          sigma_rid = DBLE(CONJG(vaux(ng,1)) &
                      * strf_d(ng)) * rhocg_d(igtongl_d(ng)) * tpiba &
                      / SQRT(gg_d(ng)) * fact
          !
          sigma1 = sigma1 + sigma_rid * g_d(1,ng)*g_d(1,ng)
          sigma2 = sigma2 + sigma_rid * g_d(1,ng)*g_d(2,ng)
          sigma3 = sigma3 + sigma_rid * g_d(1,ng)*g_d(3,ng)
          sigma4 = sigma4 + sigma_rid * g_d(2,ng)*g_d(2,ng)
          sigma5 = sigma5 + sigma_rid * g_d(3,ng)*g_d(2,ng)
          sigma6 = sigma6 + sigma_rid * g_d(3,ng)*g_d(3,ng)
          !
        ENDDO
        !
     ENDIF
     !
  ENDDO
  !
  sigmaxcc(1,1) = sigma1  ;  sigmaxcc(2,3) = sigma5
  sigmaxcc(1,2) = sigma2  ;  sigmaxcc(3,1) = sigma3
  sigmaxcc(1,3) = sigma3  ;  sigmaxcc(3,2) = sigma5
  sigmaxcc(2,1) = sigma2  ;  sigmaxcc(3,3) = sigma6
  sigmaxcc(2,2) = sigma4
  !
  DO l = 1, 3
     sigmaxcc(l,l) = sigmaxcc(l,l) + sigmadiag
  ENDDO 
  !
  CALL mp_sum( sigmaxcc, intra_bgrp_comm )
  !
  !$acc end data
  DEALLOCATE( vxc, vaux )
  CALL dev_buf%release_buffer( gl_d,   ierrs(1) )
  CALL dev_buf%release_buffer( rhocg_d,ierrs(2) )
  CALL dev_buf%release_buffer( r_d,    ierrs(3) )
  CALL dev_buf%release_buffer( rab_d,  ierrs(4) )
  CALL dev_buf%release_buffer( rhoc_d, ierrs(5) )
  CALL dev_buf%release_buffer( strf_d, ierrs(6) )
#endif
  !
  RETURN
  !
END SUBROUTINE stres_cc_gpu

