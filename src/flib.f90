!vim:comments+=fb:!
!
! Fortran extension module. Here we code speed-critical stuff.
!
! Compilation / usage
! -------------------
! See Makefile for compilation.
!
! Use the f2py Python wrapper function directly as _flib.<function>(...)
!
! To see the function signature of the f2py wrapper function, do:
!   $ python -c 'from pwtools import _flib; print _flib.<function>.__doc__'
!
! Remove "!verbose" below to get some OpenMP debugging infos.
!
! stdout/stderr
! -------------
! write(*,*) or write(6,*) write to stdout, write(0,*) to stderr. This works for
! redirecting text in the shell:
!   ./a.out > foo
!   ./a.out > foo 2>&1
! But it does not work for Fortran extensions. For instance, nose (testing) still
! prints stdout messages from Fortran extensions instead of catching them. AFAIK,
! there is no eays (read: f2py builtin) solution. If you know better, send me an
! email -- or a patch!
!
! f2py notes
! ==========
!
! passing variables
! -----------------
! Doc:
! [1] http://cens.ioc.ee/projects/f2py2e/usersguide/index.html
! [2] http://www.sagemath.org/doc/numerical_sage/f2py.html
!
! A Fortran subroutine always needs to get input and pre-allocated result
! arrays. The result arrays get overwriten inside the subroutine. This is in
! contrast to Python fuctions, which usually only take input args and allocate
! all return args on the fly inside and return them.
!
! In f2py, all args to a subroutine are "!f2py intent(in)" by default.
!
! All variables declared as "intent(out) foo" will be returned in a tuple (if
! there is more then one). Note that there must be one "intent(out)" line for
! *each* arg. Also, the order in the tuple is the one of the input args.
!
! There are basically 2 (well, 2.5) ways of wrapping a subroutine:
!
! (1) the python wrapper doesn't pre-allocate and pass result arrays. The
! Fortran routine looks like this::
!
!     subroutine foo(a, b, c, d, n)
!         implicit none
!         integer :: n
!         double precision :: a(n,n), b(n,n), c(n,n), d(n,n)
!         !f2py intent(out) :: c
!         !f2py intent(out) :: d
!         c = matmul(a,b)
!         d = matmul(a,b)*2.0d0
!     end subroutine foo
!
! and the call signature would be::
!
!      c,d = foo(a,b,[n])
!
! It takes only the inputs `a` and `b` and well as `n` as optional arg, which is
! determined from `a` and `b`'s array dimension if not given. This is the most
! easy and pythonic way. In that case, the output arrays `c` and `d` are
! allocated in Fortran in F order. Note that you don't need to pass them when
! calling the wrapper.
!
! Note: It used to be that `c` and `d` are copied to C order when the f2py
! wrapper function returns. But see method 3 below!
!
! (2) Explicitely allocate result arrays on python side and pass in.
!
!     subroutine foo(a, b, c, d, n)
!         implicit none
!         integer :: n
!         double precision :: a(n,n), b(n,n), c(n,n), d(n,n)
!         !f2py intent(in,out) :: c
!         !f2py intent(in,out) :: d
!         c = matmul(a,b)
!         d = matmul(a,b)*2.0d0
!     end subroutine foo
!
! Here, we changed the f2py statement to "!f2py intent(in,out)", telling f2py
! that the user must supply `c` and `d` explicitely. The signature is now::
!
!     c,d = foo(a,b,c,d,[n])
!
! In that case, there are two usage pattern in Python: (A) One can call the wrapper
! with or (B) without return args b/c the result arrays get overwritten in-place.
!
!     c = np.empty(..., order='F')  # allocate result array
!     d = np.empty(..., order='F')
!
!     _flib(a,b,c,d)                # variant A
!     c,d = _flib(a,b,c,d)          # variant B
!
!
! (3) Don't use f2py comment lines and get F order arrays back without passing
! them in.
!
! Last time I checked (numpy 1.7.1) and with a prototype *without* special f2py
! comment lines, `c` and `d` are allocated in Fortran and also passed back to
! Python as order='F' arrays, i.e. without making a copy to C order.
!
!     subroutine foo(a, b, c, d, n)
!         implicit none
!         integer :: n
!         double precision, intent(in) :: a(n,n), b(n,n)
!         double precision, intent(out) :: c(n,n), d(n,n)
!         c = matmul(a,b)
!         d = matmul(a,b)*2.0d0
!     end subroutine foo
!
! and the f2py wrapper signature as in case (1)::
!
!      c,d = foo(a,b,[n])
!
! This is the best version b/c we don't need to explicitely allocate `c` and `d`
! in F order in Python and pass in + we get F order arrys back w/o a copy. This
! is cool as long as we don't need C-order arrays in Python.
!
! C/F-order arrays and copies (method 1 and 2 only)
! -------------------------------------------------
!
! By default, the f2py wrapper will make a copy of each numpy input array which
!
!   * has rank >= 2
!   * order='C'
!
! and each output array (F to C order) which was not explicitely passed in.
! This can be a real bottleneck for big arrays, sometimes performing much slower
! than the actual calculations! Use f2py -DF2PY_REPORT_ON_ARRAY_COPY=1 ... if
! you really want to know when.
!
! According to [2], the best way to avoid array copies between Python and
! Fortran is to use method (2) and allocate all input and output arrays in
! Python in F-order (e.g. np.empty(<shape>, order='F')). For input arrays, use
! "intent(in)", for outputs use "intent (in,out)" or "intent
! (in,out,overwrite)". The latter case will add an arg ``overwrite_foo`` which
! defaults to 1 (True). If input arrays are small, passing them as C order might
! be OK.
!
! As mentioned, also method (3) doesn't make any copy if all input arrays (a and
! b) are F-order. No need to do anything with c and d here. This seems to be
! the best solution currently. Maybe we should check the f2py changelog more
! often ...

