# glibc 2.27 — for the pkgsGlibc227 variant.
#
# Provides binary compatibility with Ubuntu 18.04 (Bionic), RHEL 7+,
# and manylinux2014-era systems.
#
# This is a standalone package (not derived via overrideAttrs from the
# current glibc) because glibc 2.27 differs materially from 2.42:
#   - libpthread/librt/libdl are real libraries (not merged into libc.so)
#   - no python3 build dependency
#   - no --enable-fortify-source or --enable-cet configure flags
#   - nss_files_fopen.c and libidn2 integration don't exist yet

{
  lib,
  stdenv,
  buildPackages,
  fetchurl,
  linuxHeaders,
  bison,
  libgcc,
  gnumake,
}:

let
  # glibc <=2.36 is incompatible with GNU Make >=4.4: pattern-rule
  # evaluation changes cause infinite loops.  Pin Make 4.3 (the Trofi
  # MAKEFLAGS patch is also applied as belt-and-suspenders).
  gnumake_4_3 = gnumake.overrideAttrs (old: {
    version = "4.3";
    src = fetchurl {
      url = "mirror://gnu/make/make-4.3.tar.gz";
      hash = "sha256-4F/d5HxffKRctpfpc4lP9PXXnhO3UO1X17Ztje/Hjhk=";
    };
    patches = [ ];
  });

in

