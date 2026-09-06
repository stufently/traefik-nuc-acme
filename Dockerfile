# syntax=docker/dockerfile:1
# Patched Traefik with configurable ACME CSR subject. No Node, no dashboard assets.

FROM golang:1.27-alpine@sha256:cf6fca6641884b8433441b2b0652976f975e1d0fdd26d177eaaf8596087f3125 AS builder

RUN apk add --no-cache git patch ca-certificates upx

WORKDIR /src
COPY .upstream/traefik-v3.7.13.tar.gz /tmp/traefik.tar.gz
COPY patches/0001-csr-subject.patch /tmp/csr-subject.patch
RUN tar -xzf /tmp/traefik.tar.gz \
    && mv traefik-3.7.13 traefik \
    && cd traefik \
    && patch -p1 < /tmp/csr-subject.patch

WORKDIR /src/traefik

ARG VERSION=v3.7.13-nuc.1
ARG CODENAME=cheddar
ARG BUILD_DATE=unknown

ENV CGO_ENABLED=0
ENV GOPROXY=https://proxy.golang.org,direct
ENV GOSUMDB=sum.golang.org
ENV GOFLAGS=-mod=mod

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath \
      -ldflags="-s -w \
        -X github.com/traefik/traefik/v3/pkg/version.Version=${VERSION} \
        -X github.com/traefik/traefik/v3/pkg/version.Codename=${CODENAME} \
        -X github.com/traefik/traefik/v3/pkg/version.BuildDate=${BUILD_DATE}" \
      -o /out/traefik ./cmd/traefik \
    && upx --best --lzma /out/traefik

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache --no-progress ca-certificates tzdata

COPY --from=builder /out/traefik /traefik

EXPOSE 80
VOLUME ["/tmp"]

ENTRYPOINT ["/traefik"]
