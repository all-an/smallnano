FROM ubuntu:22.04 AS builder

ARG ZIG_VERSION=0.15.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -C /opt -xf /tmp/zig.tar.xz \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY . .

RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

FROM scratch

COPY --from=builder /src/zig-out/bin/smallnano /smallnano

ENTRYPOINT ["/smallnano"]