stdenv.mkDerivation {
  pname = "glibc";
  version = "2.27";

  src = fetchurl {
    url = "mirror://gnu/glibc/glibc-2.27.tar.xz";
    hash = "sha256-UXLeVDGOwLfyc15akdkIr+HJyikf7Ba1N02fqt/B/HI=";
  };

  # No Nix-specific patches — the 2.42 patches don't apply to 2.27.
  # For NixOS use you would need to port dont-use-system-ld-so-cache.patch
  # and nix-locale-archive.patch to the 2.27 codebase.
  patches = [
    # Backport of upstream 2d7ed98a (Trofi, BZ#29564): GNU Make 4.4+
    # exposes long options in MAKEFLAGS which breaks glibc's Makerules.
    ./fix-makeflags-for-make-4.4.patch
    # Make the dynamic linker treat missing version nodes (e.g.
    # GLIBC_2.34 required by GCC 15's libgcc_s.so) as non-fatal.
    # The actual symbols are provided by libglibc_compat.so.
    ./skip-version-not-found.patch
  ];

  outputs = [
    "out"
    "bin"
    "dev"
    "static"
    "getent"
  ];

  strictDeps = true;
  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [ bison gnumake_4_3 ];
  buildInputs = [ linuxHeaders ];

  enableParallelBuilding = true;

  postPatch = ''
    # nscd needs libgcc, and we don't want it dynamically linked
    # because we don't want it to depend on bootstrap-tools libs.
    echo "LDFLAGS-nscd += -static-libgcc" >> nscd/Makefile
  '';

  configureFlags =
    [
      "-C"
      "--enable-add-ons"
      "--sysconfdir=/etc"
      "--enable-stack-protector=strong"
      "--enable-bind-now"
      "--enable-obsolete-rpc"
      "--enable-obsolete-nsl"
      "--enable-stackguard-randomization"
      "--with-headers=${linuxHeaders}/include"
      "--disable-profile"
      "--disable-werror"
      "--enable-kernel=3.13"
      # GCC 10+ defaults to -fno-common; glibc 2.27 has tentative
      # definitions (nss/databases.def) that require the old behaviour.
      "libc_extra_cflags=-fcommon"
    ]
    ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
      (lib.flip lib.withFeature "fp" (
        stdenv.hostPlatform.gcc.float or (stdenv.hostPlatform.parsed.abi.float or "hard") == "soft"
      ))
      "--with-__thread"
    ]
    ++ lib.optionals (stdenv.hostPlatform == stdenv.buildPlatform && stdenv.hostPlatform.isAarch32) [
      "--host=arm-linux-gnueabi"
      "--build=arm-linux-gnueabi"
      "libc_cv_as_needed=no"
    ];

  makeFlags =
    [
      "OBJCOPY=${stdenv.cc.targetPrefix}objcopy"
      # GCC 15 defaults to PIE; glibc 2.27's CRT objects are not
      # PIE-compatible.  glibc's configure does not propagate LDFLAGS
      # into config.make, so pass it as a make variable.
      "LDFLAGS=-no-pie"
    ]
    ++ lib.optionals (stdenv.cc.libc != null) [
      "BUILD_LDFLAGS=-Wl,-rpath,${stdenv.cc.libc}/lib"
      "OBJDUMP=${stdenv.cc.bintools.bintools}/bin/objdump"
    ]
    ++ lib.optionals (libgcc != null) [
      "user-defined-trusted-dirs=${libgcc}/lib"
    ];

  env = {
    linuxHeaders = "${linuxHeaders}";
    inherit (stdenv.hostPlatform) is64bit;
    BASH_SHELL = "/bin/sh";
  };

  # Remove absolute paths from configure; build out-of-tree.
  preConfigure =
    ''
      export PWD_P=$(type -tP pwd)
      for i in configure io/ftwtest-sh; do
          # Can't use substituteInPlace here because replace hasn't been
          # built yet in the bootstrap.
          sed -i "$i" -e "s^/bin/pwd^$PWD_P^g"
      done

      mkdir build
      cd build

      configureScript="`pwd`/../configure"
    ''
    + lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
      sed -i s/-lgcc_eh//g ../Makeconfig

      cat > config.cache << "EOF"
      libc_cv_forced_unwind=yes
      libc_cv_c_cleanup=yes
      libc_cv_gnu89_inline=yes
      EOF

      sed -i \
        -e '/^AR=/d' \
        -e '/^AS=/d' \
        -e '/^LD=/d' \
        -e '/^OBJCOPY=/d' \
        -e '/^OBJDUMP=/d' \
        $configureScript
    '';

  NIX_NO_SELF_RPATH = true;

  postConfigure = ''
    # Hack: get rid of the `-static' flag set by the bootstrap stdenv.
    # This has to be done *after* `configure' because it builds some
    # test binaries.
    export NIX_CFLAGS_LINK=
    export NIX_LDFLAGS_BEFORE=

    export NIX_DONT_SET_RPATH=1
    unset CFLAGS

    # Apparently --bindir is not respected.
    makeFlagsArray+=("bindir=$bin/bin" "sbindir=$bin/sbin" "rootsbindir=$bin/sbin")
  '';

  # The stackprotector and fortify hardening flags are autodetected by
  # glibc and enabled by default if supported. Setting it for every gcc
  # invocation does not work.
  hardeningDisable = [
    "fortify"
    "stackprotector"
  ];

  installFlags = [ "sysconfdir=$(out)/etc" ];

  postInstall = ''
    moveToOutput bin/getent $getent

    test -f $out/etc/ld.so.cache && rm $out/etc/ld.so.cache

    if test -n "$linuxHeaders"; then
        # Include the Linux kernel headers in Glibc, except the `scsi'
        # subdirectory, which Glibc provides itself.
        (cd $dev/include && \
         ln -sv $(ls -d ${linuxHeaders}/include/* | grep -v scsi\$) .)
    fi

    # Fix for NIXOS-54 (ldd not working on x86_64).  Make a symlink
    # "lib64" to "lib".
    if test -n "$is64bit"; then
        ln -s lib $out/lib64
    fi

    # Get rid of more unnecessary stuff.
    rm -rf $out/var $bin/bin/sln

    # Put libraries for static linking in a separate output.  Note
    # that libc_nonshared.a and libpthread_nonshared.a are required
    # for dynamically-linked applications.
    mkdir -p $static/lib
    mv $out/lib/*.a $static/lib
    mv $static/lib/lib*_nonshared.a $out/lib
    # Some of *.a files are linker scripts where moving broke the paths.
    sed "/^GROUP/s|$out/lib/lib|$static/lib/lib|g" \
      -i "$static"/lib/*.a

    # Forward-compat shims for symbols that GCC 15's runtime libraries
    # (libgcc_s.so, libstdc++.so) need but glibc 2.27 lacks.
    # Built as a shared library with its own version script so the
    # versioned symbols are self-contained (no GLIBC_2.34 requirement
    # on libc.so).  Using dlsym() to call the glibc 2.27 implementations
    # avoids creating a versioned dependency on libpthread.
    cat > /tmp/glibc_compat.c <<'COMPAT'
    /* Avoid including any glibc headers that might conflict; use
       bare declarations and dlsym from the dynamic linker. */
    extern void *dlsym(void *handle, const char *symbol);
    #define RTLD_NEXT ((void *) -1L)

    /* __libc_single_threaded: added in glibc 2.32. */
    char __libc_single_threaded = 1;

    /* Resolve the real function from libpthread at first call. */
    #define LAZY(ret, name, params, args) \
        ret name params { \
            static ret (*real) params; \
            if (!real) real = dlsym(RTLD_NEXT, #name); \
            return real args; \
        }

    LAZY(void*, pthread_getspecific, (unsigned key), (key))
    LAZY(int, pthread_setspecific, (unsigned key, const void *val), (key, val))
    LAZY(int, pthread_key_create, (unsigned *key, void (*destr)(void*)), (key, destr))
    LAZY(int, pthread_once, (int *ctrl, void (*init)(void)), (ctrl, init))

    /* _dl_find_object: added in glibc 2.35 for stack unwinding.
       Return "not found" so libgcc falls back to dl_iterate_phdr. */
    int _dl_find_object(void *pc, void *result) {
        (void)pc; (void)result;
        return -1;
    }
COMPAT
    cat > /tmp/glibc_compat.map <<'VERSCRIPT'
    GLIBC_2.32 { global: __libc_single_threaded; };
    GLIBC_2.34 { global: pthread_getspecific; pthread_setspecific;
                         pthread_key_create; pthread_once; };
    GLIBC_2.35 { global: _dl_find_object; };
VERSCRIPT
    $CC -shared -nostdlib -o $out/lib/libglibc_compat.so.0 /tmp/glibc_compat.c \
        -Wl,-soname,libglibc_compat.so.0 \
        -Wl,--version-script,/tmp/glibc_compat.map \
        -ldl -lgcc
    ln -s libglibc_compat.so.0 $out/lib/libglibc_compat.so

    # Work around a Nix bug: hard links across outputs cause a build failure.
    cp $bin/bin/getconf $bin/bin/getconf_
    mv $bin/bin/getconf_ $bin/bin/getconf
  '';

  separateDebugInfo = true;

  doCheck = false;

  passthru =
    {
      version = "2.27";
      minorRelease = "2.27";
    }
    // lib.optionalAttrs (libgcc != null) {
      inherit libgcc;
    };

  meta = {
    homepage = "https://www.gnu.org/software/libc/";
    description = "GNU C Library (version 2.27, for binary compatibility with Ubuntu 18.04+)";
    license = lib.licenses.lgpl2Plus;
    platforms = lib.platforms.linux;
  };
}