#define stdout 6
#define stderr 0

subroutine vacf(v, m, c, method, use_m, nthreads, natoms, nstep)
    ! Normalized vacf: c_vv(t) = C_vv(t) / C_vv(0) for atomic velocities stored
    ! in 3d array `v`.
    !
    ! method=1: loops
    ! method=2: vectorized, but makes a copy of `v`
#ifdef __OPENMP
    use omp_lib
    !f2py threadsafe
#endif
    implicit none
    integer, intent(in) :: natoms, nstep, method, use_m
    integer, intent(in), optional ::  nthreads
    double precision, intent(in) :: v(0:nstep-1, 0:natoms-1, 0:2)
    double precision, intent(in) :: m(0:natoms-1)
    double precision, intent(out) :: c(0:nstep-1)
    character(len=*), parameter :: this='[_flib.so:vacf] '
    integer ::  t, i, j, k
    ! for mass vector in method 2
    double precision :: vv(0:nstep-1, 0:natoms-1, 0:2)
    !f2py intent(in, out) c
#ifdef __OPENMP
    ! Check if env vars are recognized.
    ! getenv() is implemented in gfortran and ifort.
    !
    !! character(100) :: OMP_NUM_THREADS
    !! call getenv('OMP_NUM_THREADS', OMP_NUM_THREADS)
    !! write(*,*) 'OMP_NUM_THREADS: ', OMP_NUM_THREADS

    ! With f2py, "if (present(nthreads)) then ..." doesn't work for 'optional'
    ! input args. nthreads is alawys present. When it is not
    ! supplied, the if clause *should* evaluate to .false. . Instead,
    ! nthreads is simply 0.
    if (nthreads /= 0) then
        call omp_set_num_threads(nthreads)
    end if
#endif
    if (method == 1) then
        if (use_m == 1) then
            !$omp parallel
            !$omp do
            do t = 0,nstep-1
                do j = 0,nstep - t - 1
                    do i = 0,natoms-1
                        ! poor man's unrolled dot
                        c(t) = c(t) + ( v(j+t,i,0) * v(j,i,0)  &
                                    +   v(j+t,i,1) * v(j,i,1)  &
                                    +   v(j+t,i,2) * v(j,i,2) ) * m(i)
                    end do
                end do
            end do
            !$omp end do
            !$omp end parallel
        else if (use_m == 0) then
            !$omp parallel
            !$omp do
            do t = 0,nstep-1
                do j = 0,nstep - t - 1
                    do i = 0,natoms-1
                        ! poor man's unrolled dot
                        c(t) = c(t) + ( v(j+t,i,0) * v(j,i,0)  &
                                    +   v(j+t,i,1) * v(j,i,1)  &
                                    +   v(j+t,i,2) * v(j,i,2) )
                    end do
                end do
            end do
            !$omp end do
            !$omp end parallel
        else
            write(stderr,*) this, "ERROR: illegal value for 'use_m'"
            return
        end if
        c = c / c(0)
        return

    ! Vectorzied version of the loops.
    else if (method == 2) then

        ! Slightly faster b/c of vectorization, but makes a copy of `v`. Use
        ! only if you have enough memory.  Don't know how to implement numpy's
        ! newaxis+broadcast magic into Fortran, but numpy will also make temp
        ! copies, for sure.
        ! We need a copy of `v` b/c `v` is "intent(in) v" and Fortran does not
        ! allow manipulation of input args. Moreover, we don't want to modify
        ! `v` directly should it become "intent(in,out)" one day.
        !
        ! Multiplication with the mass vector:
        ! Element-wise multiply each vector of length `natoms` vv(:,j,k) with
        ! sqrt(m). In the dot product of the velocities
        ! vv(i,j,:) . vv(i,j+t,:), we get m(i) back.

        if (use_m == 1) then
            !$omp parallel
            !$omp do
            do j = 0,nstep-1
                do k = 0,2
                    vv(j,:,k) = dsqrt(m) * v(j,:,k)
                end do
            end do
            !$omp end do
            !$omp end parallel
            call vect_loops(vv, natoms, nstep, c)
        else if (use_m == 0) then
            call vect_loops(v, natoms, nstep, c)
        else
            write(stderr,*) this, "ERROR: illegal value for 'use_m'"
            return
        end if
        c = c / c(0)
        return
    else
        write(stderr,*) this, "ERROR: illegal value for 'method'"
        return
    end if
