!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_mm_accdrv
   !! Fourth layer of the dbcsr matrix-matrix multiplication.
   !! It hides the differences between performing calculations on the
   !! accelerator device or on the CPU.
   !! <b>Modification history:</b>
   !! - 2010-02-23 Moved from dbcsr_operations
   !! - 2011-11    Moved parameter-stack processing routines to
   !! dbcsr_mm_methods.
   !! - 2013-01    extensive refactoring (Ole Schuett)
   !! - 2014-04    generalized into acc-framework (Ole Schuett)

   USE dbcsr_acc_devmem, ONLY: acc_devmem_allocate_bytes, &
                               acc_devmem_allocated, &
                               acc_devmem_deallocate, &
                               acc_devmem_host2dev, &
                               acc_devmem_setzero_bytes, &
                               acc_devmem_type
   USE dbcsr_acc_event, ONLY: acc_event_create, &
                              acc_event_destroy, &
                              acc_event_query, &
                              acc_event_record, &
                              acc_event_type, &
                              acc_stream_wait_event
   USE dbcsr_acc_hostmem, ONLY: acc_hostmem_allocate, &
                                acc_hostmem_deallocate
   USE dbcsr_acc_operations, ONLY: dbcsr_acc_do_mm_stack
   USE dbcsr_acc_stream, ONLY: acc_stream_associated, &
                               acc_stream_create, &
                               acc_stream_destroy, &
                               acc_stream_priority_range, &
                               acc_stream_synchronize, &
                               acc_stream_type
   USE dbcsr_block_operations, ONLY: block_add
   USE dbcsr_config, ONLY: dbcsr_cfg, &
                           default_resize_factor
   !accdrv_binning_binsize, accdrv_binning_nbins, accdrv_min_flop_sort, &
   !accdrv_posterior_buffers, accdrv_posterior_streams, accdrv_priority_buffers, &
   !accdrv_priority_streams, default_resize_factor, mm_stack_size
   USE dbcsr_data_methods, ONLY: dbcsr_data_dev2host, &
                                 dbcsr_data_ensure_size, &
                                 dbcsr_data_get_size, &
                                 dbcsr_data_get_type, &
                                 dbcsr_data_new, &
                                 dbcsr_data_release
   USE dbcsr_kinds, ONLY: default_string_length, &
                          int_4, &
                          int_4_size, &
                          int_8
   USE dbcsr_mem_methods, ONLY: dbcsr_mempool_destruct, &
                                dbcsr_mempool_limit_capacity, &
                                dbcsr_memtype_setup
   USE dbcsr_mm_types, ONLY: dbcsr_ps_acc_width, &
                             dbcsr_ps_width, &
                             stack_descriptor_type
   USE dbcsr_toollib, ONLY: sort
   USE dbcsr_types, ONLY: dbcsr_data_area_type, &
                          dbcsr_data_obj, &
                          dbcsr_memtype_type, &
                          dbcsr_type, &
                          dbcsr_work_type
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_mm_accdrv'

   LOGICAL, PARAMETER, PRIVATE :: careful_mod = .FALSE.

! **************************************************************************************************
   TYPE dbcsr_mm_accdrv_type
      PRIVATE
      TYPE(dbcsr_work_type), POINTER           :: product_wm => Null()
      TYPE(dbcsr_data_obj)                     :: c_buffer
      LOGICAL                                  :: phase_out = .FALSE.
      INTEGER                                  :: nbuffers_phaseout
      LOGICAL                                  :: c_area_copy = .TRUE.
   END TYPE dbcsr_mm_accdrv_type

