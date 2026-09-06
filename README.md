# nut-config-templates

Config templates and a generate script for a native [NUT](https://networkupstools.org/)
server monitoring an **APC Smart-UPS** (via its Network Management Card) and
an **APC AP7920 PDU** over SNMP.

It follows a "render from a template plus a secret store, never persist the
rendered secret" pattern: the real `/etc/nut/*` config is regenerated on
every launch and exists only on the host.

## Layout

| Path | Role |
|---|---|
| `launch.sh` | Sources `./host_config.env`, logs into Infisical, renders `templates/*` into `/etc/nut/`, restarts NUT. Run as root. |
| `templates/ups.conf.tmpl` | `snmp-ups` driver stanzas for both devices — IPs and communities substituted at render time. |
| `templates/upsd.conf.tmpl` | `LISTEN` directives. |
| `templates/upsd.users.tmpl` | Two accounts: `monitor` (`upsmon master` only) and `padmin` (interactive admin). Passwords substituted. |
| `templates/upsmon.conf.tmpl` | Local `upsmon` — `MONITOR` lines, `SHUTDOWNCMD`, `NOTIFYCMD`. Monitor password substituted. |
| `templates/loadshed.sh.tmpl` | Automated PDU load-shedding, invoked by `notify.sh` on power events. PDU IP + write community substituted. |
| `notify.sh` | NUT `NOTIFYCMD` handler — copied verbatim (no secrets). Logs events, dispatches to `loadshed.sh`. |
| `example.env` | The contract `host_config.env` must satisfy. |

## Setup

1. `git clone` this repo to its production path (this operator uses
   `/opt/nut-config-templates`).
2. Copy `example.env` to `host_config.env` and fill in real values — the
   Infisical folder names, the two device IPs, and your Infisical instance
   URL + `core-infra` project ID.
3. Put the Infisical machine identity's bootstrap credential in
   `~/.secrets/infisical.env` (see `example.env` for the variable names).
4. In Infisical, under the `core-infra` project's `prod` environment:
   - `/<SERVER>/monitor/` and `/<SERVER>/padmin/` — `TOKEN_NAME` +
     `TOKEN_SECRET` each.
   - `/apc_snmp/<UPS_DEVICE>/` and `/apc_snmp/<PDU_DEVICE>/` — a bare
     `COMMUNITY` each (write-capable).
5. `sudo ./launch.sh`.

This operator invokes it through a shared wrapper
(`dahome_private_config/estate/hosts/stack-launch.sh nut`) that pulls both
repos fresh and generates `host_config.env` from a private config store
before running `launch.sh`; nothing here depends on that.