end subroutine vacf


subroutine vect_loops(v, natoms, nstep, c)
#ifdef __OPENMP
    !f2py threadsafe
#endif
    implicit none
    integer :: t, nstep, natoms
    double precision, intent(in) :: v(0:nstep-1, 0:natoms-1, 0:2)
    double precision, intent(out) :: c(0:nstep-1)
    !$omp parallel
    !$omp do
    do t = 0,nstep-1
        c(t) = sum(v(:(nstep-t-1),:,:) * v(t:,:,:))
    end do
    !$omp end do
    !$omp end parallel
end subroutine vect_loops


subroutine acorr(v, c, nstep, method, norm)
    ! (Normalized) 1d-vacf: c_vv(t) = C_vv(t) / C_vv(0)
    ! This is a reference implementation.
    implicit none
    integer :: nstep, t, j, method, norm
    double precision, intent(in) :: v(0:nstep-1)
    double precision, intent(out) :: c(0:nstep-1)
    !f2py intent(in, out) c
    if (method == 1) then
        do t = 0,nstep-1
            do j = 0,nstep - t - 1
                c(t) = c(t) + v(j) * v(j+t)
            end do
        end do
    else if (method == 2) then
        do t = 0,nstep-1
            c(t) = sum(v(:(nstep-t-1)) * v(t:))
        end do
    end if
    if (norm == 1) then
        c = c / c(0)
    end if
    return
end subroutine acorr

subroutine distsq(arrx, arry, dsq, nx, ny, ndim)
#ifdef __OPENMP
    !f2py threadsafe
#endif
    implicit none
    integer :: ii, jj, nx, ny, ndim
    double precision :: arrx(nx, ndim), arry(ny, ndim), dsq(nx,ny)
    !f2py intent(in, out) dsq
    ! note row-major loop order -> speed!
    !$omp parallel
    !$omp do
    do jj=1,ny
        do ii=1,nx
            dsq(ii,jj) = sum((arrx(ii,:) - arry(jj,:))**2.0d0)
        end do
    end do
    !$omp end parallel
end subroutine distsq

subroutine angles(distvecs, dists, mask_val, deg, anglesijk, natoms)
    ! Return a 3d array with angles for easy indexing anglesijk[ii,jj,kk]. Not
    ! all array entries are used. Entries where ii==jj or ii==kk or jj==kk are
    ! set to fill value `mask_val`.
    !
    ! Parameters
    ! ----------
    ! distvecs : 3d array w/ cartesian distance vectors
    ! dists : 2d array with distances: dists(i,j) = norm(distvecs(i,j,:))
    ! mask_val : float
    !   Fill value for anglesijk(ii,jj,kk) where ii==jj or ii==kk or
    !   jj==kk, i.e. no angle defined. Can be used to create bool mask arrays in
    !   numpy.
    ! deg : int, {0,1}
    !   whether to return angles in degrees (1) or cosine values (0)
    ! anglesijk : dummy result array
    ! natoms : int, dummy, number of atoms
    !
    ! Returns
    ! -------
    ! anglesijk : 3d array (natoms,)*3
    implicit none
    integer :: ii, jj, kk, idx, natoms, deg
    double precision :: distvecs(natoms, natoms, 3)
    double precision :: dists(natoms, natoms)
    double precision :: mask_val, cang
    double precision, intent(out) :: anglesijk(natoms,natoms,natoms)
    double precision, parameter :: pi=acos(-1.0d0)
    double precision, parameter :: eps=2.2d-16, ceps=1.0d0 - eps
    !f2py intent(in,out,overwrite) anglesijk
    idx = 1
    do kk=1,natoms
        do jj=1,natoms
            do ii=1,natoms
                if (ii /= jj .and. ii /= kk .and. jj /= kk) then
                    cang = dot_product(distvecs(ii,jj,:), distvecs(ii,kk,:)) &
                        / dists(ii,jj) / dists(ii,kk)
                    anglesijk(ii,jj,kk) = cang
                else
                    anglesijk(ii,jj,kk) = mask_val
                end if
            end do
        end do
    end do
    if (deg==1) then
        ! handle numerical corner cases where acos() can return NaN,
        ! note that eps is hardcoded currently
        where (anglesijk /= mask_val .and. anglesijk > ceps) anglesijk = 1.0d0
        where (anglesijk /= mask_val .and. anglesijk < -ceps) anglesijk = -1.0d0
        where (anglesijk /= mask_val) anglesijk = acos(anglesijk) * 180.0d0 / pi
    end if
