!
! Copyright (C) 2001-2012 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
! A small utility that reads the first q from a dynamical matrix file (either xml or plain text),
! recomputes the system symmetry (starting from the lattice) and generates the star of q.
!
! Useful for debugging and for producing the star of the wannier-phonon code output.
!
! Syntax:
!   q2qstar.x filein [fileout]
!
! fileout default: rot_filein (old format) or rot_filein.xml (new format)
!
!----------------------------------------------------------------------------
PROGRAM Q2QSTAR
  !----------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE constants,          ONLY : amu_ry
  USE parameters,         ONLY : ntypx
  USE mp,                 ONLY : mp_bcast
  USE mp_global,          ONLY : mp_startup, mp_global_end
  USE mp_world,           ONLY : world_comm
  USE io_global,          ONLY : ionode_id, ionode, stdout
  USE environment,        ONLY : environment_start, environment_end
  ! symmetry
  USE symm_base,          ONLY : s, invs, nsym, find_sym, set_sym_bl, irt, copy_sym, nrot, inverse_s
  ! for reading the dyn.mat.
  USE cell_base,          ONLY : at, bg, celldm, ibrav, omega
  USE ions_base,          ONLY : nat, ityp, ntyp => nsp, atm, tau, amass
  ! as above, unused here
  USE control_ph,         ONLY : xmldyn
  USE noncollin_module,   ONLY : m_loc, nspin_mag
  !
  USE dynmat,             ONLY : w2
  !
  ! for non-xml file only:
  USE dynamicalq,         ONLY : dq_phiq => phiq, dq_tau => tau, dq_ityp => ityp, zeu 
  ! fox xml files only
  USE io_dyn_mat,         ONLY : read_dyn_mat_param, read_dyn_mat_header, &
                                 read_dyn_mat, read_dyn_mat_tail, &
                                 write_dyn_mat_header
  ! small group symmetry
  USE lr_symm_base,       ONLY : rtau, nsymq, minus_q, irotmq, gi, gimq
  USE decompose_d2
  !
  IMPLICIT NONE
  !
  CHARACTER(len=7),PARAMETER :: CODE="Q2QSTAR"
  CHARACTER(len=256) :: fildyn, filout
  INTEGER :: ierr, nargs
  !
  INTEGER       :: nqs, isq (48), imq, nqq
  REAL(DP)      :: sxq(3, 48), xq(3), xqs(3,48), epsil(3,3)
  !
  LOGICAL :: sym(48), lrigid
  LOGICAL, EXTERNAL :: has_xml
  !
  COMPLEX(DP),ALLOCATABLE :: phi(:,:,:,:), d2(:,:), basis(:,:,:)
  REAL(DP),ALLOCATABLE :: decomposition(:)
  INTEGER :: i,j, icar,jcar, na,nb, rank
  !
  !NAMELIST / input / fildyn
  !
  CALL mp_startup()
  CALL environment_start(CODE)
  !
  nargs = command_argument_count()
  IF(nargs < 1) CALL errore(CODE, 'Argument is missing! Syntax: "q2qstar dynfile [outfile]"', 1)
  !
  CALL get_command_argument(1, fildyn)
  CALL mp_bcast(fildyn, ionode_id,world_comm)
  !
  ! check input
  IF (fildyn == ' ')  CALL errore (CODE,' bad fildyn',1)
  xmldyn=has_xml(fildyn)
  !
  ! set up output
  IF (nargs > 1) THEN
    CALL get_command_argument(2, filout)
  ELSE
      filout = "rot_"//TRIM(fildyn)
  ENDIF
  CALL mp_bcast(filout, ionode_id,world_comm)
  !
  ! ######################### reading ######################### 
  XML_FORMAT_READ : &
  IF (xmldyn) THEN
    ! read params
    CALL read_dyn_mat_param(fildyn,ntyp,nat)
    ALLOCATE(m_loc(3,nat))
    ALLOCATE(tau(3,nat))
    ALLOCATE(ityp(nat))
    ALLOCATE(zeu(3,3,nat))
    ALLOCATE(phi(3,3,nat,nat))
    ! read system information
    CALL read_dyn_mat_header(ntyp, nat, ibrav, nspin_mag, &
                             celldm, at, bg, omega, atm, amass, tau, ityp, &
                             m_loc, nqs, lrigid, epsil, zeu )
    ! read dyn.mat.
    CALL read_dyn_mat(nat,1,xq,phi)
    ! close file
    CALL read_dyn_mat_tail(nat)
    !
  ELSE XML_FORMAT_READ
    ! open file
    IF (ionode)OPEN (unit=1, file=fildyn,status='old',form='formatted',iostat=ierr)
    CALL mp_bcast(ierr, ionode_id,world_comm)
    IF (ierr /= 0) CALL errore(CODE,'file '//TRIM(fildyn)//' missing!',1)
    ! read everything, this use global variables
    ntyp = ntypx
    CALL read_dyn_from_file (nqs, xqs, epsil, lrigid,  &
        ntyp, nat, ibrav, celldm, at, atm, amass)
    !
    IF (ionode) CLOSE(unit=1)
    !
    xq = xqs(:,1)
    ALLOCATE(phi(3,3,nat,nat))
    ALLOCATE(tau(3,nat))
    ALLOCATE(ityp(nat))
    phi  = dq_phiq(:,:,:,:,1)
    tau =  dq_tau
    ityp = dq_ityp
    !zeu =  dq_zeu ! note: zeu from dynamicalq is a real(dp) array, zeu from control_ph is a flag (logical)
    amass = amass/amu_ry
    !
  ENDIF XML_FORMAT_READ
  !
  ! regenerate the lattice
  CALL latgen(ibrav,celldm,at(1,1),at(1,2),at(1,3),omega)
  at = at / celldm(1)  !  bring at in units of alat
  CALL volume(celldm(1),at(1,1),at(1,2),at(1,3),omega)
  CALL recips(at(1,1),at(1,2),at(1,3),bg(1,1),bg(1,2),bg(1,3))
  !
!   IF( nqs > 1) CALL errore(CODE, 'This code can in principle read dyn.mat. with the star of q, but it makes no sense', 1)
  WRITE(stdout,'(//,5x,a,3f14.9/)') "Dynamical matrix at q =", xq
  !
  ! ######################### symmetry setup #########################
  ! ~~~~~~~~ setup bravais lattice symmetry ~~~~~~~~ 
  CALL set_sym_bl ( )
  WRITE(stdout, '(5x,a,i3)') "Symmetries of bravais lattice: ", nrot
  !
  ! ~~~~~~~~ setup crystal symmetry ~~~~~~~~ 
  IF(.not.allocated(m_loc))  THEN
    ALLOCATE(m_loc(3,nat))
    m_loc = 0._dp
  ENDIF
  
  CALL find_sym ( nat, tau, ityp, .false., m_loc )
  WRITE(stdout, '(5x,a,i3)') "Symmetries of crystal:         ", nsym
  !
  ! ~~~~~~~~ setup small group of q symmetry ~~~~~~~~ 
  ! part 1: call smallg_q and the copy_sym, 
  minus_q = .true.
  sym = .false.
  sym(1:nsym) = .true.
  CALL smallg_q(xq, 0, at, bg, nsym, s, sym, minus_q)
  nsymq = copy_sym(nsym, sym)
  ! recompute the inverses as the order of sym.ops. has changed
  CALL inverse_s ( ) 
  ! part 2: this computes gi, gimq
  call set_giq (xq,s,nsymq,nsym,irotmq,minus_q,gi,gimq)
  WRITE(stdout, '(5x,a,i3)') "Symmetries of small group of q:", nsymq
  IF(minus_q) WRITE(stdout, '(10x,a)') "in addition sym. q -> -q+G:"
  !
  ! finally this does some of the above again and also computes rtau...
  ALLOCATE(rtau( 3, 48, nat))
  CALL sgam_lr(at, bg, nsym, s, irt, tau, rtau, nat)
  !
  ! the next subroutine uses symmetry from global variables
  CALL find_d2_symm_base(xq, rank, basis)
  !
  ALLOCATE(d2(3*nat,3*nat), w2(3*nat), decomposition(rank))
  CALL compact_dyn(nat, d2, phi)
  !  print*, d2
  print*, "== DECOMPOSITION =="
  DO i = 1,rank
    decomposition(i) = dotprodmat(3*nat,d2, basis(:,:,i))
    print*, i, decomposition(i)
  ENDDO
  !
  d2 = 0
  DO i = 1,rank
    d2 = d2 + decomposition(i)*basis(:,:,i)
  ENDDO

  DEALLOCATE(phi, d2, w2)
  DEALLOCATE(rtau, tau, ityp)
  IF( .not.xmldyn ) DEALLOCATE(dq_phiq, dq_tau, dq_ityp, zeu) ! from read_dyn_from_file
  IF( xmldyn) DEALLOCATE(zeu, m_loc)
  DEALLOCATE(irt) ! from symm_base
  !----------------------------------------------------------------------------
 END PROGRAM Q2QSTAR
!----------------------------------------------------------------------------
!
