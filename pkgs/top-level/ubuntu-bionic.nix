# Cross-compilation variant targeting Ubuntu Bionic (18.04).
#
# Produces binaries linked against Ubuntu's glibc 2.27, using LLVM 21.
# Usage: pkgsUbuntu.bionic.hello
#
# The full nixpkgs package set is available, but individual packages may
# need adjustments (e.g. disabling tests that assume a working NSS stack).
# Add per-package overrides in the crossOverlay below.
{
  lib,
  nixpkgsFun,
  stdenv,
  overlays,
  sysroot,
}:

nixpkgsFun {
  overlays = [
    (self': super': {
      pkgsUbuntu = super'.pkgsUbuntu or { } // {
        bionic = super';
      };
    })
  ]
  ++ overlays;

  crossSystem = stdenv.hostPlatform // {
    useLLVM = true;
    linker = "lld";
  };

  crossOverlays = [
    (crossSelf: crossSuper: {
      glibc = sysroot;

      # Per-package overrides:

      # wolfssl's test suite does hostname resolution via NSS, which doesn't
      # work with Ubuntu's vanilla glibc inside the Nix sandbox.
      wolfssl = crossSuper.wolfssl.overrideAttrs { doCheck = false; };

      # Tests try to execute cross-compiled binaries which either can't run
      # on the build host or fail with "libgcc_s.so.1 must be installed for
      # pthread_cancel to work" under the LLVM toolchain.
      gdbm = crossSuper.gdbm.overrideAttrs { doCheck = false; };
      libarchive = crossSuper.libarchive.overrideAttrs { doCheck = false; };
      libffi = crossSuper.libffi.overrideAttrs { doCheck = false; };
      libgcrypt = crossSuper.libgcrypt.overrideAttrs { doCheck = false; };
      libgpg-error = crossSuper.libgpg-error.overrideAttrs { doCheck = false; };
      libpsl = crossSuper.libpsl.overrideAttrs { doCheck = false; };
      openssl = crossSuper.openssl.overrideAttrs { doCheck = false; };
      p11-kit = crossSuper.p11-kit.overrideAttrs { doCheck = false; };
      sqlite = crossSuper.sqlite.overrideAttrs { doCheck = false; };
      unbound = crossSuper.unbound.overrideAttrs { doCheck = false; };

      # elfutils uses -Werror; clang catches a -Wunused-but-set-variable
      # that gcc doesn't.
      elfutils = crossSuper.elfutils.overrideAttrs (old: {
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "")
            + " -Wno-error=unused-but-set-variable";
        };
      });

      # Ubuntu Bionic's glibc fortify headers redefine asprintf as a macro,
      # which conflicts with bash's own extern declaration in braces.c.
      bash = crossSuper.bash.overrideAttrs (old: {
        hardeningDisable = (old.hardeningDisable or [ ]) ++ [ "fortify" ];
      });
      bashNonInteractive = crossSuper.bashNonInteractive.overrideAttrs (old: {
        hardeningDisable = (old.hardeningDisable or [ ]) ++ [ "fortify" ];
      });

      # Ubuntu Bionic's kernel headers (4.15) are too old for the kTLS API
      # that gnutls 3.8.x requires (TLS_RX, AES-CCM structs, etc.).
      gnutls = crossSuper.gnutls.overrideAttrs (old: {
        configureFlags =
          builtins.filter (f: !builtins.elem f [ "--enable-ktls" "--enable-cxx" ]) (old.configureFlags or [ ])
          ++ [ "--disable-ktls" "--disable-cxx" ];
      });

      # Python's Makefile sets RUNSHARED=LD_LIBRARY_PATH=<builddir> so the
      # native python loads the cross-compiled libpython, which pulls in
      # the sysroot's libpthread (with GLIBC_PRIVATE symbols the build
      # host doesn't have).  Clear RUNSHARED after configure.
      python313 = crossSuper.python313.overrideAttrs (old: {
        postConfigure = (old.postConfigure or "") + ''
          sed -i 's/^RUNSHARED=.*/RUNSHARED=/' Makefile
        '';
      });

      # g-ir-scanner links a temporary binary using the cross compiler
      # against native libraries that reference newer GLIBC symbols than
      # the Bionic sysroot provides.  Disable GObject introspection.
      glib = crossSuper.glib.override { withIntrospection = false; };

      # gettext 0.26's libtextstyle needs iconv, but the configure check
      # tries to run a test binary which fails under cross-compilation.
      # Also, clang 21 treats an incompatible function pointer in
      # iconv-ostream.c as a hard error.
      # Graphviz: gts, pango, and gd pull in glib variants with
      # introspection enabled through splicing, which can't
      # cross-compile.  The core libraries (libcgraph, libgvc,
      # libgvpr, libpathplan, libxdot) don't need them.
      graphviz = (crossSuper.graphviz.override { withXorg = false; }).overrideAttrs (old: {
        buildInputs = builtins.filter
          (i: !builtins.elem (i.pname or "") [ "gts" "pango" "gd" ])
          (old.buildInputs or [ ]);
      });

      # RPM: rpm-sequoia's Rust build scripts load the cross-sysroot's
      # libpthread which lacks GLIBC_PRIVATE symbols.  audit needs newer
      # kernel headers.  systemd needs glibc 2.28+ threads.h.
      rpm = (crossSuper.rpm.override {
        rpm-sequoia = null;
        audit = null;
        systemd = null;
        gnupg = (crossSelf.gnupg.override {
          withPcsc = false;
          withTpm2Tss = false;
          openldap = null;
          guiSupport = false;
          libusb1 = null;
        }).overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
            "am_cv_func_iconv_works=yes"
          ];
        });
      }).overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DWITH_AUDIT=OFF"
          "-DWITH_SELINUX=OFF"
          "-DWITH_SEQUOIA=OFF"
          "-DWITH_INTERNAL_OPENPGP=ON"
        ];
        buildInputs = (old.buildInputs or [ ]) ++ [
          crossSelf.libgcrypt
        ];
      });

      # audit requires kernel headers newer than Ubuntu Bionic's 4.15
      # (linux/io_uring.h, AUDIT_ARCH_RISCV*).  Disable it everywhere.
      linux-pam = crossSuper.linux-pam.override { withAudit = false; };
      dbus = crossSuper.dbus.override { audit = null; enableSystemd = false; };

      # libpcap: bluez needs dbus+audit chain (broken on Bionic).
      libpcap = crossSuper.libpcap.override { withBluez = false; };
      # wireshark-cli: disable bluez in libpcap, skip speexdsp (needs
      # Fortran/fftw), skip spandsp3 (needs fftw too).
      wireshark-cli = (crossSuper.wireshark-cli.override {
        libpcap' = crossSelf.libpcap;
        spandsp3 = null;
      }).overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DBUILD_sharkd=OFF"
          "-DBUILD_stratoshark=OFF"
        ];
        buildInputs = builtins.filter
          (i: (i.pname or "") != "speexdsp")
          (old.buildInputs or [ ]);
        # CMake applies cross-compiler (clang) flags to the native lemon
        # build. Strip clang-specific flags from the generated build file.
        postConfigure = (old.postConfigure or "") + ''
          sed -i 's/-Xclang -analyzer-disable-all-checks//g' build.ninja
          sed -i 's/-fno-sanitize=all//g' build.ninja
        '';
        # Ubuntu Bionic's kernel headers (4.15) lack NL80211_BAND_6GHZ.
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "")
            + " -DNL80211_BAND_6GHZ=5";
        };
      });

      # libcap: Go can't cross-compile (sysroot contamination),
      # PAM needs audit.
      libcap = crossSuper.libcap.override { withGo = false; usePam = false; };

      gettext = crossSuper.gettext.overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [
          "am_cv_func_iconv=yes"
          "am_cv_func_iconv_works=yes"
        ];
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "")
            + " -Wno-incompatible-function-pointer-types";
        };
      });
    })
  ];
}