end subroutine angles


subroutine distsq_frac(coords_frac, cell, pbc, distsq, distvecs, distvecs_frac, natoms)
    ! Special purpose routine to calculate distance vectors, squared distances
    ! and apply minimum image convention (pbc) for fractional atom coords.
    !
    ! Parameters
    ! ----------
    ! coords_frac : (natoms,3)
    !     Fractional arom coords.
    ! cell : (3,3)
    ! pbc : int
    !     {0,1}
    ! distsq : dummy input
    ! distvecs : dummy input
    ! distvecs_frac : dummy input
    ! natoms : dummy input
    !
    ! Returns
    ! -------
    ! distsq : (natoms,natoms)
    !     squared cartesien distances
    ! distvecs : (natoms,natoms,3)
    !     cartesian distance vectors
    ! distvecs_frac : (natoms,natoms,3)
    !     fractional distance vectors, PBC applied if pbc=1
    implicit none
    integer :: natoms, pbc, ii,jj,kk
    double precision :: coords_frac(natoms,3), cell(3,3)
    double precision :: distsq(natoms,natoms), distvecs_frac(natoms, natoms, 3), &
                        distvecs(natoms, natoms, 3)
    !f2py intent(in,out,overwrite) distsq
    !f2py intent(in,out,overwrite) distvecs
    !f2py intent(in,out,overwrite) distvecs_frac
    do jj=1,natoms
        do ii=1,natoms
            distvecs_frac(ii,jj,:) = coords_frac(ii,:) - coords_frac(jj,:)
        end do
    end do

    if (pbc == 1) then
        do kk=1,3
            do jj=1,natoms
                do ii=1,natoms
                    do while (distvecs_frac(ii,jj,kk) >= 0.5d0)
                        distvecs_frac(ii,jj,kk) = distvecs_frac(ii,jj,kk) - 1.0d0
                    end do
                    do while (distvecs_frac(ii,jj,kk) < -0.5d0)
                        distvecs_frac(ii,jj,kk) = distvecs_frac(ii,jj,kk) + 1.0d0
                    end do
                end do
            end do
        end do
    end if

    do kk=1,3
        do jj=1,natoms
            do ii=1,natoms
                distvecs(ii,jj,kk) = dot_product(distvecs_frac(ii,jj,:), cell(:,kk))
            end do
        end do
    end do

    do jj=1,natoms
        do ii=1,natoms
            distsq(ii,jj) = sum(distvecs(ii,jj,:)**2.0d0)
        end do
    end do
end subroutine distsq_frac


! This routine below works, but on one core it is NOT faster than looping thru a
! Trajectory in Python::
!
!   >>> tr = Trajectory(...)
!   >>> for st in tr:
!   ...     dist = crys.distances(st,...)
!
! where distances() uses distsq_frac(), which is the called 1e4 times if
! tr.nstep=1e4! See examples/dist_speed_traj.py. We know that looping thru
! Trajectory is very fast b/c we only use array views when calling
! tr.__getitem__(). Then, the overhead of calling a f2py wrapper must be very
! small, proably b/c we allocate arrays in F order in distances() etc. That's
! pretty impressive!
!
! Below, OpenMP scales almost linear (tested up to 4 cores).
! But: The array `dists` tends to get quite big (some GB) very quickly.
!
! Instead, what is easy on memory *and* scales linear is using
! multiprocessing.Pool.map(worker,...) to iterare thru a Trajectory in parallel,
! calling distances() in each worker! That is embarr. parallel and should scale
! to any cores b/c we only chop the traj into pieces.

