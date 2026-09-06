FROM swift:6.2-jammy

RUN apt-get update && apt-get install -y libdbus-1-dev pkg-config dpkg-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /src

CMD swift build -c release --static-swift-stdlib --product qudelix
