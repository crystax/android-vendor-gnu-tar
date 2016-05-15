#!/bin/sh

error()
{
    echo "*** ERROR: $@" 1>&2
}

THISFILE=""
if [ "x$BASH_VERSION" != "x" ]; then
    THISFILE=${BASH_SOURCE[0]}
elif [ "x$ZSH_VERSION" != "x" ]; then
    THISFILE=${(%):-%x}
else
    error "we're running in unknown shell (only BASH or ZSH are supported)!"
    return 1
fi

MYDIR=$(cd $(dirname $THISFILE) && pwd)

if [ -z "$NDK" ]; then
    error "NDK was not defined!"
    return 1
fi

if [ -z "$ABI" ]; then
    error "ABI was not defined!"
    return 1
fi

if [ -z "$OUTDIR" ]; then
    OUTDIR=$MYDIR/out/$ABI
fi

OSTYPE=$(uname -s | tr '[A-Z]' '[a-z]')
case $OSTYPE in
    linux|darwin)
        ;;
    *)
        error "Unsupported host OS: '$OSTYPE'"
        return 1
esac

OSARCH=$(uname -m)

HOST_TAG=${OSTYPE}-${OSARCH}

GCC_VERSION=5

case $ABI in
    armeabi|armeabi-v7a|armeabi-v7a-hard)
        TARGET=arm-linux-androideabi
        ;;
    arm64-v8a)
        TARGET=aarch64-linux-android
        ;;
    x86)
        TARGET=i686-linux-android
        ;;
    x86_64)
        TARGET=x86_64-linux-android
        ;;
    mips)
        TARGET=mipsel-linux-android
        ;;
    mips64)
        TARGET=mips64el-linux-android
        ;;
    *)
        error "Unsupported ABI: '$ABI'"
        return 1
esac

case $ABI in
    armeabi*)
        ARCH=arm
        ;;
    arm64*)
        ARCH=arm64
        ;;
    *)
        ARCH=$ABI
esac

case $ABI in
    x86|x86_64)
        TCNAME=$ABI
        ;;
    *)
        TCNAME=$TARGET
esac

case $ABI in
    armeabi)
        ARCHFLAGS="-march=armv5te -mtune=xscale -msoft-float"
        ;;
    armeabi-v7a)
        ARCHFLAGS="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp"
        ;;
    armeabi-v7a-hard)
        ARCHFLAGS="-march=armv7-a -mfpu=vfpv3-d16 -mhard-float"
        ;;
    *)
        ARCHFLAGS=""
esac

case $ABI in
    armeabi*)
        ARCHFLAGS="$ARCHFLAGS -mthumb"
        ;;
esac

LFLAGS=""
case $ABI in
    armeabi-v7a*)
        LFLAGS="$LFLAGS -Wl,--fix-cortex-a8"
        ;;
esac

case $ABI in
    armeabi-v7a-hard)
        LFLAGS="$LFLAGS -Wl,--no-warn-mismatch"
        ;;
esac

case $ABI in
    armeabi*|x86|mips)
        APILEVEL=16
        ;;
    arm64*|x86_64|mips64)
        APILEVEL=21
        ;;
esac

CROSS=$NDK/toolchains/${TCNAME}-${GCC_VERSION}/prebuilt/${HOST_TAG}/bin/${TARGET}

BINDIR=$OUTDIR/bin
SYSROOT=$OUTDIR/sysroot

rm -Rf $BINDIR || return 1
mkdir -p $BINDIR || return 1

mkdir -p $SYSROOT/ || return 1
rsync -a --delete $NDK/platforms/android-${APILEVEL}/arch-${ARCH}/ $SYSROOT/ || return 1
find $SYSROOT/ -name 'libcrystax.*' -delete
cp -f $NDK/sources/crystax/libs/$ABI/libcrystax.so $SYSROOT/usr/lib/ || return 1

{
    echo "#!/bin/sh"
    echo "exec $NDK/tools/adbrunner --abi=$ABI --log=$OUTDIR/adbrunner.log --pie \"\$@\""
} | cat >$BINDIR/${TARGET}-adbrunner
test $? -eq 0 || return 1
chmod +x $BINDIR/${TARGET}-adbrunner || return 1

LAUNCHER=$BINDIR/${TARGET}-adbrunner
export LAUNCHER

upcase()
{
    echo "$@" | tr '[a-z]' '[A-Z]'
}

mktool()
{
    local TOOL=$1

    {
        echo "#!/bin/sh"
        echo "run()"
        echo "{"
        echo "    echo \"## COMMAND: \$@\" 1>&2"
        echo "    exec \"\$@\""
        echo "}"
        CMD="${CROSS}-${TOOL}"
        case $TOOL in
            gcc)
                CMD="$CMD ${ARCHFLAGS}"
                CMD="$CMD -fPIE -pie"
                CMD="$CMD --sysroot=$SYSROOT"
                CMD="$CMD $LFLAGS"
                ;;
        esac
        echo "run $CMD \"\$@\""
    } | cat >$BINDIR/${TARGET}-${TOOL}
    test $? -eq 0 || return 1
    chmod +x $BINDIR/${TARGET}-${TOOL} || return 1
    return 0
}

for tool in gcc as ar ranlib strip; do
    mktool $tool || return 1
    eval $(upcase $tool)=$BINDIR/${TARGET}-${tool}
done

PATH=$BINDIR:$PATH
export PATH
