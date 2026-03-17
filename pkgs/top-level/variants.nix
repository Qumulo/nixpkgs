/*
  This file contains all of the different variants of nixpkgs instances.

  Unlike the other package sets like pkgsCross, pkgsi686Linux, etc., this
  contains non-critical package sets. The intent is to be a shorthand
  for things like using different toolchains in every package in nixpkgs.
*/
{
  lib,
  stdenv,
  nixpkgsFun,
  overlays,
  makeMuslParsedPlatform,
}:
let
  makeLLVMParsedPlatform =
    parsed:
    (
      parsed
      // {
        abi = lib.systems.parse.abis.llvm;
      }
    );
in
self: super: {
  pkgsLLVM = nixpkgsFun {
    overlays = [
      (self': super': {
        pkgsLLVM = super';
      })
    ]
    ++ overlays;
    # Bootstrap a cross stdenv using the LLVM toolchain.
    # This is currently not possible when compiling natively,
    # so we don't need to check hostPlatform != buildPlatform.
    crossSystem = stdenv.hostPlatform // {
      useLLVM = true;
      linker = "lld";
    };
  };

  pkgsArocc = nixpkgsFun {
    overlays = [
      (self': super': {
        pkgsArocc = super';
      })
    ]
    ++ overlays;
    # Bootstrap a cross stdenv using the Aro C compiler.
    # This is currently not possible when compiling natively,
    # so we don't need to check hostPlatform != buildPlatform.
    crossSystem = stdenv.hostPlatform // {
      useArocc = true;
      linker = "lld";
    };
  };

  pkgsZig = nixpkgsFun {
    overlays = [
      (self': super': {
        pkgsZig = super';
      })
    ]
    ++ overlays;
    # Bootstrap a cross stdenv using the Zig toolchain.
    # This is currently not possible when compiling natively,
    # so we don't need to check hostPlatform != buildPlatform.
    crossSystem = stdenv.hostPlatform // {
      useZig = true;
      linker = "lld";
    };
  };

  # All packages built with the Musl libc. This will override the
  # default GNU libc on Linux systems. Non-Linux systems are not
  # supported. 32-bit is also not supported.
  pkgsMusl =
    if stdenv.hostPlatform.isLinux && stdenv.buildPlatform.is64bit then
      nixpkgsFun {
        overlays = [
          (self': super': {
            pkgsMusl = super';
          })
        ]
        ++ overlays;
        ${if stdenv.hostPlatform == stdenv.buildPlatform then "localSystem" else "crossSystem"} = {
          config = lib.systems.parse.tripleFromSystem (makeMuslParsedPlatform stdenv.hostPlatform.parsed);
        };
      }
    else
      throw "Musl libc only supports 64-bit Linux systems.";

  # x86_64-darwin packages for aarch64-darwin users to use with Rosetta for incompatible packages
  pkgsx86_64Darwin =
    if stdenv.hostPlatform.isDarwin then
      nixpkgsFun {
        overlays = [
          (self': super': {
            pkgsx86_64Darwin = super';
          })
        ]
        ++ overlays;
        localSystem = {
          config = lib.systems.parse.tripleFromSystem (
            stdenv.hostPlatform.parsed
            // {
              cpu = lib.systems.parse.cpuTypes.x86_64;
            }
          );
        };
      }
    else
      throw "x86_64 Darwin package set can only be used on Darwin systems.";

  # Full package set with rocm on cuda off
  # Mostly useful for asserting pkgs.pkgsRocm.torchWithRocm == pkgs.torchWithRocm and similar
  pkgsRocm = nixpkgsFun {
    config = super.config // {
      cudaSupport = false;
      rocmSupport = true;
    };
  };

  # Full package set with cuda on rocm off
  # Mostly useful for asserting pkgs.pkgsCuda.torchWithCuda == pkgs.torchWithCuda and similar
  pkgsCuda = nixpkgsFun {
    config = super.config // {
      cudaSupport = true;
      rocmSupport = false;
    };
  };

  # `pkgsForCudaArch` maps each CUDA capability in _cuda.db.cudaCapabilityToInfo to a Nixpkgs variant configured for
  # that target system. For example, `pkgsForCudaArch.sm_90a.python3Packages.torch` refers to PyTorch built for the
  # Hopper architecture, leveraging architecture-specific features.
  # NOTE: Not every package set is supported on every architecture!
  # See `Using pkgsForCudaArch` in doc/languages-frameworks/cuda.section.md for more information.
  pkgsForCudaArch = lib.listToAttrs (
    lib.map (cudaCapability: {
      name = self._cuda.lib.mkRealArchitecture cudaCapability;
      value = nixpkgsFun {
        config = super.config // {
          cudaSupport = true;
          rocmSupport = false;
          # Not supported by architecture-specific feature sets, so disable for all.
          # Users can choose to build for family-specific feature sets if they wish.
          cudaForwardCompat = false;
          cudaCapabilities = [ cudaCapability ];
        };
      };
    }) (lib.attrNames self._cuda.db.cudaCapabilityToInfo)
  );

  # All packages built against glibc 2.27 for binary compatibility with
  # Ubuntu 18.04 (Bionic), RHEL 7+, and manylinux2014-era systems.
  # The stdenv's cc-wrapper and bintools-wrapper are rebuilt to link
  # against glibc 2.27; the compiler itself remains from the host stdenv.
  pkgsGlibc227 =
    if stdenv.hostPlatform.isLinux then
      let
        # Build glibc 2.27 using the OUTER (non-variant) package set.
        # This avoids circular dependencies: the variant's stdenv depends
        # on glibc 2.27, so glibc 2.27 must not depend on the variant's stdenv.
        glibc227 = self.callPackage ../development/libraries/glibc-2_27 {
          stdenv = self.gccStdenv;
        };
      in
      nixpkgsFun {
        overlays = [
          (
            self': super':
            let
              cc = super'.stdenv.cc;
              # Only override at the final stage.  Bootstrap stages are
              # named "bootstrap-stage{N}-stdenv-linux"; the final stdenv
              # is just "stdenv-linux".
              ready =
                cc != null
                && !(lib.hasPrefix "bootstrap" (super'.stdenv.name or "bootstrap"));

              newBintools = cc.bintools.override { libc = glibc227; };
              # GCC 15 defaults to C23 and emits __isoc23_* symbol
              # refs (e.g. __isoc23_strtoul) that glibc 2.27 lacks.
              # Append -std=gnu17 to the cc-wrapper's cc-cflags file
              # so it applies to every compilation in this variant.
              newCc = (cc.override {
                libc = glibc227;
                bintools = newBintools;
              }).overrideAttrs (old: {
                postFixup = (old.postFixup or "") + "\n" + ''
                  # GCC 15 has glibc 2.42 headers hardcoded via -isystem;
                  # override with glibc 2.27 headers at higher priority so
                  # the __isoc23_* redirects in 2.42's stdlib.h are not seen.
                  echo " -isystem ${glibc227.dev}/include" >> $out/nix-support/cc-cflags
                '';
              });
            in
            {
              pkgsGlibc227 = super';
            }
            // lib.optionalAttrs ready {
              stdenv = super'.stdenv.override {
                cc = newCc;
                allowedRequisites = null;
              };
            }
          )
        ]
        ++ overlays;
      }
    else
      throw "pkgsGlibc227 is only supported on Linux.";

  pkgsExtraHardening = nixpkgsFun {
    overlays = [
      (
        self': super':
        {
          pkgsExtraHardening = super';
          stdenv = super'.withDefaultHardeningFlags (
            super'.stdenv.cc.defaultHardeningFlags
            ++ [
              "strictflexarrays1"
              "shadowstack"
              "nostrictaliasing"
              "pacret"
              "glibcxxassertions"
              "libcxxhardeningfast"
              "trivialautovarinit"
            ]
          ) super'.stdenv;
          glibc = super'.glibc.override rec {
            enableCET = if self'.stdenv.hostPlatform.isx86_64 then "permissive" else false;
            enableCETRuntimeDefault = enableCET != false;
          };
        }
        // lib.optionalAttrs (with super'.stdenv.hostPlatform; isx86_64 && isLinux) {
          # causes shadowstack disablement
          pcre = super'.pcre.override { enableJit = false; };
          pcre-cpp = super'.pcre-cpp.override { enableJit = false; };
        }
      )
    ]
    ++ overlays;
  };
}