! **************************************************************************************************

   PUBLIC :: dbcsr_mm_accdrv_type
   PUBLIC :: dbcsr_mm_accdrv_lib_init, dbcsr_mm_accdrv_lib_finalize
   PUBLIC :: dbcsr_mm_accdrv_phaseout, dbcsr_mm_accdrv_barrier
   PUBLIC :: dbcsr_mm_accdrv_init, dbcsr_mm_accdrv_finalize
   PUBLIC :: dbcsr_mm_accdrv_process
   PUBLIC :: dbcsr_mm_accdrv_dev2host_init

   ! ===== Global Accelerator Memory =====
   ! Allocating memory on the device and host-pinned is slow.
   ! Therefore, the memory is allocated once and stored in global variables.

   TYPE stack_buffer_type
      TYPE(acc_devmem_type)                  :: devmem
      INTEGER, DIMENSION(:, :), POINTER       :: hostmem => Null()
      TYPE(acc_event_type)                   :: ready
      TYPE(acc_event_type)                   :: calculated
      TYPE(acc_stream_type)                  :: stream
   END TYPE stack_buffer_type

   TYPE thread_private_type
      TYPE(stack_buffer_type), DIMENSION(:), POINTER     :: stack_buffers => Null()
      TYPE(dbcsr_memtype_type)                           :: memtype_cbuffer
      ! ensure that array-elements are on different cache lines
      INTEGER(kind=int_4), DIMENSION(64)                 :: padding
   END TYPE thread_private_type

   TYPE(thread_private_type), SAVE, DIMENSION(:), ALLOCATABLE, TARGET :: all_thread_privates
   TYPE(acc_stream_type), SAVE                            :: upload_stream
   TYPE(acc_stream_type), SAVE, DIMENSION(:), POINTER     :: posterior_streams => Null()
   TYPE(acc_stream_type), SAVE, DIMENSION(:), POINTER     :: priority_streams => Null()
   TYPE(acc_event_type), SAVE, DIMENSION(:), POINTER     :: barrier_events => Null()
   INTEGER, SAVE                                          :: barrier_counter = 0

CONTAINS

   SUBROUTINE dbcsr_mm_accdrv_lib_init()
      !! Initialize the library

      INTEGER                                            :: nthreads

      nthreads = 1
!$    nthreads = OMP_GET_NUM_THREADS()

!$OMP     MASTER
      ALLOCATE (all_thread_privates(0:nthreads - 1))
!$OMP     END MASTER
!$OMP     BARRIER
   END SUBROUTINE dbcsr_mm_accdrv_lib_init

   SUBROUTINE dbcsr_mm_accdrv_lib_finalize()
      !! Finalize the library

      INTEGER                                            :: ithread
      TYPE(thread_private_type), POINTER                 :: thread_privates

      ithread = 0
!$    ithread = OMP_GET_THREAD_NUM()
      thread_privates => all_thread_privates(ithread)

      IF (ASSOCIATED(thread_privates%stack_buffers)) &
         CALL deallocate_stackbuffers()

      IF (ASSOCIATED(thread_privates%memtype_cbuffer%pool)) &
         CALL dbcsr_mempool_destruct(thread_privates%memtype_cbuffer%pool)

!$OMP     BARRIER
!$OMP     MASTER
      DEALLOCATE (all_thread_privates)
!$OMP     END MASTER

      !How much memory is still allocated on the card?
      !istat = dbcsr_acc_dev_mem_info(mem_free, mem_avail)
      !WRITE (*,*) "after finalize acc mem: ",mem_free, mem_avail, istat

      CALL deallocate_streams()

   END SUBROUTINE dbcsr_mm_accdrv_lib_finalize

   SUBROUTINE dbcsr_mm_accdrv_init(this, product_wm, nlayers)
      !! Initializes a multiplication cycle for new set of C-blocks.
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this
      TYPE(dbcsr_work_type), POINTER                     :: product_wm
      INTEGER, OPTIONAL                                  :: nlayers

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_accdrv_init'

      INTEGER                                            :: handle, i, ithread, my_nlayers, nthreads
      TYPE(dbcsr_data_obj)                               :: c_area
      TYPE(thread_private_type), POINTER                 :: thread_privates

      CALL timeset(routineN, handle)

      nthreads = 1; ithread = 0
