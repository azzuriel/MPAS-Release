! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html
!
module mpas_subdriver

   use mpas_framework
   use mpas_core
   use mpas_kind_types

   ! TODO: This should be moved inside the domain type?
   !       Unless we re-arrange modules, doing so would create a circular dependence
   !       between the mpas_grid_types and mpas_stream_manager modules.
   use mpas_stream_manager, only : MPAS_streamManager_type

   type (dm_info), pointer :: dminfo
   type (domain_type), save, target :: domain
   type (domain_type), pointer :: domain_ptr

   ! TODO: This should be moved inside the domain type?
   !       Unless we re-arrange modules, doing so would create a circular dependence
   !       between the mpas_grid_types and mpas_stream_manager modules.
   type (MPAS_streamManager_type), pointer :: stream_manager


   contains


   subroutine mpas_init()

      use mpas_stream_manager, only : MPAS_stream_mgr_init, MPAS_build_stream_filename
      use iso_c_binding, only : c_char, c_loc, c_ptr, c_int
      use mpas_c_interfacing, only : mpas_f_to_c_string, mpas_c_to_f_string
      use mpas_timekeeping, only : MPAS_Time_type, mpas_get_clock_time, mpas_get_time
      use mpas_bootstrapping, only : mpas_bootstrap_framework, mpas_setup_immutable_streams
 
      implicit none

      character(len=StrKIND) :: timeStamp
      integer :: ierr

      character(kind=c_char), dimension(StrKIND+1) :: c_filename       ! StrKIND+1 for C null-termination character
      integer(kind=c_int) :: c_comm
      integer(kind=c_int) :: c_ierr
      type (c_ptr) :: mgr_p
      character(len=StrKIND) :: mesh_stream
      character(len=StrKIND) :: mesh_filename
      character(len=StrKIND) :: mesh_filename_temp
      character(len=StrKIND) :: ref_time_temp
      character(len=StrKIND) :: filename_interval_temp
      character(kind=c_char), dimension(StrKIND+1) :: c_mesh_stream
      character(kind=c_char), dimension(StrKIND+1) :: c_mesh_filename_temp
      character(kind=c_char), dimension(StrKIND+1) :: c_ref_time_temp
      character(kind=c_char), dimension(StrKIND+1) :: c_filename_interval_temp
      type (MPAS_Time_type) :: start_time
      type (MPAS_Time_type) :: ref_time
      type (MPAS_TimeInterval_type) :: filename_interval
      character(len=StrKIND) :: start_timestamp


      interface
         subroutine xml_stream_parser(xmlname, mgr_p, comm, ierr) bind(c)
            use iso_c_binding, only : c_char, c_ptr, c_int
            character(kind=c_char), dimension(*), intent(in) :: xmlname
            type (c_ptr), intent(inout) :: mgr_p
            integer(kind=c_int), intent(inout) :: comm
            integer(kind=c_int), intent(out) :: ierr
         end subroutine xml_stream_parser

         subroutine xml_stream_get_attributes(xmlname, streamname, comm, filename, ref_time, filename_interval, ierr) bind(c)
            use iso_c_binding, only : c_char, c_int
            character(kind=c_char), dimension(*), intent(in) :: xmlname
            character(kind=c_char), dimension(*), intent(in) :: streamname
            integer(kind=c_int), intent(inout) :: comm
            character(kind=c_char), dimension(*), intent(in) :: filename
            character(kind=c_char), dimension(*), intent(in) :: ref_time
            character(kind=c_char), dimension(*), intent(in) :: filename_interval
            integer(kind=c_int), intent(out) :: ierr
         end subroutine xml_stream_get_attributes
      end interface


      domain_ptr => domain

      !
      ! Initialize infrastructure
      !
      call mpas_framework_init(dminfo, domain_ptr)
      call mpas_core_setup_packages(domain_ptr % configs, domain_ptr % packages, ierr)
      call mpas_core_setup_clock(domain_ptr % clock, domain_ptr % configs, ierr)

      call mpas_timer_start('total time')
      call mpas_timer_start('initialize')

      !
      ! Using information from the namelist, a graph.info file, and a file containing
      !    mesh fields, build halos and allocate blocks in the domain
      !
      call mpas_core_get_mesh_stream(domain_ptr % configs, mesh_stream, ierr)
      if (ierr /= 0) then
         call mpas_dmpar_abort(dminfo)
      end if
      call mpas_f_to_c_string(domain % streams_filename, c_filename)
      call mpas_f_to_c_string(mesh_stream, c_mesh_stream)
      c_comm = dminfo % comm
      call xml_stream_get_attributes(c_filename, c_mesh_stream, c_comm, &
                                     c_mesh_filename_temp, c_ref_time_temp, &
                                     c_filename_interval_temp, c_ierr)
      if (c_ierr /= 0) then
         call mpas_dmpar_abort(dminfo)
      end if
      call mpas_c_to_f_string(c_mesh_filename_temp, mesh_filename_temp)
      call mpas_c_to_f_string(c_ref_time_temp, ref_time_temp)
      call mpas_c_to_f_string(c_filename_interval_temp, filename_interval_temp)

      start_time = mpas_get_clock_time(domain_ptr % clock, MPAS_START_TIME, ierr)
      if ( trim(ref_time_temp) == 'initial_time' ) then
          call mpas_get_time(start_time, dateTimeString=ref_time_temp, ierr=ierr)
      end if

      if ( trim(filename_interval_temp) == 'none' ) then
          call mpas_expand_string(ref_time_temp, mesh_filename_temp, mesh_filename)
      else
          call mpas_set_time(ref_time, dateTimeString=ref_time_temp, ierr=ierr)
          call mpas_set_timeInterval(filename_interval, timeString=filename_interval_temp, ierr=ierr)
          call mpas_build_stream_filename(ref_time, start_time, filename_interval, mesh_filename_temp, mesh_filename, ierr)
      end if
      write(stderrUnit, *) ' ** Attempting to bootstrap MPAS framework using stream: ', trim(mesh_stream)
      call mpas_bootstrap_framework(domain_ptr, mesh_filename)

      !
      ! Set up run-time streams
      !
      call MPAS_stream_mgr_init(stream_manager, domain % clock, domain % blocklist % allFields, domain % packages, domain % blocklist % allStructs)

      call add_stream_attributes(stream_manager, domain)

      call mpas_setup_immutable_streams(stream_manager)

      mgr_p = c_loc(stream_manager)
      call xml_stream_parser(c_filename, mgr_p, c_comm, c_ierr)
      if (c_ierr /= 0) then
         call mpas_dmpar_abort(dminfo)
      end if


      !
      ! Initialize core
      !
      call mpas_core_init(domain_ptr, stream_manager, timeStamp)

      call mpas_timer_stop('initialize')

   end subroutine mpas_init


   subroutine mpas_run()

      implicit none

      call mpas_core_run(domain_ptr, stream_manager)

   end subroutine mpas_run


   subroutine mpas_finalize()

      use mpas_stream_manager, only : MPAS_stream_mgr_finalize
   
      implicit none


      !
      ! Finalize core
      !
      call mpas_core_finalize(domain_ptr, stream_manager)

      call mpas_timer_stop('total time')
      call mpas_timer_write()


      !
      ! Finalize infrastructure
      !
      call MPAS_stream_mgr_finalize(stream_manager)

      call mpas_framework_finalize(dminfo, domain_ptr)

   end subroutine mpas_finalize


   subroutine add_stream_attributes(stream_manager, domain)

      use mpas_stream_manager, only : MPAS_stream_mgr_add_att

      implicit none

      type (MPAS_streamManager_type), intent(inout) :: stream_manager
      type (domain_type), intent(inout) :: domain

      type (MPAS_Pool_iterator_type) :: itr
      integer, pointer :: intAtt
      logical, pointer :: logAtt
      character (len=StrKIND), pointer :: charAtt
      real (kind=RKIND), pointer :: realAtt
      character (len=StrKIND) :: histAtt

      integer :: local_ierr

      if (domain % dminfo % nProcs < 10) then
          write(histAtt, '(A,I1,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      else if (domain % dminfo % nProcs < 100) then
          write(histAtt, '(A,I2,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      else if (domain % dminfo % nProcs < 1000) then
          write(histAtt, '(A,I3,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      else if (domain % dminfo % nProcs < 10000) then
          write(histAtt, '(A,I4,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      else if (domain % dminfo % nProcs < 100000) then
          write(histAtt, '(A,I5,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      else
          write(histAtt, '(A,I6,A,A,A)') 'mpirun -n ', domain % dminfo % nProcs, ' ./', trim(domain % coreName), '_model'
      end if
     

      call MPAS_stream_mgr_add_att(stream_manager, 'on_a_sphere', domain % on_a_sphere)
      call MPAS_stream_mgr_add_att(stream_manager, 'sphere_radius', domain % sphere_radius)
      call MPAS_stream_mgr_add_att(stream_manager, 'model_name', domain % modelName)
      call MPAS_stream_mgr_add_att(stream_manager, 'core_name', domain % coreName)
      ! DWJ 10/01/2014: Eventually add the real history attribute, for now (due to length restrictions)
      ! add a shortened version.
!     call MPAS_stream_mgr_add_att(stream_manager, 'history', domain % history)
      call MPAS_stream_mgr_add_att(stream_manager, 'history', histAtt)
      call MPAS_stream_mgr_add_att(stream_manager, 'source', domain % source)
      call MPAS_stream_mgr_add_att(stream_manager, 'Conventions', domain % Conventions)
      call MPAS_stream_mgr_add_att(stream_manager, 'parent_id', domain % parent_id)
      call MPAS_stream_mgr_add_att(stream_manager, 'mesh_spec', domain % mesh_spec)
      call MPAS_stream_mgr_add_att(stream_manager, 'git_version', domain % git_version)

      call mpas_pool_begin_iteration(domain % configs)

      do while (mpas_pool_get_next_member(domain % configs, itr))

         if ( itr % memberType == MPAS_POOL_CONFIG) then

            if ( itr % dataType == MPAS_POOL_REAL ) then
               call mpas_pool_get_config(domain % configs, itr % memberName, realAtt)
               call MPAS_stream_mgr_add_att(stream_manager, itr % memberName, realAtt, ierr=local_ierr)
            else if ( itr % dataType == MPAS_POOL_INTEGER ) then
               call mpas_pool_get_config(domain % configs, itr % memberName, intAtt)
               call MPAS_stream_mgr_add_att(stream_manager, itr % memberName, intAtt, ierr=local_ierr)
            else if ( itr % dataType == MPAS_POOL_CHARACTER ) then
               call mpas_pool_get_config(domain % configs, itr % memberName, charAtt)
               call MPAS_stream_mgr_add_att(stream_manager, itr % memberName, charAtt, ierr=local_ierr)
            else if ( itr % dataType == MPAS_POOL_LOGICAL ) then
               call mpas_pool_get_config(domain % configs, itr % memberName, logAtt)
               if (logAtt) then
                  call MPAS_stream_mgr_add_att(stream_manager, itr % memberName, 'YES', ierr=local_ierr)
               else
                  call MPAS_stream_mgr_add_att(stream_manager, itr % memberName, 'NO', ierr=local_ierr)
               end if
            end if

          end if
      end do

   end subroutine add_stream_attributes

end module mpas_subdriver
