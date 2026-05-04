#!/bin/bash
# Subnet-router tailscaled supervisor.
#
# Differences from the fluent-networks/tailscale-mikrotik entrypoint:
#   - no `--reset` on `tailscale up` (preserves prefs across restarts)
#   - single `up` invocation (the upstream loop cancels its own login attempts)
#   - explicit `tailscale set --webclient` AFTER up, so the :5252 UI/metrics
#     endpoint persists across container restarts by design
#   - kernel TUN by default (RouterOS 7.21+ exposes /dev/net/tun in every
#     container), with `--netfilter-mode=on` so Tailscale's stateful
#     filtering is actually effective. Set TS_USERSPACE=true to fall back
#     to gvisor netstack for environments without /dev/net/tun (local
#     `docker compose` testing where the host doesn't grant TUN to the
#     container).
#
# Job control is bash-managed; tini (PID 1) reaps and forwards SIGTERM.

set -euo pipefail
set -m

# Sysctl tuning — write directly to /proc/sys to avoid pulling in procps.
# The `[ -w … ] && echo` form silently no-ops if the kernel rejects the write
# (some sysctls are global and may be locked down by RouterOS).
write_sysctl() {
    local path="/proc/sys/$(echo "$1" | tr . /)"
    [ -w "$path" ] && echo "$2" > "$path" || true
}

# Subnet-router prerequisites:
#   - rp_filter=0 so tun0 ingress with non-tailnet src isn't dropped by the
#     reverse-path check (IPv4 only — there's no v6 rp_filter sysctl).
#   - forwarding=1 on both v4/v6 so the kernel routes tun0 ↔ veth-rt.
write_sysctl net.ipv4.conf.all.rp_filter 0
write_sysctl net.ipv4.conf.all.forwarding 1
write_sysctl net.ipv4.ip_forward 1
write_sysctl net.ipv6.conf.all.forwarding 1

# Network buffer tuning. magicsock would like 7 MB UDP socket buffers per
# direction (it tries SO_RCVBUFFORCE which needs CAP_NET_ADMIN beyond what
# RouterOS containers grant). Lift rmem_max/wmem_max so the regular SO_RCVBUF
# path lands the same target. If the kernel rejects (sysctl locked or shared
# with host), fail silent — the warning impacts throughput only, not correctness.
write_sysctl net.core.rmem_max 7340032
write_sysctl net.core.wmem_max 7340032
write_sysctl net.core.rmem_default 2097152
write_sysctl net.core.wmem_default 2097152


: "${TS_AUTHKEY:?TS_AUTHKEY env var is required (Tailscale auth key)}"
: "${TS_AUTH_ONCE:=false}"
: "${TS_HOSTNAME:=mikrotik-router}"
: "${TS_LOGIN_SERVER:=https://controlplane.tailscale.com}"
: "${TS_TAGS:=tag:mikrotik}"
: "${TS_PORT:=41641}"
# TS_USERSPACE=true forces gvisor netstack mode. Default (unset/false) uses a
# real kernel TUN — required for stateful filtering and netfilter integration.
: "${TS_USERSPACE:=false}"
# Comma-separated list of CIDRs to advertise. Empty = run "parked" (joined to
# the tailnet but not advertising any routes — useful during cutover so this
# node coexists with the legacy subnet router without competing for routes).
: "${TS_ADVERTISE_ROUTES:=}"

mkdir -p /var/lib/tailscale /var/run/tailscale

# Pin the socket path explicitly — both for tailscaled (where it listens) and
# every `tailscale` CLI call below (where it connects). Featuretag combos can
# shift the default path, so be explicit.
TS_SOCKET=/var/run/tailscale/tailscaled.sock

TAILSCALED_ARGS=(
    --statedir=/var/lib/tailscale
    --socket="${TS_SOCKET}"
    --tun="tun0"
    --port="${TS_PORT}"
)
if [ "${TS_USERSPACE}" = "true" ]; then
    echo "[entrypoint] starting tailscaled (userspace-networking, port=${TS_PORT})"
    TAILSCALED_ARGS+=( --tun=userspace-networking )
