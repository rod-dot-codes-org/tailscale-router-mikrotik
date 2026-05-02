# On-router deployment for the tailscale-router container.
#
# NOTE — the IPs and MAC addresses below are the values from the original
# RB3011 deployment this script was written for. They are illustrative,
# not authoritative. Before /import, adjust:
#   - veth `address=` and `gateway=` to match your bridge-containers subnet
#   - `mac-address=` and `container-mac-address=` to anything stable and
#     not colliding with other interfaces (or remove them and let RouterOS
#     auto-assign)
#   - the bridge name in `/interface bridge port`
#
# Adds a veth on bridge-containers (172.17.0.5 in the example) running our
# own minimal tailscaled — designed to replace fluent-networks/tailscale-mikrotik
# (the subnet router) once it's been verified in coexistence.
#
# Coexist layout on bridge-containers (don't break):
#   veth-ts    172.17.0.2  fluent-networks/tailscale-mikrotik (current subnet router — STAYS for now)
#   veth-dns   172.17.0.3  klutchell/dnscrypt-proxy            (DoH forwarder)
#   veth-tsdns 172.17.0.4  mikrotik-tailscale-dns              (MagicDNS exposer)
#   veth-rt    172.17.0.5  mikrotik-tailscale-router           (THIS deploy — parked initially)
#
# Magicsock UDP port: this container listens on 41642 (NOT 41641) so it
# doesn't collide with fluent-networks during coexist. The
# fwd6-tailscale-magicsock firewall rule still points at 41641, so this new
# node falls back to DERP for inbound until cutover. Acceptable for a
# parked node; flip TS_PORT to 41641 (and update the firewall rule's target
# IPv6) once the legacy container is decommissioned.
#
# --- Pre-req steps before /import (run from dev machine) ---
#
#   # 1. Build the image and copy the tar onto the router.
#   cd tailscale-router && ./build.sh
#   scp -i ~/.ssh/rodcodes \
#       tailscale-router/tailscale-router.tar \
#       rodcodes@192.168.1.1:/usb1/container-images/tailscale-router.tar
#
#   # 2. Generate a Tailscale auth key in the admin console:
#   #      Reusable: NO    Ephemeral: NO    Tags: tag:mikrotik
#   #    (matches the --advertise-tags in entrypoint.sh)
#   #    Set the AUTH_KEY env value AFTER /import via:
#   #      /container envs set [find list=tailscale-router and key=AUTH_KEY] value=<real-key>
#
#   # 3. Make sure the state dir exists on the router.
#   ssh -i ~/.ssh/rodcodes rodcodes@192.168.1.1 \
#       '/file/add name=/usb1/tailscale-router-state type=directory' || true
#
#   # 4. Then on the router:
#   /import file-name=tailscale-router-deploy.rsc
#
# -----------------------------------------------------------------------------

# Idempotent: clean any prior attempts
:foreach c in=[/container find where name~"tailscale-router"] do={
    /container stop $c
    :delay 2s
    /container remove $c
}
:foreach m in=[/container mounts find where list="tailscale-router-state"] do={/container mounts remove $m}
:foreach p in=[/interface bridge port find where interface="veth-rt"] do={/interface bridge port remove $p}
:foreach v in=[/interface veth find where name="veth-rt"] do={/interface veth remove $v}

# --- veth ---
# v4 only at create-time. The hourly `update-container-v6` script iterates
# every veth on bridge-containers and patches a static v6 from the current
# /56 PD onto each one (suffix matches the v4 last octet → ::5).
/interface veth
add name=veth-rt \
    mac-address=26:61:F8:5A:27:E3 \
    container-mac-address=26:61:F8:5A:27:E4 \
    address=172.17.0.5/16 \
    gateway=172.17.0.1 \
    dhcp=no \
    comment="managed-by=config-tool component=tailscale-router-container"

/interface bridge port
add bridge=bridge-containers interface=veth-rt \
    comment="managed-by=config-tool component=tailscale-router-container"

# --- Container mounts ---
# Persist tailscaled state across container restarts. Without this the node
# has to re-auth every boot, burning the auth-key each time.
/container mounts
add list=tailscale-router-state \
    src=/usb1/tailscale-router-state \
    dst=/var/lib/tailscale

# --- Container itself ---
/container
add file=/usb1/tailscale-router.tar \
    interface=veth-rt \
    hostname=mikrotik-router \
    root-dir=/usb1/containers/tailscale-router \
    mountlists=tailscale-router-state \
    dns=1.1.1.1,8.8.8.8,2606:4700:4700::1111,2001:4860:4860::8888 \
    logging=yes \
    start-on-boot=yes \
    comment="managed-by=config-tool component=tailscale-router-container"

# --- Container envs ---
# AUTH_KEY is the only required env. Replace via /container envs set after
# /import — the placeholder won't auth. The mikrotik export scrub redacts
# AUTH_KEY* from the committable export (see _SECRET_KEY_RE in cli.py).
#
# TS_ADVERTISE_ROUTES is intentionally empty — the container will join the
# tailnet without competing with the legacy subnet router for routes.
# When ready to cut over:
#   /container envs set [find list=tailscale-router and key=TS_ADVERTISE_ROUTES] \
#       value="192.168.1.1/32,172.17.0.3/32"
#   /container/stop [find where name~"tailscale-router"]
#   /container/start [find where name~"tailscale-router"]
#   # then stop the legacy container:
#   /container/stop [find where name~"tailscale-mikrotik"]
/container envs
:foreach e in=[/container envs find where list="tailscale-router"] do={/container envs remove $e}
add list=tailscale-router key=TS_AUTH_ONCE value="true"
# TS_AUTHKEY left empty — set after /import via:
#   /container envs set [find list=tailscale-router and key=TS_AUTHKEY] value=<real-key>
# Generate the key in the admin console with tag:mikrotik (see header comment).
add list=tailscale-router key=TS_AUTHKEY value=""
add list=tailscale-router key=TS_HOSTNAME value="mikrotik-router"
add list=tailscale-router key=TS_TAGS value="tag:mikrotik"
add list=tailscale-router key=TS_PORT value="41642"
add list=tailscale-router key=TS_ADVERTISE_ROUTES value=""

# Bind the env list to the container we just created.
/container set [find where name~"tailscale-router"] envlist=tailscale-router

# Image extraction happens async on add — watch progress with:
#   /container/print detail where name~"tailscale-router"
# Wait until status=stopped, then:
#   /container/start [find where name~"tailscale-router"]
#   /log/print without-paging where message~"tailscale-router"
#
# Verify webclient is reachable from a tailnet peer once it's joined (after
# adding an ACL grant for tcp:5252 → tag:mikrotik):
#   curl -sI http://<this-node-tailnet-ip>:5252/ | head -1
