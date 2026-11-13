# PostgreSQL with gnomon: the extension, the C module preloaded and its heartbeat
# worker on, and the gnomon CLI. Every database named in GNOMON_DATABASES gets the extension and a
# heartbeat at first start.
#   docker build -f docker/Dockerfile -t gnomon/postgres .
#   docker run -e POSTGRES_PASSWORD=pw -p 5432:5432 gnomon/postgres
ARG PG_MAJOR=18
FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS cli
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY cli/ cli/
RUN cd cli && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w" -o /gnomon ./cmd/gnomon

FROM postgres:${PG_MAJOR}-bookworm AS build
ARG PG_MAJOR
RUN apt-get update && apt-get install -y --no-install-recommends build-essential postgresql-server-dev-${PG_MAJOR} python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Makefile gnomon.control ./
COPY src/ src/
COPY tools/ tools/
RUN make && make install && make -C src/c && make -C src/c install

FROM postgres:${PG_MAJOR}-bookworm
LABEL org.opencontainers.image.source="https://github.com/bitsinfra/gnomon"
ARG PG_MAJOR
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/gnomon* /usr/share/postgresql/${PG_MAJOR}/extension/
COPY --from=build /usr/lib/postgresql/${PG_MAJOR}/lib/gnomon_c.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=cli /gnomon /usr/local/bin/gnomon
COPY docker/init-gnomon.sh /docker-entrypoint-initdb.d/50-gnomon.sh
ENV GNOMON_DATABASES=postgres
CMD ["postgres", "-c", "shared_preload_libraries=gnomon_c", "-c", "wal_level=logical", "-c", "track_commit_timestamp=on"]
