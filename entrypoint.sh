#!/usr/bin/env bash

msg(){
    echo
    echo "==> $*"
    echo
}

err(){
    echo 1>&2
    echo "==> $*" 1>&2
    echo 1>&2
}

set_output(){
    echo "$1=$2" >> $GITHUB_OUTPUT
}

extract_tarball(){
    echo "Extracting $1 to $2"
    tar xf "$1" -C "$2"
}

workdir="$GITHUB_WORKSPACE"
arch="$1"
compiler="$2"
defconfig="$3"
image="$4"
repo_name="${GITHUB_REPOSITORY/*\/}"
zipper_path="${ZIPPER_PATH:-zipper}"
kernel_path="${KERNEL_PATH:-.}"
name="${NAME:-$repo_name}"

msg "Installing packages..."
dnf group install development-tools -y
dnf install llvm lld bc bison ca-certificates curl flex glibc-devel.i686 glibc-devel binutils-devel openssl python3 python2 zstd clang gcc-arm-linux-gnu dtc libxml2 libarchive openssl-devel perl tomsfastmath-devel wget xz -y
ln -sf "/usr/bin/python3" /usr/bin/python
set_output hash "$(cd "$kernel_path" && git rev-parse HEAD || exit 127)"
msg "Installing toolchain..."
if [[ $arch = "arm64" ]]; then
    arch_opts="ARCH=${arch} SUBARCH=${arch}"
    export ARCH="$arch"
    export SUBARCH="$arch"
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"

    if [[ $compiler = gcc/* ]]; then
        ver_number="${compiler/gcc\/}"
        make_opts=""
        host_make_opts=""

        if ! apt install -y --no-install-recommends gcc-"$ver_number" g++-"$ver_number" \
            gcc-"$ver_number"-aarch64-linux-gnu gcc-"$ver_number"-arm-linux-gnueabi; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi

        ln -sf /usr/bin/gcc-"$ver_number" /usr/bin/gcc
        ln -sf /usr/bin/g++-"$ver_number" /usr/bin/g++
        ln -sf /usr/bin/aarch64-linux-gnu-gcc-"$ver_number" /usr/bin/aarch64-linux-gnu-gcc
        ln -sf /usr/bin/arm-linux-gnueabi-gcc-"$ver_number" /usr/bin/arm-linux-gnueabi-gcc

    elif [[ $compiler = evagcc/* ]]; then
        ver_number="${compiler/evagcc\/}"
        host_make_opts=""

	make_opts="CROSS_COMPILE=aarch64-elf- CROSS_COMPILE_ARM32=arm-eabi- AR=aarch64-elf-ar"
	make_opts+=" NM=llvm-nm LD=ld.lld OBCOPY=llvm-objcopy"
	make_opts+=" OBJDUMP=aarch64-elf-objdump STRIP=aarch64-elf-strip"

        url="https://github.com/mvaisakh/gcc-arm64/archive/${ver_number}.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/evagcc-arm64-"${ver_number}".tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        url="https://github.com/mvaisakh/gcc-arm/archive/${ver_number}.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/evagcc-arm-"${ver_number}".tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        extract_tarball /tmp/evagcc-arm64-"${ver_number}".tar.gz /
        cd /gcc-arm64-"${ver_number}"* || exit 127
        evagcc64_path="$(pwd)"
        extract_tarball /tmp/evagcc-arm-"${ver_number}".tar.gz /
        cd /gcc-arm-"${ver_number}"* || exit 127
        evagcc_path="$(pwd)"

        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$evagcc64_path/bin:$evagcc_path/bin:${PATH}"


    elif [[ $compiler = clang/* ]]; then
        ver="${compiler/clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"
        
        if $binutils; then
            additional_packages="binutils binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            # Most android kernels still need binutils as the assembler, but it will
            # not be used when the Makefile is patched to make use of LLVM_IAS option
            additional_packages="binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        if ! apt install -y --no-install-recommends clang-"$ver_number" \
            lld-"$ver_number" llvm-"$ver_number" $additional_packages; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi

        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang
        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang++
        ln -sf /usr/bin/ld.lld-"$ver_number" /usr/bin/ld.lld

        for i in /usr/bin/llvm-*-"$ver_number"; do
            ln -sf "$i" "${i/-$ver_number}"
        done

        export CLANG_TRIPLE="aarch64-linux-gnu-"

    elif [[ $compiler = proton-clang/* ]]; then
        ver="${compiler/proton-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://github.com/kdrag0n/proton-clang/archive/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        # Due to different time in container and the host,
        # disable certificate check
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/proton-clang-"${ver_number}".tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev || exit 127
        extract_tarball /tmp/proton-clang-"${ver_number}".tar.gz /
        cd /proton-clang-"${ver_number}"* || exit 127
        proton_path="$(pwd)"
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$proton_path/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"

    elif [[ $compiler = neutron-clang/* ]]; then
        ver="${compiler/neutron-clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev zstd libxml2 libarchive-tools || exit 127
        mkdir /neutron-clang && cd /neutron-clang
        curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
        if ! bash antman -S=${ver_number} &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="/neutron-clang/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"

    elif [[ $compiler = zyc-clang/* ]]; then
        ver="${compiler/zyc-clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"
        isLatest="$([[ $ver = *latest* ]] && echo true || echo false)"

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev zstd libxml2 libarchive-tools || exit 127
        if $isLatest; then
            url=$(curl https://raw.githubusercontent.com/ZyCromerZ/Clang/main/Clang-main-link.txt)
        else
            url="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-${ver_number}-release/Clang-17.0.0-${ver_number}.tar.gz"
        fi

        mkdir /zyc-clang && cd /zyc-clang
        curl -LO ${url}
        tar -zxf *.tar.gz
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="/zyc-clang/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"

    elif [[ $compiler = aosp-clang/* ]]; then
        ver="${compiler/aosp-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-clang.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm64.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-host.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        mkdir -p /aosp-clang /aosp-gcc-arm64 /aosp-gcc-arm /aosp-gcc-host
        extract_tarball /tmp/aosp-clang.tar.gz /aosp-clang
        extract_tarball /tmp/aosp-gcc-arm64.tar.gz /aosp-gcc-arm64
        extract_tarball /tmp/aosp-gcc-arm.tar.gz /aosp-gcc-arm
        extract_tarball /tmp/aosp-gcc-host.tar.gz /aosp-gcc-host

        for i in /aosp-gcc-host/bin/x86_64-linux-*; do
            ln -sf "$i" "${i/x86_64-linux-}"
        done

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev || exit 127

        export PATH="/aosp-clang/bin:/aosp-gcc-arm64/bin:/aosp-gcc-arm/bin:/aosp-gcc-host/bin:$PATH"
        export CLANG_TRIPLE="aarch64-linux-gnu-"

    else
        err "Unsupported toolchain string. refer to the README for more detail"
        exit 100
    fi
else
    err "Currently this action only supports arm64, refer to the README for more detail"
    exit 100
fi

if [ ! -n $KBUILD_BUILD_USER ]; then
    export KBUILD_BUILD_USER=github
fi

if [ ! -n $KBUILD_BUILD_HOST ]; then
    export KBUILD_BUILD_HOST=githubCI
fi

cd "$workdir"/"$kernel_path" || exit 127
start_time="$(date +%s)"
date="$(date +%d%m%Y-%I%M)"
tag="$(git branch | sed 's/*\ //g')"
if [ ! -n $tag ]; then
    echo "branch/tag: $tag"
else
    echo "no branch/tag specified"
fi
echo "make options:" $arch_opts $make_opts $host_make_opts
msg "Generating defconfig from \`make $defconfig\`..."
if ! make O=out $arch_opts $make_opts $host_make_opts "$defconfig"; then
    err "Failed generating .config, make sure it is actually available in arch/${arch}/configs/ and is a valid defconfig file"
    exit 2
fi
msg "Begin building kernel..."

make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)" prepare

if ! make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)"; then
    err "Failed building kernel, probably the toolchain is not compatible with the kernel, or kernel source problem"
    exit 3
fi
set_output elapsed_time "$(echo "$(date +%s)"-"$start_time" | bc)"
msg "Packaging the kernel..."
if [ ! -n $tag ]; then
    zip_filename="${name}-${tag}-${date}.zip"
else
    zip_filename="${name}-${date}.zip"
fi
if [[ -e "$workdir"/"$zipper_path" ]]; then
    cp out/arch/"$arch"/boot/"$image" "$workdir"/"$zipper_path"/"$image"
    cp out/arch/"$arch"/boot/dts/*/*.dtb "$workdir"/"$zipper_path"/dtb
    cp out/arch/"$arch"/boot/dtbo.img "$workdir"/"$zipper_path"/dtbo.img
    cd "$workdir"/"$zipper_path" || exit 127
    rm -rf .git
    zip -r9 "$zip_filename" . -x .gitignore README.md || exit 127
    set_output outfile "$workdir"/"$zipper_path"/"$zip_filename"
    cd "$workdir" || exit 127
    exit 0
else
    msg "No zip template provided, releasing the kernel image instead"
    set_output outfile out/arch/"$arch"/boot/"$image"
    exit 0
fi
