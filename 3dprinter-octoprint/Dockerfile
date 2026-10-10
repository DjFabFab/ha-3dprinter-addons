ARG BUILD_FROM="ghcr.io/home-assistant/amd64-base-debian:trixie"
FROM ${BUILD_FROM}
ARG OCTOPRINT_VERSION="1.11.4"

# OctoPrint version baked into the image
ENV OCTOPRINT_VERSION=${OCTOPRINT_VERSION}

# Preparation for install of Caddy
RUN apt update \
    && apt install -y \
    --no-install-recommends \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https \
    gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

# Install dependencies
RUN apt update \
    && apt install -y \
        --no-install-recommends \
        python3-venv \
        python3-dev \
        python3-pip \
        python3-wheel \
        build-essential \
        caddy \
        libffi-dev \
        # Extras.
        ffmpeg \
        avrdude \
        dfu-util \
        dfu-programmer \
        stm32flash \
        # Development/testing
        vim \
    && \
    apt clean

# Bake OctoPrint base into /opt/octoprint with system python (D1: --target,
# not a venv, so PIP_USER=1 user-site installs keep working).
RUN python3 -m pip install --no-cache-dir --break-system-packages --target /opt/octoprint octoprint==${OCTOPRINT_VERSION}

# Runtime environment for split-venv: base in /opt/octoprint, user plugins in /data/plugins.
ENV PATH=/opt/octoprint/bin:${PATH}
ENV PYTHONPATH=/opt/octoprint
ENV PYTHONUSERBASE=/data/plugins
ENV PIP_USER=1
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# Copy root filesystem (split-venv: base lives in /opt/octoprint, /data holds
# config + user plugins only; cont-init migrates legacy installs).
COPY rootfs /
RUN chmod +x /etc/cont-init.d/*.sh
RUN chmod +x /etc/services.d/*/*
RUN chmod +x /scripts/*.sh

# Build-time assertion: base install is importable and the CLI resolves.
RUN octoprint --version \
    && python3 -c "import importlib.metadata; print(importlib.metadata.version('OctoPrint'))"
