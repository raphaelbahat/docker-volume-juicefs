FROM golang:1.23 AS builder

ARG GOPROXY
ENV GOPROXY=${GOPROXY:-"https://proxy.golang.org,direct"}
ARG JUICEFS_CE_VERSION
ENV JUICEFS_CE_VERSION=${JUICEFS_CE_VERSION:-"1.3.1"}
ARG JUICEFS_CE_SHA256
ARG ARCH
ENV ARCH=${ARCH:-"amd64"}

WORKDIR /docker-volume-juicefs
COPY . .
RUN apt-get update && apt-get install -y curl musl-tools tar gzip && \
    CC=/usr/bin/musl-gcc go build -o bin/docker-volume-juicefs --ldflags '-linkmode external -extldflags "-static"' .

WORKDIR /workspace
RUN curl -fsSL -o juicefs-ce.tar.gz https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_CE_VERSION}/juicefs-${JUICEFS_CE_VERSION}-linux-${ARCH}.tar.gz && \
    if [ -n "${JUICEFS_CE_SHA256}" ]; then echo "${JUICEFS_CE_SHA256}  juicefs-ce.tar.gz" | sha256sum -c -; fi && \
    tar -zxf juicefs-ce.tar.gz -C /tmp && \
    chmod +x /tmp/juicefs && \
    /tmp/juicefs --version | grep -q "${JUICEFS_CE_VERSION}" || (echo "CE version mismatch! Expected ${JUICEFS_CE_VERSION}" && /tmp/juicefs --version && exit 1)

RUN curl -fsSL -o /juicefs https://s.juicefs.com/static/juicefs && \
    chmod +x /juicefs

FROM python:3.12
RUN rm -f /bin && mkdir -p /bin /run/docker/plugins /jfs/state /jfs/volumes && \
    for f in /usr/bin/* /usr/sbin/*; do \
        [ "$(basename "$f")" != "juicefs" ] && ln -sf "$f" "/bin/$(basename "$f")" 2>/dev/null || true; \
    done
COPY --from=builder /docker-volume-juicefs/bin/docker-volume-juicefs /
COPY --from=builder /tmp/juicefs /bin/juicefs
COPY --from=builder /juicefs /usr/bin/
RUN /usr/bin/juicefs version && /bin/juicefs --version
CMD ["docker-volume-juicefs"]
