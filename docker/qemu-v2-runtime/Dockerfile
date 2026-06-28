FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    CMAKE_GENERATOR=Ninja \
    CC=gcc \
    CXX=g++ \
    RUNNABLE_QEMU_V2_IN_CONTAINER=1 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-lc"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils \
    bison \
    build-essential \
    ca-certificates \
    ccache \
    clang \
    cmake \
    coreutils \
    curl \
    diffutils \
    file \
    findutils \
    flex \
    gawk \
    git \
    gdb \
    gettext \
    libaio-dev \
    libattr1-dev \
    libboost-dev \
    libbz2-dev \
    libcap-ng-dev \
    libcapstone-dev \
    libcurl4-openssl-dev \
    libfdt-dev \
    libglib2.0-dev \
    libgnutls28-dev \
    libgcrypt20-dev \
    liblzma-dev \
    libncurses-dev \
    libpixman-1-dev \
    libseccomp-dev \
    libslirp-dev \
    libssl-dev \
    libstdc++-12-dev \
    libtool \
    liburing-dev \
    libxml2-dev \
    libzstd-dev \
    llvm \
    llvm-dev \
    lld \
    make \
    meson \
    ninja-build \
    patch \
    perl \
    python3 \
    python3-dev \
    python3-packaging \
    python3-pip \
    python3-pygraphviz \
    python3-pyelftools \
    python3-setuptools \
    python3-tomli \
    python3-venv \
    python3-yaml \
    pkg-config \
    rsync \
    sed \
    strace \
    tar \
    xz-utils \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

COPY smoke.sh /usr/local/bin/qemu-v2-runtime-smoke

RUN chmod +x /usr/local/bin/qemu-v2-runtime-smoke \
 && mkdir -p /workspace /scratch /opt/qemu-v2 /opt/runnable-v2 /root/.cache \
 && chmod 1777 /scratch

WORKDIR /workspace/Runnable-Rewriting

CMD ["/bin/bash"]