else
    if [ ! -c /dev/net/tun ]; then
        echo "[entrypoint] /dev/net/tun missing — set TS_USERSPACE=true to use netstack" >&2
        exit 1
    fi
    # Pre-create the tun device (tun2socks-style) so tailscaled inherits a
    # ready interface and doesn't pay device-creation latency on a slow CPU.
    # Idempotent: ignore "File exists" if a previous run left it behind.
    if ! ip link show tun0 >/dev/null 2>&1; then
        ip tuntap add mode tun dev tun0
    fi
    ip link set dev tun0 up

    # Force iptables-legacy mode. Alpine 3.22's `iptables` package defaults
    # /usr/sbin/iptables to xtables-nft-multi; RouterOS's kernel has no
    # nf_tables module, so the nft variant fails with `Could not fetch rule
    # set generation id: Invalid argument`. Repoint the symlinks at the
    # legacy multi-call binary (alpine has no `update-alternatives`).
    if [ -x /usr/sbin/xtables-legacy-multi ]; then
        for cmd in iptables ip6tables iptables-save iptables-restore ip6tables-save ip6tables-restore; do
            ln -sf /usr/sbin/xtables-legacy-multi "/usr/sbin/${cmd}"
        done
    fi
    export TS_DEBUG_FIREWALL_MODE=iptables
    echo "[entrypoint] starting tailscaled (kernel TUN tun0, port=${TS_PORT}, firewall=iptables-legacy)"
fi
/usr/local/bin/tailscaled "${TAILSCALED_ARGS[@]}" &
TAILSCALED_PID=$!

echo "[entrypoint] waiting for tailscaled local API socket"
# Wait for the LocalAPI to accept a status query — that means tailscaled is up.
# Don't loop `tailscale up`; each invocation cancels the previous login attempt
# and the daemon never converges.
for _ in $(seq 1 60); do
    if /usr/local/bin/tailscale --socket="${TS_SOCKET}" status >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${TAILSCALED_PID}" 2>/dev/null; then
        echo "[entrypoint] tailscaled exited before LocalAPI came up" >&2
        exit 1
    fi
    sleep 0.5
done

# Build `up` arguments. Routes are only advertised when TS_ADVERTISE_ROUTES is
# non-empty (parked-by-default), so the same image can be deployed alongside a
# legacy subnet router and brought into service by setting the env later.
#
# In netstack mode netfilter integration is meaningless (traffic bypasses the
# kernel firewall path), so we explicitly turn it off. In kernel-TUN mode we
# pass --netfilter-mode=on so tailscaled installs rules; this also makes the
# up command idempotent across upgrades — `tailscale up` refuses to silently
# change a pref away from a non-default value, so we always state our intent.
#
# --accept-dns=true so MagicDNS resolves *.ts.net inside the container (needed
# for any tailnet-targeted helper that goes by hostname, not IP).
# --stateful-filtering=false because this node is a subnet router and needs
# to forward packets whose source isn't a known tailnet peer (e.g., LAN
# clients pre-routed through the container, or the RouterOS host itself).
UP_ARGS=(
    --authkey="${TS_AUTHKEY}"
    --hostname="${TS_HOSTNAME}"
    --login-server="${TS_LOGIN_SERVER}"
    --advertise-tags="${TS_TAGS}"
    --accept-dns=true
    --accept-routes=true
    --stateful-filtering=false
)
if [ "${TS_USERSPACE}" = "true" ]; then
    UP_ARGS+=( --netfilter-mode=off )
else
    UP_ARGS+=( --netfilter-mode=on )
fi
if [ -n "${TS_ADVERTISE_ROUTES}" ]; then
    UP_ARGS+=( --advertise-routes="${TS_ADVERTISE_ROUTES}" )
    echo "[entrypoint] advertising routes: ${TS_ADVERTISE_ROUTES}"
else
    echo "[entrypoint] no TS_ADVERTISE_ROUTES set — running parked"
fi

echo "[entrypoint] running 'tailscale up' (single attempt, blocks until joined)"
/usr/local/bin/tailscale --socket="${TS_SOCKET}" up "${UP_ARGS[@]}"
echo "[entrypoint] tailscale up OK"

# Persistent webclient — idempotent, fine to re-run on every boot.
echo "[entrypoint] enabling webclient (:5252)"
/usr/local/bin/tailscale --socket="${TS_SOCKET}" set --webclient

# Posture checking — reports OS / hostname / serial back to the control plane
# so srcPosture grants in policy.hujson can match on this node. Idempotent.
echo "[entrypoint] enabling posture reporting"
/usr/local/bin/tailscale --socket="${TS_SOCKET}" set --report-posture

echo "[entrypoint] supervising tailscaled (pid=${TAILSCALED_PID})"
wait "${TAILSCALED_PID}"
