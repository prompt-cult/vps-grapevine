# nftables firewall kit (22 + 80/443 only)

`nftables.conf` defines one table, `inet vps_grapevine_filter`:

- **input** — policy drop; loopback, icmp/ipv6-icmp, established/related,
  tcp 22, 80, 443. Everything else dropped (logged at 5/s for debugging).
- **forward** — policy drop; established/related, anything already DNAT'd
  (`ct status dnat` — that is how Docker published ports reach containers),
  and egress/inter-container traffic on `docker*` interfaces.

## Docker coexistence (read before applying)

Docker installs its own base chains (DOCKER / DOCKER-USER tables via the
iptables or nft backend). Base chains at the same hook are all evaluated,
so this table does NOT replace Docker's — and this file deliberately does
**not** `flush ruleset`, which would rip Docker's rules out live and cut
every published port (traefik on 80/443 included) until the docker daemon
restarts.

Forward policy is drop, not accept: without `ct status dnat accept`,
published ports break (their packets are DNAT'd by Docker and then cross
FORWARD from the external NIC to the bridge). With it, only Docker-DNAT'd
traffic plus `docker*`-interface egress flows — there is no open forward.

## Apply (Ubuntu 24.04 / 26.04)

```bash
apt-get install -y nftables

# dry-run syntax check first (does not touch the live ruleset):
nft -c -f /root/vps-grapevine/server/nftables/nftables.conf

# keep a rollback copy, then apply:
cp /etc/nftables.conf /etc/nftables.conf.bak 2>/dev/null || true
install -m 755 /root/vps-grapevine/server/nftables/nftables.conf /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables.service
```

`systemctl enable nftables.service` makes it persist across reboots (Ubuntu
24.04 ships nftables.service reading `/etc/nftables.conf`). Do NOT also
enable netfilter-persistent with a conflicting iptables ruleset — pick one
owner of `/etc/nftables.conf`.

## Sanity checks

```bash
nft list table inet vps_grapevine_filter      # our table is loaded
nft list ruleset | grep -c 'DOCKER'           # docker chains still present
ss -tlnp                                      # what actually listens
curl -sI http://localhost/                    # 80/443 reachable via host
ssh -o ConnectTimeout=5 <box> true            # from the laptop: 22 still open
```

Check the drop counters are counting (not flooding):

```bash
nft list chain inet vps_grapevine_filter input | grep counter
journalctl -k | grep nft-drop | tail -5
```

## Rollback

From an ssh session that is still open (keep one open while testing —
applying input policy drop does not kill established connections):

```bash
# revert to the previous file and reload:
nft -f /etc/nftables.conf.bak
# or surgically drop only our table, leaving Docker untouched:
nft delete table inet vps_grapevine_filter
# nuclear option (clears Docker's rules too — restart docker afterwards):
nft flush ruleset
```

Worst case (locked out): the provider VPS console (e.g. Hostinger panel →
VPS → console) is the only way back in; that is why you test `nft -c` and
keep an ssh session open before `nft -f`.
