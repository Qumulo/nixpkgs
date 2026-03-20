# Heimdal with Qumulo patches for custom NTLM, GSSAPI IOV, hooks, and
# debug facilities, rebased on top of the upstream 7.8.0 source.
#
# The CVE backport patches (20-31) from the original Qumulo patch set are
# dropped because the 7.8.0 source already includes those fixes.
{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  python3,
  perl,
  bison,
  flex,
  texinfo,
  perlPackages,

  sqlite,
  openssl,
  libedit,
  libcap_ng,
  ncurses,
  libxcrypt,
}:

stdenv.mkDerivation {
  pname = "heimdal-qumulo";
  version = "7.8.0-unstable-2024-09-10";

  src = fetchFromGitHub {
    owner = "heimdal";
    repo = "heimdal";
    rev = "fd2d434dd375c402d803e6f948cfc6e257d3facc";
    hash = "sha256-WA3lo3eD05l7zKuKEVxudMmiG7OvjK/calaUzPQ2pWs=";
  };

  outputs = [
    "out"
    "dev"
    "man"
  ];

  patches = [
    # Qumulo patches (01, 03, 13, 17, 32) that apply cleanly to 7.8.0
    ./0001-Apply-clean-Qumulo-patches-01-03-13-17-32.patch
    # Ported Qumulo patches (05, 11, 16, 18, 19, 35)
    ./0002-Port-patch-05-Force-SPNEGO-to-fallback-to-NTLM.patch
    ./0003-Port-patch-11-Enable-NTLMv2-authentication.patch
    ./0004-Port-patch-16-Add-krb5_set_debug_dest_facility.patch
    ./0005-Port-patch-18-Implement-gss_get_mic_iov.patch
    ./0006-Port-patch-19-Implement-gss_verify_mic_iov.patch
    ./0007-Port-patch-35-Fix-NTLM-Type-1-message-encoding.patch
  ];

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
    python3
    perl
    bison
    flex
    perlPackages.JSON
    texinfo
  ];

  buildInputs = [
    libedit
    ncurses
    openssl
    sqlite
    libxcrypt
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [
    libcap_ng
  ];

  configureFlags = [
    "--disable-otp"
    "--disable-heimdal-documentation"
    "--without-x"
    "--without-berkeley-db"
    "--without-openldap"
    "--with-sqlite3=${sqlite.dev}"
    "--disable-afs-string-to-key"
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [
    "--with-capng"
  ];

  doCheck = false;

  postBuild = ''
    (cd include/hcrypto; make -j $NIX_BUILD_CORES)
    (cd lib/hcrypto; make -j $NIX_BUILD_CORES)
  '';

  postInstall = ''
    (cd include/hcrypto; make -j $NIX_BUILD_CORES install)
    (cd lib/hcrypto; make -j $NIX_BUILD_CORES install)

    mkdir -p $dev/bin
    mv $out/bin/krb5-config $dev/bin/

    mv $out/libexec/heimdal/* $dev/bin
    rmdir $out/libexec/heimdal

    mv lib/com_err/.libs/compile_et $dev/bin
  '';

  passthru = {
    implementation = "heimdal";
  };

  meta = {
    homepage = "https://www.heimdal.software";
    description = "Heimdal Kerberos with Qumulo patches (custom NTLM, GSSAPI IOV, hooks)";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
  };
}
