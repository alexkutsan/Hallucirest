FROM crystallang/crystal:latest

RUN apt-get update && apt-get install -y \
    git \
    curl \
    sudo \
    just \
    python3 \
    python3-pip \
    python3-venv \
    # Dependencies for building kcov (code coverage)
    binutils-dev \
    libcurl4-openssl-dev \
    zlib1g-dev \
    libdw-dev \
    libiberty-dev \
    cmake \
    build-essential \
    # Node.js (includes npm and npx)
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Build and install kcov for code coverage
RUN cd /tmp && \
    git clone --depth 1 https://github.com/SimonKagstrom/kcov.git && \
    cd kcov && mkdir build && cd build && \
    cmake .. && make -j$(nproc) && \
    make install && \
    cd / && rm -rf /tmp/kcov

# Create non-root user with UID/GID 1000 (devcontainer will remap to host UID/GID)
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

RUN if getent passwd ${USER_UID} > /dev/null 2>&1; then \
        userdel -r $(getent passwd ${USER_UID} | cut -d: -f1); \
    fi \
    && if getent group ${USER_GID} > /dev/null 2>&1; then \
        groupdel $(getent group ${USER_GID} | cut -d: -f1); \
    fi \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# Install uv (Python package manager) globally
RUN curl -LsSf https://astral.sh/uv/install.sh | env sh

RUN mkdir -p /bin && \
    curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /bin

WORKDIR /workspace
USER $USERNAME