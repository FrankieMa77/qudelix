FROM swift:6.4-jammy

RUN apt-get update \
 && apt-get install -y --no-install-recommends libdbus-1-dev pkg-config libcurl4-openssl-dev binutils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