!$    nthreads = OMP_GET_NUM_THREADS(); ithread = OMP_GET_THREAD_NUM()
      thread_privates => all_thread_privates(ithread)

      ! Setup global data which is reused in between multiplications
      !------------------------------------------------------------------------
      CALL setup_streams()
      CALL setup_stackbuffers(this)

      !Each thread has its own memtype with its own mempool
      i = MOD(ithread, SIZE(priority_streams)) + 1
      CALL dbcsr_memtype_setup(thread_privates%memtype_cbuffer, has_pool=.TRUE., acc_hostalloc=.TRUE., &
                               acc_devalloc=.TRUE., acc_stream=priority_streams(i))
      my_nlayers = 1
      IF (PRESENT(nlayers)) my_nlayers = nlayers
      CALL dbcsr_mempool_limit_capacity(thread_privates%memtype_cbuffer%pool, capacity=my_nlayers)

      ! Setup things for this particular multiplication
      !------------------------------------------------------------------------
      this%product_wm => product_wm
      c_area = this%product_wm%data_area

      CALL dbcsr_data_new(this%c_buffer, data_type=dbcsr_data_get_type(c_area), &
                          data_size=dbcsr_data_get_size(c_area), memory_type=thread_privates%memtype_cbuffer)

      CALL acc_devmem_setzero_bytes(this%c_buffer%d%acc_devmem, &
                                    stream=this%c_buffer%d%memory_type%acc_stream)

      CALL acc_event_record(this%c_buffer%d%acc_ready, &
                            stream=this%c_buffer%d%memory_type%acc_stream)

      CALL timestop(handle)
   END SUBROUTINE dbcsr_mm_accdrv_init

   SUBROUTINE setup_streams()
      !! Helper routine used by dbcsr_mm_accdrv_init()

      INTEGER                                            :: greatest_priority, least_priority

!$OMP MASTER
      CALL acc_stream_priority_range(least_priority, greatest_priority)
      CALL stream_array_force_size(priority_streams, "Calc (priority)", &
                                   n=dbcsr_cfg%accdrv_priority_streams, priority=greatest_priority)
      CALL stream_array_force_size(posterior_streams, "Calc (posterior)", &
                                   n=dbcsr_cfg%accdrv_posterior_streams, events=barrier_events)

      !create upload stream
      IF (.NOT. acc_stream_associated(upload_stream)) &
         CALL acc_stream_create(upload_stream, "Stackbuf h2d")
!$OMP END MASTER
! Other threads have to wait until streams are created
!$OMP BARRIER

   END SUBROUTINE setup_streams

   SUBROUTINE deallocate_streams()
      !! Helper routine used by setup_streams() and dbcsr_mm_accdrv_lib_finalize()

!$OMP MASTER
      IF (acc_stream_associated(upload_stream)) &
         CALL acc_stream_destroy(upload_stream)

      CALL stream_array_force_size(priority_streams, "Calc (priority)", n=0)
      CALL stream_array_force_size(posterior_streams, "Calc (posterior)", n=0, events=barrier_events)
