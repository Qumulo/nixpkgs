{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
}:

stdenvNoCC.mkDerivation {
  pname = "ubuntu-bionic-sysroot";
  version = "2.27-3ubuntu1.6";

  outputs = [
    "out"
    "dev"
    "static"
  ];

  srcs = [
    (fetchurl {
      url = "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.27-3ubuntu1.6_amd64.deb";
      hash = "sha256-W4E9RRJJHNj7MLLrkZI0nudf/jyfIa4TbMeyQp9ww7I=";
    })
    (fetchurl {
      url = "http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6-dev_2.27-3ubuntu1.6_amd64.deb";
      hash = "sha256-lq59LPOPBUfKPMyzNEyIAv31vNccS22a7QlVisjMh9s=";
    })
    (fetchurl {
      url = "http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux-libc-dev_4.15.0-213.224_amd64.deb";
      hash = "sha256-BtnxZkTTobKrfdAXMOgz1Ra29XXZdYVfSW7qZGP+8vY=";
    })
  ];

  nativeBuildInputs = [ dpkg ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    # dpkg unpack hook extracts each .deb into root/
    local s=root

    # --- $out: shared libraries + CRT objects ---
    mkdir -p $out/lib

    # Shared libraries from libc6 (./lib/x86_64-linux-gnu/)
    cp -a $s/lib/x86_64-linux-gnu/* $out/lib/

    # CRT objects + linker scripts + static nonshared libs from libc6-dev
    # (./usr/lib/x86_64-linux-gnu/)
    cp -a $s/usr/lib/x86_64-linux-gnu/*.o $out/lib/
    cp -a $s/usr/lib/x86_64-linux-gnu/*_nonshared.a $out/lib/

    # Development .so files from libc6-dev: a mix of linker scripts and symlinks.
    # Both contain absolute Ubuntu paths that need rewriting.
    for f in $s/usr/lib/x86_64-linux-gnu/*.so; do
      name=$(basename "$f")
      # Skip if we already have this file (e.g. from the libc6 runtime package)
      [ -e "$out/lib/$name" ] && continue
      if [ -L "$f" ]; then
        # Symlink (may be broken in sandbox): rewrite to relative target
        target=$(readlink "$f")
        target=$(basename "$target")
        ln -s "$target" "$out/lib/$name"
      elif [ -f "$f" ]; then
        # Linker script: rewrite absolute paths
        sed -E "s|(/usr)?/lib/x86_64-linux-gnu/|$out/lib/|g" \
          "$f" > "$out/lib/$name"
      fi
    done

    # --- $dev: headers ---
    mkdir -p $dev/include

    # Main glibc headers from libc6-dev (./usr/include/)
    cp -a $s/usr/include/* $dev/include/

    # Arch-specific headers go on top (./usr/include/x86_64-linux-gnu/)
    # These contain bits/, gnu/, sys/ subdirs that override/supplement the main ones
    cp -a $s/usr/include/x86_64-linux-gnu/* $dev/include/
    rm -rf $dev/include/x86_64-linux-gnu

    # Kernel headers from linux-libc-dev are already in usr/include/
    # (asm/, asm-generic/, linux/) - they were copied above

    # --- $static: static libraries ---
    mkdir -p $static/lib
    cp -a $s/usr/lib/x86_64-linux-gnu/*.a $static/lib/
    # Remove the nonshared libs we already put in $out
    rm -f $static/lib/*_nonshared.a

    runHook postInstall
  '';

  dontFixup = true;

  passthru = {
    # cc-wrapper reads these to construct -B and -isystem flags
    libdir = "/lib";
    incdir = "/include";
  };

  meta = {
    description = "Ubuntu Bionic (18.04) glibc 2.27 sysroot for cross-compilation";
    homepage = "https://packages.ubuntu.com/bionic/libc6";
    license = lib.licenses.lgpl21Plus;
    platforms = [ "x86_64-linux" ];
  };
}
