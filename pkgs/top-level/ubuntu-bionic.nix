# Cross-compilation variant targeting Ubuntu Bionic (18.04).
#
# Produces binaries linked against Ubuntu's glibc 2.27, using LLVM 21.
# Usage: pkgsUbuntu.bionic.hello
#
# The full nixpkgs package set is available, but individual packages may
# need adjustments (e.g. disabling tests that assume a working NSS stack).
# Add per-package overrides in the crossOverlays below.
{
  lib,
  self,
  nixpkgsFun,
  stdenv,
  overlays,
}:

let
  sysroot = self.callPackage ../development/libraries/ubuntu-sysroot/bionic.nix { };

  # Per-package overrides for the cross (host) package set.
  # crossSuper is the unmodified cross package; use overrideAttrs to adjust.
  packageOverrides = crossSelf: crossSuper: {
    # wolfssl's test suite does hostname resolution via NSS, which doesn't
    # work with Ubuntu's vanilla glibc inside the Nix sandbox.
    wolfssl = crossSuper.wolfssl.overrideAttrs { doCheck = false; };
  };
in
nixpkgsFun {
  overlays = [
    (self': super': {
      pkgsUbuntu = super'.pkgsUbuntu or { } // {
        bionic = super';
      };
    })
  ] ++ overlays;

  crossSystem = stdenv.hostPlatform // {
    useLLVM = true;
    linker = "lld";
  };

  crossOverlays = [
    (crossSelf: crossSuper: {
      glibc = sysroot;
    })
    packageOverrides
  ];
}
