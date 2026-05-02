# Minimal Tailscale subnet router, built to replace
# fluent-networks/tailscale-mikrotik. Compared to that image this one:
#   - is built from a pinned upstream Tailscale tag (not a moving target),
#   - trims via featuretags (drops ssh, taildrop, serve, funnel, etc.),
#   - keeps webclient enabled by design (entrypoint calls
#     `tailscale set --webclient` after `up`, persistent across restarts —
#     fluent-networks runs `tailscale up --reset` every boot, which wipes
#     pref state, and its RUNNING_SCRIPT hook expects a file path so the
#     "obvious" workaround silently no-ops),
#   - runs a single `tailscale up` (no register/abort loop).
#
# Architecture: linux/arm/v7 to match the RB3011's ARMv7 cores.
# Pin the Go toolchain to whatever the chosen Tailscale tag declares in
# go.mod — v1.96.5 declares `go 1.26.1`, so that's the FROM line below.

ARG TAILSCALE_VERSION=1.96.5
ARG GO_VERSION=1.26.1
ARG ALPINE_VERSION=3.22

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS build

ARG TAILSCALE_VERSION
WORKDIR /src
RUN apk add git upx \
 && git -c advice.detachedHead=false clone --depth=1 \
      --branch v${TAILSCALE_VERSION} \
      https://github.com/tailscale/tailscale.git .

# featuretags `--min` strips everything; `--add=` pins what we need:
#   linuxfw             - linux firewall plumbing — required for any kernel
#                         firewall integration. Pairs with `iptables` and/or
#                         `nftables` featuretags below; `linuxfw` alone won't
#                         compile in either backend.
#   iptables            - Linux iptables runner. WITHOUT this, tailscaled
#                         errors `could not setup netfilter: iptables disabled
#                         in build` even when the runtime image has the
#                         iptables binary. Required on the RB3011 because
#                         RouterOS kernel ships xtables (iptables-legacy)
#                         but not nf_tables.
#                         Required for --netfilter-mode=on and Tailscale's
#                         --stateful-filtering on subnet routers. RouterOS
#                         containers DO expose /dev/net/tun (verified
#                         2026-04-30 on RouterOS 7.23rc2 — earlier docs and
#                         the fluent-networks image were stale on this), so
#                         we run a real kernel TUN now and netfilter rules
#                         actually see traffic.
#   osrouter            - kernel route table programming. Required pair with
#                         linuxfw for kernel-TUN mode; without it tailscaled
#                         errors with "tailscaled was built without OSRouter
#                         support" the moment it tries to NewUserspaceEngine
#                         with a real tun device. Only relevant alongside a
#                         kernel TUN — netstack mode doesn't need it.
#   netstack            - kept as fallback for environments without TUN; lets
#                         the same image run under docker compose locally
#                         (no /dev/net/tun) without code changes — just set
#                         --tun=userspace-networking in the entrypoint.
#   advertiseroutes     - subnet route advertisement
#   useroutes           - accept routes from peer subnet routers (lets this
#                         node reach things behind, e.g., ams-exit if it ever
#                         advertises something)
#   webclient           - the :5252 web UI / metrics endpoint we want
#                         persistently on, NOT subject to the upstream
#                         --reset-on-every-boot bug
#   dns                 - kept in for now even though we run --accept-dns=false;
#                         lets us flip the flag later without rebuilding.
#                         Drop in a future image if size matters.
#   bakedroots          - embedded CA roots so control-plane TLS works
#                         regardless of /etc/ssl/certs in the runtime image
#   clientmetrics       - netstack references clientmetric.NewCounterFunc and
#                         won't compile without this. Cheap to keep.
#   unixsocketidentity  - omit stub causes actor.Permissions to deny everything
#                         and the CLI hangs in an "access denied" loop. Keep
#                         this until upstream fixes the stub.
#   debug               - tailscale up depends on /localapi/v0/watch-ipn-bus,
#                         which is registered only when HasDebug||HasServe.
#                         debug is the lighter of the two.
#
# We deliberately drop:
#   ssh, taildrop, serve, funnel, exitnodes, captiveportal, portmapper,
#   relayserver — not used by a subnet router.
#
# If the build fails with an "undefined" reference from a transitive
# dependency, add the missing tag back and document why above.
ARG TARGETARCH
ARG TARGETVARIANT
# Build flags rationale:
#   -trimpath        - strip absolute paths (smaller, reproducible).
#   -buildvcs=false  - don't embed git metadata; saves a few KB and one less
#                      thing in the binary diff between builds.
#   -ldflags -w -s   - strip DWARF debug info + symbol table (~30% smaller).
#   -ldflags -buildid= - drop the buildid string (UPX dedups better).
#   GOAMD64/GOARM    - target ARMv7 fully (FPU, hardfloat). Already at v7,
#                      which is the max for this CPU.
#   GOEXPERIMENT     - left at default; `newinliner` is now baseline in 1.26.
# UPX --lzma --best then re-compresses the stripped binary; on tailscaled
# this drops the on-disk size from ~30MB to ~7MB without measurable startup
# overhead (one-time decompress on exec).
RUN set -eux; \
    TAGS="$(go run ./cmd/featuretags --min --add=tailnetlock,netstack,linuxfw,iptables,osrouter,dns,bakedroots,clientmetrics,unixsocketidentity,debug,advertiseroutes,useroutes,webclient)"; \
    GOARM="${TARGETVARIANT#v}"; \
    export CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" GOARM="${GOARM:-}"; \
    export VERSION_LONG="${TAILSCALE_VERSION}"; \
    export VERSION_SHORT="${TAILSCALE_VERSION}"; \
    LDFLAGS="-w -s -buildid= \
        -X tailscale.com/version.Long=${VERSION_LONG} \
        -X tailscale.com/version.Short=${VERSION_SHORT}"; \
    go build -trimpath -buildvcs=false \
      -ldflags="${LDFLAGS}" -tags="${TAGS}" \
      -o /out/tailscaled ./cmd/tailscaled; \
    go build -trimpath -buildvcs=false \
      -ldflags="${LDFLAGS}" -tags="${TAGS}" \
      -o /out/tailscale ./cmd/tailscale; \
    upx --lzma --best /out/tailscaled /out/tailscale

