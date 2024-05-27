let
  withGold = platform: platform.isElf && !platform.isRiscV && !platform.isLoongArch64;
in

{ stdenv
, autoreconfHook
, autoconf269, automake, libtool
, bison
, buildPackages
, fetchFromGitHub
, fetchurl
, flex
, gettext
, lib
, noSysDirs
, perl
, substitute
, zlib

, enableGold ? withGold stdenv.targetPlatform
, enableGoldDefault ? false
, enableShared ? !stdenv.hostPlatform.isStatic
  # WARN: Enabling all targets increases output size to a multiple.
, withAllTargets ? false
}:

# WARN: configure silently disables ld.gold if it's unsupported, so we need to
# make sure that intent matches result ourselves.
assert enableGold -> withGold stdenv.targetPlatform;
assert enableGoldDefault -> enableGold;


let
  inherit (stdenv) buildPlatform hostPlatform targetPlatform;

  version = "2.41";

  srcs = {
    normal = fetchurl {
      url = "mirror://gnu/binutils/binutils-${version}.tar.bz2";
      hash = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    vc4-none = fetchFromGitHub {
      owner = "itszor";
      repo = "binutils-vc4";
      rev = "708acc851880dbeda1dd18aca4fd0a95b2573b36";
      sha256 = "1kdrz6fki55lm15rwwamn74fnqpy0zlafsida2zymk76n3656c63";
    };
  };

  #INFO: The targetPrefix prepended to binary names to allow multiple binuntils
  # on the PATH to both be usable.
  targetPrefix = lib.optionalString (targetPlatform != hostPlatform) "${targetPlatform.config}-";
in

stdenv.mkDerivation (finalAttrs: {
  pname = targetPrefix + "binutils";
  inherit version;

  # HACK: Ensure that we preserve source from bootstrap binutils to not rebuild LLVM
  src = stdenv.__bootPackages.binutils-unwrapped.src
    or srcs.${targetPlatform.system}
    or srcs.normal;

  # WARN: this package is used for bootstrapping fetchurl, and thus cannot use
  # fetchpatch! All mutable patches (generated by GitHub or cgit) that are
  # needed here should be included directly in Nixpkgs as files.
  patches = [
    # Upstream patch to fix llvm testsuite failure when loading powerpc
    # objects:
    #   https://sourceware.org/PR30794
    ./gold-powerpc-for-llvm.patch

    # Make binutils output deterministic by default.
    ./deterministic.patch


    # Breaks nm BSD flag detection, heeds an upstream fix:
    #   https://sourceware.org/PR29547
    ./0001-Revert-libtool.m4-fix-the-NM-nm-over-here-B-option-w.patch
    ./0001-Revert-libtool.m4-fix-nm-BSD-flag-detection.patch

    # Required for newer macos versions
    ./0001-libtool.m4-update-macos-version-detection-block.patch

    # For some reason bfd ld doesn't search DT_RPATH when cross-compiling. It's
    # not clear why this behavior was decided upon but it has the unfortunate
    # consequence that the linker will fail to find transitive dependencies of
    # shared objects when cross-compiling. Consequently, we are forced to
    # override this behavior, forcing ld to search DT_RPATH even when
    # cross-compiling.
    ./always-search-rpath.patch

    # Avoid `lib -> out -> lib` reference. Normally `bfd-plugins` does
    # not need to know binutils' BINDIR at all. It's an absolute path
    # where libraries are stored.
    ./plugins-no-BINDIR.patch
  ]
  ++ lib.optional targetPlatform.isiOS ./support-ios.patch
  # Adds AVR-specific options to "size" for compatibility with Atmel's downstream distribution
  # Patch from arch-community
  # https://github.com/archlinux/svntogit-community/blob/c8d53dd1734df7ab15931f7fad0c9acb8386904c/trunk/avr-size.patch
  ++ lib.optional targetPlatform.isAvr ./avr-size.patch
  ++ lib.optional stdenv.targetPlatform.isWindows ./windres-locate-gcc.patch
  ;

  outputs = [ "out" "info" "man" "dev" ]
  # Ideally we would like to always install 'lib' into a separate
  # target. Unfortunately cross-compiled binutils installs libraries
  # across both `$lib/lib/` and `$out/$target/lib` with a reference
  # from $out to $lib. Probably a binutils bug: all libraries should go
  # to $lib as binutils does not build target libraries. Let's make our
  # life slightly simpler by installing everything into $out for
  # cross-binutils.
  ++ lib.optionals (targetPlatform == hostPlatform) [ "lib" ];

  strictDeps = true;
  depsBuildBuild = [ buildPackages.stdenv.cc ];
  # texinfo was removed here in https://github.com/NixOS/nixpkgs/pull/210132
  # to reduce rebuilds during stdenv bootstrap.  Please don't add it back without
  # checking the impact there first.
  nativeBuildInputs = [
    bison
    perl
  ]
  ++ lib.optionals targetPlatform.isiOS [ autoreconfHook ]
  ++ lib.optionals buildPlatform.isDarwin [ autoconf269 automake gettext libtool ]
  ++ lib.optionals targetPlatform.isVc4 [ flex ]
  ;

  buildInputs = [ zlib gettext ];

  inherit noSysDirs;

  preConfigure = (lib.optionalString buildPlatform.isDarwin ''
    for i in */configure.ac; do
      pushd "$(dirname "$i")"
      echo "Running autoreconf in $PWD"
      # autoreconf doesn't work, don't know why
      # autoreconf ''${autoreconfFlags:---install --force --verbose}
      autoconf
      popd
    done
  '') + ''
    # Clear the default library search path.
    if test "$noSysDirs" = "1"; then
        echo 'NATIVE_LIB_DIRS=' >> ld/configure.tgt
    fi

    # Use symlinks instead of hard links to save space ("strip" in the
    # fixup phase strips each hard link separately).
    for i in binutils/Makefile.in gas/Makefile.in ld/Makefile.in gold/Makefile.in; do
        sed -i "$i" -e 's|ln |ln -s |'
    done

    # autoreconfHook is not included for all targets.
    # Call it here explicitly as well.
    ${finalAttrs.postAutoreconf}
  '';

  postAutoreconf = ''
    # As we regenerated configure build system tries hard to use
    # texinfo to regenerate manuals. Let's avoid the dependency
    # on texinfo in bootstrap path and keep manuals unmodified.
    touch gas/doc/.dirstamp
    touch gas/doc/asconfig.texi
    touch gas/doc/as.1
    touch gas/doc/as.info
  '';

  # As binutils takes part in the stdenv building, we don't want references
  # to the bootstrap-tools libgcc (as uses to happen on arm/mips)
  env.NIX_CFLAGS_COMPILE =
    if hostPlatform.isDarwin
    then "-Wno-string-plus-int -Wno-deprecated-declarations"
    else "-static-libgcc";

  hardeningDisable = [ "format" "pie" ];

  configurePlatforms = [ "build" "host" "target" ];

  configureFlags = [
    "--enable-64-bit-bfd"
    "--with-system-zlib"

    "--enable-deterministic-archives"
    "--disable-werror"
    "--enable-fix-loongson2f-nop"

    # Turn on --enable-new-dtags by default to make the linker set
    # RUNPATH instead of RPATH on binaries.  This is important because
    # RUNPATH can be overridden using LD_LIBRARY_PATH at runtime.
    "--enable-new-dtags"

    # force target prefix. Some versions of binutils will make it empty if
    # `--host` and `--target` are too close, even if Nixpkgs thinks the
    # platforms are different (e.g. because not all the info makes the
    # `config`). Other versions of binutils will always prefix if `--target` is
    # passed, even if `--host` and `--target` are the same. The easiest thing
    # for us to do is not leave it to chance, and force the program prefix to be
    # what we want it to be.
    "--program-prefix=${targetPrefix}"

    # Unconditionally disable:
    # - musl target needs porting: https://sourceware.org/PR29477
    "--disable-gprofng"

    # By default binutils searches $libdir for libraries. This brings in
    # libbfd and libopcodes into a default visibility. Drop default lib
    # path to force users to declare their use of these libraries.
    "--with-lib-path=:"
  ]
  ++ lib.optionals withAllTargets [ "--enable-targets=all" ]
  ++ lib.optionals enableGold [
    "--enable-gold${lib.optionalString enableGoldDefault "=default"}"
    "--enable-plugins"
  ] ++ (if enableShared
      then [ "--enable-shared" "--disable-static" ]
      else [ "--disable-shared" "--enable-static" ])
  ++ (lib.optionals (stdenv.cc.bintools.isLLVM && lib.versionAtLeast stdenv.cc.bintools.version "17") [
      # lld17+ passes `--no-undefined-version` by default and makes this a hard
      # error; libctf.ver version script references symbols that aren't present.
      #
      # This is fixed upstream and can be removed with the future release of 2.43.
      # For now we allow this with `--undefined-version`:
      "LDFLAGS=-Wl,--undefined-version"
  ])
  ;

  # Fails
  doCheck = false;

  # Break dependency on pkgsBuildBuild.gcc when building a cross-binutils
  stripDebugList = if stdenv.hostPlatform != stdenv.targetPlatform then "bin lib ${stdenv.hostPlatform.config}" else null;

  # INFO: Otherwise it fails with:
  # `./sanity.sh: line 36: $out/bin/size: not found`
  doInstallCheck = (buildPlatform == hostPlatform) && (hostPlatform == targetPlatform);

  enableParallelBuilding = true;

  # For the same reason we don't split "lib" output we undo the $target/
  # prefix for installed headers and libraries we link:
  #   $out/$host/$target/lib/*     to $out/lib/
  #   $out/$host/$target/include/* to $dev/include/*
  # TODO(trofi): fix installation paths upstream so we could remove this
  # code and have "lib" output unconditionally.
  postInstall = lib.optionalString (hostPlatform.config != targetPlatform.config) ''
    ln -s $out/${hostPlatform.config}/${targetPlatform.config}/lib/*     $out/lib/
    ln -s $out/${hostPlatform.config}/${targetPlatform.config}/include/* $dev/include/
  '';

  passthru = {
    inherit targetPrefix;
    hasGold = enableGold;
    isGNU = true;
    # Having --enable-plugins is not enough, system has to support
    # dlopen() or equivalent. See config/plugins.m4 and configure.ac
    # (around PLUGINS) for cases that support or not support plugins.
    # No platform specific filters yet here.
    hasPluginAPI = enableGold;
  };

  meta = with lib; {
    description = "Tools for manipulating binaries (linker, assembler, etc.)";
    longDescription = ''
      The GNU Binutils are a collection of binary tools.  The main
      ones are `ld' (the GNU linker) and `as' (the GNU assembler).
      They also include the BFD (Binary File Descriptor) library,
      `gprof', `nm', `strip', etc.
    '';
    homepage = "https://www.gnu.org/software/binutils/";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [ ericson2314 lovesegfault ];
    platforms = platforms.unix;

    # INFO: Give binutils a lower priority than gcc-wrapper to prevent a
    # collision due to the ld/as wrappers/symlinks in the latter.
    priority = 10;
  };
})
