# Boot order for host services that bind docker-bridge interfaces

## The bug class

A host service that binds a **docker-bridge gateway address** (for example a
database that listens on a bridge IP so containers can reach it via the
bridge gateway) races `docker.service` at boot:

- systemd starts the service and `docker.service` in parallel (no ordering
  between them by default);
- the bridge interfaces (the default bridge and every user-defined docker
  network's bridge) only exist **after** `docker.service` has started and
  materialised the networks from its store;
- if the service starts first, its bind on the bridge address fails, and
  every container depending on it crash-loops ("connection refused") until
  a human repairs it.

Symptoms seen in the wild: a full IdP outage after an ordinary reboot, with
the dependent container stack healthy-except-the-database and the database
unit green on `localhost` only.

## The fix

Order the service after docker with a systemd drop-in
(`postgresql@16-main.service.d/boot-order.conf` in this repo, for the
Debian/Ubuntu postgres packaging):

    [Unit]
    Wants=docker.service
    After=docker.service

`Wants=` (not `Requires=`) is deliberate: the database must still boot if
docker is disabled or removed — it just must not race it.

Install:

    install -d /etc/systemd/system/<unit>.service.d
    install -m 644 postgresql@16-main.service.d/boot-order.conf \
      /etc/systemd/system/<unit>.service.d/boot-order.conf
    systemctl daemon-reload
    systemctl restart <unit>

Verify: the service's listening sockets include every configured address
(`ss -tlnp`), dependents are healthy, and the application answers end to
end. A full boot proof needs a reboot — operator's word required.

## Interfaces are explicit, always

- **No service listens on an internet-facing interface. Ever.** Services
  bind an explicit address list (`localhost` + the specific bridge
  addresses they serve), never `*`.
- Any config that carries an interface/address list ships as a **template**
  named `<basename>.x.<ext>.j2` with `{{ foo_bar_interfaces }}`-style
  placeholders (this repo: `templates/postgresql.x.conf.j2`). The rendered
  per-box values are estate-private and live only in the sealed
  `server/SETUP-NOTES.md`.
- A bridge address may only be bound if that docker network's subnet is
  **pinned** in its compose/network definition — never auto-assigned — so
  the address is stable and known at template-render time.

## Related lesson (same class, different edge)

The edge containers themselves must be `restart: unless-stopped` (or
equivalent) so a daemon restart or box reboot brings the whole stack back
without hand-holding. This is already estate law; the drop-in closes the
remaining gap: the host service that the containers depend on.

## Status on vps2 (2026-10-09) — applied; NOT closed until reboot proof

- Drop-in installed + in-session verify battery green (4 binds, pg_isready,
  zitadel api healthy, discovery 200). That is necessary, NOT sufficient.
- CLOSING REQUIRES: (1) a reboot by the operator (agents never reboot) with
  the verify battery re-run after boot; (2) external verification — public
  endpoints and the browser path via the operator's Mac agent
  (listed user lands; unlisted user 403s). In-session restarts prove nothing
  about boot durability; do not claim this fix closed without both.