FROM alpine:${ALPINE_VERSION}
# Runtime tooling — minimum viable set:
#   ca-certificates-bundle - just the ca-certificates.crt file. Replaces
#                     `ca-certificates` proper, which drags in libcrypto3 +
#                     libssl3 (~3.4 MB) for OpenSSL's c_rehash tool.
#                     Tailscale's Go binary is statically linked and reads
#                     /etc/ssl/certs/ca-certificates.crt directly — it never
#                     touches libssl. The bundle alone is sufficient.
#   bash            - entrypoint shebang; busybox sh lacks arrays.
#   tini            - PID 1 reaper / signal forwarder.
#   iproute2-minimal - just `ip` (no `tc`, no `bridge`). Saves ~700 KB vs
#                     full iproute2. Entrypoint only needs `ip tuntap add`
#                     and `ip link set up`, both in the minimal subset.
#   iptables        - the iptables CLI suite (default = xtables-nft-multi).
#   iptables-legacy - the xtables-legacy-multi binary; required because
#                     RouterOS kernel ships xtables only, not nf_tables.
#                     Without this, tailscaled's nftables runner hangs on
#                     a netlink ack the kernel can't send and the wgengine
#                     watchdog fires at 45s. Entrypoint repoints
#                     /usr/sbin/iptables -> xtables-legacy-multi at start.
# Dropped from previous iterations:
#   nftables (no kernel support, doesn't work on this device)
#   procps (sysctl replaced with direct /proc/sys writes)
#   net-tools, bridge-utils (debug utilities not needed in production)
#   sudo (entrypoint runs as PID 1 root; no sudo needed)
RUN apk add --no-cache ca-certificates-bundle bash tini iproute2-minimal \
        iptables iptables-legacy

COPY --from=build /out/tailscaled /out/tailscale /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER root:root
# tailscaled state. Bind-mount /usb1/tailscale-router-state on top of this
# when running on the router so the node identity persists across container
# restarts (otherwise re-auth required every boot, burning a fresh key).
VOLUME ["/var/lib/tailscale"]


# Invoked via `bash` rather than direct exec so /entrypoint.sh can be a
# bind-mount from /usb1 — RouterOS strips the execute bit on bind-mounted
# files (security default), but bash only needs the file to be readable.
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "/entrypoint.sh"]
