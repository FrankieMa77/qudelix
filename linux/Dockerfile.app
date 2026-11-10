FROM swift:6.4-noble

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    libdbus-1-dev pkg-config libcurl4-openssl-dev binutils \
    libgtk-4-dev libadwaita-1-dev \
    xvfb xauth fonts-cantarell adwaita-icon-theme librsvg2-common libgl1-mesa-dri \
    dpkg-dev desktop-file-utils appstream dbus \
    libpipewire-0.3-dev pipewire pipewire-bin wireplumber libspa-0.2-modules procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