!$OMP END MASTER

   END SUBROUTINE deallocate_streams

   SUBROUTINE stream_array_force_size(streams, basename, n, events, priority)
      !! Helper routine
      TYPE(acc_stream_type), DIMENSION(:), POINTER       :: streams
      CHARACTER(len=*), INTENT(IN)                       :: basename
      INTEGER, INTENT(IN)                                :: n
      TYPE(acc_event_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: events
      INTEGER, INTENT(IN), OPTIONAL                      :: priority

      CHARACTER(len=default_string_length)               :: name
      INTEGER                                            :: i

      IF (ASSOCIATED(streams)) THEN
         IF (SIZE(streams) /= n) THEN
            DO i = 1, SIZE(streams)
               CALL acc_stream_destroy(streams(i))
               IF (PRESENT(events)) CALL acc_event_destroy(events(i))
            END DO
            DEALLOCATE (streams)
            IF (PRESENT(events)) DEALLOCATE (events)
         END IF
      END IF

      IF (.NOT. ASSOCIATED(streams) .AND. n > 0) THEN
         ALLOCATE (streams(n))
         IF (PRESENT(events)) ALLOCATE (events(n))
         DO i = 1, SIZE(streams)
            WRITE (name, "(A,I3)") TRIM(basename), i
            CALL acc_stream_create(streams(i), name=TRIM(name), priority=priority)
            IF (PRESENT(events)) CALL acc_event_create(events(i))
         END DO
      END IF
   END SUBROUTINE stream_array_force_size

   SUBROUTINE setup_stackbuffers(this)
      !! Helper routine used by dbcsr_mm_accdrv_init()
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this

      INTEGER                                            :: i, ithread, my_posterior_buffers, &
                                                            my_priority_buffers, my_total_buffers, &
                                                            nthreads
      INTEGER, SAVE                                      :: curr_posterior_stream = 0, &
                                                            curr_priority_stream = 0
      TYPE(thread_private_type), POINTER                 :: thread_privates

      nthreads = 1; ithread = 0
!$    nthreads = OMP_GET_NUM_THREADS(); ithread = OMP_GET_THREAD_NUM()
      thread_privates => all_thread_privates(ithread)

      ! distribute total number of buffers approx. evenly among threads
      ! my_* variables hold number of buffers for current thread.
      my_priority_buffers = CEILING(REAL(dbcsr_cfg%accdrv_priority_buffers)/REAL(nthreads), int_4)
      my_posterior_buffers = CEILING(REAL(dbcsr_cfg%accdrv_posterior_buffers)/REAL(nthreads), int_4)

      this%nbuffers_phaseout = my_priority_buffers
      my_total_buffers = my_posterior_buffers + my_priority_buffers

      IF (ASSOCIATED(thread_privates%stack_buffers)) THEN
         IF (SIZE(thread_privates%stack_buffers) /= my_total_buffers) &
            CALL deallocate_stackbuffers()
      ENDIF

      IF (.NOT. ASSOCIATED(thread_privates%stack_buffers)) THEN
         ALLOCATE (thread_privates%stack_buffers(my_total_buffers))
         !Done with OMP CRITICAL because curr_*_stream are shared.
!$OMP        CRITICAL(crit_setup_stackbuffers)
         DO i = 1, my_total_buffers
            CALL acc_devmem_allocate_bytes(thread_privates%stack_buffers(i)%devmem, &
                                           int_4_size*dbcsr_ps_acc_width*dbcsr_cfg%mm_stack_size)
            IF (i <= my_priority_buffers) THEN
               curr_priority_stream = MOD(curr_priority_stream, SIZE(priority_streams)) + 1
               thread_privates%stack_buffers(i)%stream = priority_streams(curr_priority_stream)
            ELSE
               curr_posterior_stream = MOD(curr_posterior_stream, SIZE(posterior_streams)) + 1
               thread_privates%stack_buffers(i)%stream = posterior_streams(curr_posterior_stream)
            ENDIF
            CALL acc_hostmem_allocate(thread_privates%stack_buffers(i)%hostmem, &
                                      dbcsr_ps_acc_width, dbcsr_cfg%mm_stack_size, thread_privates%stack_buffers(i)%stream)
            CALL acc_event_create(thread_privates%stack_buffers(i)%ready)
            CALL acc_event_create(thread_privates%stack_buffers(i)%calculated)
         END DO
!$OMP       END CRITICAL(crit_setup_stackbuffers)
      END IF
   END SUBROUTINE setup_stackbuffers

   SUBROUTINE deallocate_stackbuffers()
      !! Helper routine used by setup_stackbuffers() and dbcsr_mm_accdrv_lib_finalize()

      INTEGER                                            :: i, ithread
      TYPE(stack_buffer_type), DIMENSION(:), POINTER     :: stack_buffers

      ithread = 0
!$    ithread = OMP_GET_THREAD_NUM()
      stack_buffers => all_thread_privates(ithread)%stack_buffers

      DO i = 1, SIZE(stack_buffers)
         CALL acc_devmem_deallocate(stack_buffers(i)%devmem)
         CALL acc_hostmem_deallocate(stack_buffers(i)%hostmem, stack_buffers(i)%stream)
         CALL acc_event_destroy(stack_buffers(i)%ready)
         CALL acc_event_destroy(stack_buffers(i)%calculated)
      END DO
      DEALLOCATE (stack_buffers)
   END SUBROUTINE deallocate_stackbuffers

   SUBROUTINE dbcsr_mm_accdrv_dev2host_init(this)
      !! Finalizes a multiplication cycle for a set of C-blocks.
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this

! Transfer C-data from device to host and adding it to host's result

      IF (this%c_area_copy) THEN
         CALL dbcsr_data_dev2host(this%c_buffer)
         this%c_area_copy = .FALSE.
      ENDIF
   END SUBROUTINE dbcsr_mm_accdrv_dev2host_init

   SUBROUTINE dbcsr_mm_accdrv_finalize(this)
      !! Finalizes a multiplication cycle for a set of C-blocks.
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this

      TYPE(dbcsr_data_obj)                               :: c_area

! Transfer C-data from device to host and adding it to host's result

      IF (this%c_area_copy) THEN
         CALL dbcsr_data_dev2host(this%c_buffer)
      ENDIF
      CALL acc_stream_synchronize(this%c_buffer%d%memory_type%acc_stream)

      c_area = this%product_wm%data_area
      CALL block_add(c_area, this%c_buffer)
      CALL dbcsr_data_release(this%c_buffer)

   END SUBROUTINE dbcsr_mm_accdrv_finalize

   SUBROUTINE stack_sort(params_in, params_out, stack_size)
      !! Sort stack entries with respect to the c_id.
      INTEGER, INTENT(IN)                                :: stack_size
      INTEGER, &
         DIMENSION(dbcsr_ps_acc_width, stack_size), &
         INTENT(OUT)                                     :: params_out
      INTEGER, DIMENSION(dbcsr_ps_width, stack_size), &
         INTENT(IN)                                      :: params_in

      INTEGER                                            :: i
      INTEGER, DIMENSION(stack_size)                     :: c_sort, c_sort_ind

! sort by the C-blocks

      c_sort = params_in(6, :stack_size)
      CALL sort(c_sort, stack_size, c_sort_ind)
      DO i = 1, stack_size
         params_out(1:3, i) = params_in(4:6, c_sort_ind(i))
      END DO

   END SUBROUTINE stack_sort

   SUBROUTINE stack_binning(params_in, params_out, stack_size)
      !! Roughly order stacks with a cheaper Binning-scheme by Peter Messmer
      INTEGER, INTENT(IN)                                :: stack_size
      INTEGER, &
         DIMENSION(dbcsr_ps_acc_width, stack_size), &
         INTENT(OUT)                                     :: params_out
      INTEGER, DIMENSION(dbcsr_ps_width, stack_size), &
         INTENT(IN)                                      :: params_in

      INTEGER                                            :: bin_id, i, top
      INTEGER, DIMENSION(dbcsr_cfg%accdrv_binning_nbins) :: bin_top
      INTEGER, DIMENSION(dbcsr_ps_acc_width)             :: val
      INTEGER, DIMENSION(dbcsr_ps_acc_width, dbcsr_cfg% &
                         accdrv_binning_binsize, dbcsr_cfg% &
                         accdrv_binning_nbins)                           :: bin_arr

      bin_top = 1
      top = 1
      DO i = 1, stack_size
         val(1:3) = params_in(4:6, i)
         bin_id = 1 + INT(MODULO(INT(val(3)*(val(3) + 3), KIND=int_8), &
                                 INT(dbcsr_cfg%accdrv_binning_nbins, KIND=int_8)))
         IF (bin_top(bin_id) > dbcsr_cfg%accdrv_binning_binsize) THEN
            params_out(1:3, top:top + bin_top(bin_id) - 2) = bin_arr(1:3, 1:bin_top(bin_id) - 1, bin_id)
            top = top + bin_top(bin_id) - 1
            bin_top(bin_id) = 1
         ENDIF
         bin_arr(1:3, bin_top(bin_id), bin_id) = val(1:3)
         bin_top(bin_id) = bin_top(bin_id) + 1
      END DO
      DO i = 1, dbcsr_cfg%accdrv_binning_nbins
         IF (bin_top(i) > 1) THEN
            params_out(1:3, top:top + bin_top(i) - 2) = bin_arr(1:3, 1:bin_top(i) - 1, i)
            top = top + bin_top(i) - 1
         ENDIF
      END DO

   END SUBROUTINE stack_binning

   SUBROUTINE dbcsr_mm_accdrv_phaseout(this)
      !! Signal approaching end of multiplication
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this

      this%phase_out = .TRUE.
   END SUBROUTINE dbcsr_mm_accdrv_phaseout

   SUBROUTINE dbcsr_mm_accdrv_barrier()
      !! After being called by ALL threads, it installs a special barrier that
      !! forces the priority-streams to wait for the normal-streams.

      INTEGER                                            :: i, j, nthreads

      nthreads = 1
!$    nthreads = OMP_GET_NUM_THREADS()

!$OMP     CRITICAL
      barrier_counter = MOD(barrier_counter + 1, nthreads)
      IF (barrier_counter == 0) THEN
         DO i = 1, SIZE(posterior_streams)
            CALL acc_event_record(barrier_events(i), stream=posterior_streams(i))
            DO j = 1, SIZE(priority_streams)
               CALL acc_stream_wait_event(priority_streams(j), barrier_events(i))
            ENDDO
         ENDDO
      ENDIF
!$OMP     END CRITICAL
   END SUBROUTINE dbcsr_mm_accdrv_barrier

   SUBROUTINE dbcsr_mm_accdrv_process(this, left, right, params, stack_size, &
      !! Processes a given stack using accelerator
                                      stack_descr, success)
      TYPE(dbcsr_mm_accdrv_type), INTENT(INOUT)          :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      INTEGER, INTENT(IN)                                :: stack_size
      INTEGER, DIMENSION(dbcsr_ps_width, stack_size), &
         INTENT(INOUT)                                   :: params
      TYPE(stack_descriptor_type), INTENT(IN)            :: stack_descr
      LOGICAL, INTENT(OUT)                               :: success

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_accdrv_process'

      INTEGER                                            :: error_handle, error_handle2, &
                                                            flop_per_entry, i, ithread, &
                                                            stacked_datasize
      INTEGER, DIMENSION(:, :), POINTER                  :: stackbuf_hostmem_cropped
      TYPE(dbcsr_data_area_type), POINTER                :: a_area, b_area, c_area
      TYPE(stack_buffer_type), DIMENSION(:), POINTER     :: stack_buffers
      TYPE(stack_buffer_type), POINTER                   :: stackbuf

      NULLIFY (stackbuf, stackbuf_hostmem_cropped, stack_buffers)

      ithread = 0
!$    ithread = OMP_GET_THREAD_NUM()
      stack_buffers => all_thread_privates(ithread)%stack_buffers

      DO i = 1, SIZE(stack_buffers)
         IF (this%phase_out .AND. i > this%nbuffers_phaseout) EXIT
         IF (acc_event_query(stack_buffers(i)%calculated)) THEN
            stackbuf => stack_buffers(i)
            EXIT
         ENDIF
      ENDDO

      IF (.NOT. ASSOCIATED(stackbuf)) THEN
         success = .FALSE.
         RETURN
      END IF

      CALL timeset(routineN, error_handle)
      stacked_datasize = this%product_wm%datasize
      CALL dbcsr_data_ensure_size(this%c_buffer, stacked_datasize, &
                                  factor=default_resize_factor, zero_pad=.TRUE.)

      !===========================================================================
      ! sort the stack. Since this costs CPU time, only a good idea if the CPUs
      ! are not too busy, or device gain is very large
      CALL timeset(routineN//"_sort", error_handle2)
      flop_per_entry = 2*stack_descr%max_m*stack_descr%max_n*stack_descr%max_k

      IF (dbcsr_cfg%accdrv_stack_sort) THEN
         IF (flop_per_entry > dbcsr_cfg%accdrv_min_flop_sort) THEN
            CALL stack_sort(params, stackbuf%hostmem, stack_size)
         ELSE
            CALL stack_binning(params, stackbuf%hostmem, stack_size)
         END IF
      ELSE
         DO i = 1, stack_size
            stackbuf%hostmem(1:3, i) = params(4:6, i)
         END DO
      END IF

      CALL timestop(error_handle2)

      a_area => left%data_area%d
      b_area => right%data_area%d
      c_area => this%c_buffer%d

      !WRITE (*,*) "dbcsr_mm_accdrv_process: a_area%memory_type ", a_area%memory_type
      !WRITE (*,*) "dbcsr_mm_accdrv_process: b_area%memory_type ", b_area%memory_type
      !WRITE (*,*) "dbcsr_mm_accdrv_process: c_area%memory_type ", c_area%memory_type

      IF (.NOT. acc_devmem_allocated(a_area%acc_devmem)) &
         DBCSR_ABORT("dbcsr_mm_accdrv_process: a_area%acc_devmem not allocated")
      IF (.NOT. acc_devmem_allocated(b_area%acc_devmem)) &
         DBCSR_ABORT("dbcsr_mm_accdrv_process: b_area%acc_devmem not allocated")
      IF (.NOT. acc_devmem_allocated(c_area%acc_devmem)) &
         DBCSR_ABORT("dbcsr_mm_accdrv_process: c_area%acc_devmem not allocated")

      ! start uploading stacks only after a, b, and c are ready
      CALL acc_stream_wait_event(upload_stream, a_area%acc_ready)
      CALL acc_stream_wait_event(upload_stream, b_area%acc_ready)
      CALL acc_stream_wait_event(upload_stream, c_area%acc_ready)

      stackbuf_hostmem_cropped => stackbuf%hostmem(:, 1:stack_size)
      CALL acc_devmem_host2dev(stackbuf%devmem, hostmem=stackbuf_hostmem_cropped, stream=upload_stream)
      CALL acc_event_record(stackbuf%ready, stream=upload_stream)

      CALL acc_stream_wait_event(stackbuf%stream, stackbuf%ready)
      ! We have to sync for the C area for the cuBLAS dgemm, used for large kernels
      CALL acc_stream_wait_event(c_area%memory_type%acc_stream, stackbuf%ready)

      CALL dbcsr_acc_do_mm_stack(params, stackbuf%devmem, stack_size, c_area%data_type, &
                                 a_data=a_area%acc_devmem, &
                                 b_data=b_area%acc_devmem, &
                                 c_data=c_area%acc_devmem, &
                                 m_max=stack_descr%max_m, &
                                 n_max=stack_descr%max_n, &
                                 k_max=stack_descr%max_k, &
                                 def_mnk=stack_descr%defined_mnk, &
                                 stack_stream=stackbuf%stream, &
                                 c_stream=c_area%memory_type%acc_stream, &
                                 success=success)

      IF (success) THEN
         CALL acc_event_record(stackbuf%calculated, stream=stackbuf%stream)
         CALL acc_stream_wait_event(a_area%memory_type%acc_stream, stackbuf%calculated)
         CALL acc_stream_wait_event(b_area%memory_type%acc_stream, stackbuf%calculated)
         CALL acc_stream_wait_event(c_area%memory_type%acc_stream, stackbuf%calculated)
      ENDIF

      CALL timestop(error_handle)
   END SUBROUTINE dbcsr_mm_accdrv_process

END MODULE dbcsr_mm_accdrv