subroutine distances_traj(coords_frac, cell, pbc, natoms, nstep, dists)
    ! Cartesian distances along a trajectory.
    !
    ! Parameters
    ! ----------
    ! coords_frac : (nstep,natoms,3)
    ! cell : (nstep,3,3)
    ! pbc : int
    !     {0,1}
    ! dists : (nstep, natoms, natoms)
    !   dummy input
    ! natoms,nstep : dummy input
    !
    ! Returns
    ! -------
    ! dists : (nstep,natoms,natoms)
    !     cartesien distances
    implicit none
    integer :: natoms, pbc, istep, nstep
    double precision, intent(in) :: coords_frac(nstep,natoms,3), cell(nstep,3,3)
    double precision, intent(out) :: dists(nstep,natoms,natoms)
    double precision :: distsq(natoms,natoms), distvecs_frac(natoms, natoms, 3), &
                        distvecs(natoms, natoms, 3)

#ifdef __OPENMP
    !f2py threadsafe
#endif

    !f2py intent(in,out,overwrite) dists

    ! Without these private(...) statements the routine produces wrong results.
    !$omp parallel private(distvecs_frac, distvecs, distsq)
    !$omp do
    do istep=1,nstep
        call distsq_frac(coords_frac(istep,:,:), &
                         cell(istep,:,:), &
                         pbc, distsq, distvecs, distvecs_frac, natoms)
        dists(istep,:,:) = sqrt(distsq)
    end do
    !$omp end do
    !$omp end parallel
end subroutine distances_traj


subroutine solve(aa, bb, nn, xx)
    ! Solve linear system a*x=b.
    !
    ! Parameters
    ! ----------
    ! aa : (nn,nn)
    ! bb : (nn,)
    ! nn : int
    ! xx : (nn,)
    !   result array
    !
    ! Notes
    ! -----
    ! Only shape(x) = shape(b) = nn, i.e. only one right hand side. This is only
    ! for testing if we use dgesv() right.
    !
    implicit none
    integer :: nn
    double precision, intent(in) :: aa(nn,nn), bb(nn)
    double precision, intent(out) :: xx(nn)
    integer :: ipiv(nn), info

    ! Make a copy of bb b/c that will be overwritten in dgesv(). Not sure if
    ! this is the Fortran way to do it. But the Pyhon wrapper works and doesn't
    ! overwrite `bb`.
    xx(:) = bb(:)
    call dgesv(nn, 1, aa, nn, ipiv, xx, nn, info)
end subroutine solve


subroutine frac2cart(coords_frac, cell, natoms, coords)
    implicit none
    integer :: ii, natoms
    double precision, intent(in) :: coords_frac(natoms, 3), cell(3,3)
    double precision, intent(out) :: coords(natoms, 3)

    do ii=1,natoms
        ! same as: matmul(transpose(cell), coords_frac(ii,:))
        coords(ii,:) = matmul(coords_frac(ii,:), cell)
    end do
end subroutine frac2cart


subroutine cart2frac(coords, cell, natoms, coords_frac)
    implicit none
    integer :: natoms, ipiv(3), info
    double precision, intent(in) :: coords(natoms, 3), cell(3,3)
    double precision, intent(out) :: coords_frac(natoms, 3)
    double precision :: wrk(3,natoms)

    ! solve for all `natoms` RHS at once
    wrk = transpose(coords)
    call dgesv(3, natoms, transpose(cell), 3, ipiv, wrk, 3, info)
    coords_frac = transpose(wrk)
end subroutine cart2frac


subroutine frac2cart_traj(coords_frac, cell, nstep, natoms, coords)
    implicit none
    integer :: ii, natoms, nstep
    double precision, intent(in) :: coords_frac(nstep, natoms, 3), cell(nstep, 3,3)
    double precision, intent(out) :: coords(nstep, natoms, 3)

    do ii=1,nstep
        call frac2cart(coords_frac(ii,:,:), cell(ii,:,:), natoms, &
                        coords(ii,:,:))
    end do
end subroutine frac2cart_traj


subroutine cart2frac_traj(coords, cell, nstep, natoms, coords_frac)
    implicit none
    integer :: ii, natoms, nstep
    double precision, intent(in) :: coords(nstep, natoms, 3), cell(nstep, 3,3)
    double precision, intent(out) :: coords_frac(nstep, natoms, 3)

    do ii=1,nstep
        call cart2frac(coords(ii,:,:), cell(ii,:,:), natoms, &
                        coords_frac(ii,:,:))
    end do
end subroutine cart2frac_traj
