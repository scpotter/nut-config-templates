#!/bin/bash
set -euo pipefail

# nut-config-templates — generate script (tier 4 of the four-tier secrets
# model). Renders /etc/nut/* from the templates in this repo plus an
# Infisical export, then restarts NUT. Nothing rendered is written back into
# this checkout; the real config lives only under /etc/nut and is
# regenerated on every run.
#
# Invoked by dahome_private_config/estate/hosts/stack-launch.sh, which pulls
# this repo fresh and writes ./host_config.env (the bare contract in
# example.env) before exec'ing this. A forker who isn't that operator writes
# ./host_config.env by hand from example.env — this script neither knows nor
# cares which. Must run as root (writes /etc/nut, restarts services).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bare contract (example.env): the Infisical folder names + device IPs
# (private config, not secret) and the Infisical coordinates. `set -a` so a
# sourced var without its own `export` still reaches envsubst below.
set -a
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/host_config.env"
set +a

# Bootstrap credential — this deployment's Infisical identity. The var names
# are the SCREAMING_SNAKE transform of the identity name
# (launch-NutRack -> LAUNCH_NUT_RACK_*). Never in git; lives only on this
# host, regenerated on rebuild. A forker with a different identity edits
# these two names and the matching note in example.env.
# shellcheck source=/dev/null
source ~/.secrets/infisical.env

export INFISICAL_TOKEN
INFISICAL_TOKEN=$(infisical login \
  --method=universal-auth \
  --client-id="${LAUNCH_NUT_RACK_CLIENT_ID}" \
  --client-secret="${LAUNCH_NUT_RACK_CLIENT_SECRET}" \
  --domain="${INFISICAL_API_URL}" \
  --silent --plain)

# Every folder exports the same bare key names (TOKEN_NAME/TOKEN_SECRET for
# the two upsd accounts, COMMUNITY for the two SNMP devices), so each export
# is captured into its own variable and renamed immediately — otherwise the
# next eval clobbers the last. Capture-then-eval (not eval straight off the
# command substitution) so a failed export trips `set -e` rather than
# rendering config with an empty secret.
_pull() {
  infisical export --domain="${INFISICAL_API_URL}" \
    --projectId="${CORE_INFRA_PROJECT_ID}" --env=prod \
    --path="$1" --format=dotenv-export
}

MON_EXPORT=$(_pull "/${SERVER}/monitor/");      eval "$MON_EXPORT"
RENDER_MON_USER="${TOKEN_NAME}"; RENDER_MON_PASS="${TOKEN_SECRET}"

PAD_EXPORT=$(_pull "/${SERVER}/padmin/");       eval "$PAD_EXPORT"
RENDER_PAD_USER="${TOKEN_NAME}"; RENDER_PAD_PASS="${TOKEN_SECRET}"

UPS_EXPORT=$(_pull "/apc_snmp/${UPS_DEVICE}/"); eval "$UPS_EXPORT"
RENDER_UPS_COMMUNITY="${COMMUNITY}"

PDU_EXPORT=$(_pull "/apc_snmp/${PDU_DEVICE}/"); eval "$PDU_EXPORT"
RENDER_PDU_COMMUNITY="${COMMUNITY}"

RENDER_UPS_IP="${UPS_IP}"
RENDER_PDU_IP="${PDU_IP}"

export RENDER_MON_USER RENDER_MON_PASS RENDER_PAD_USER RENDER_PAD_PASS \
       RENDER_UPS_COMMUNITY RENDER_PDU_COMMUNITY RENDER_UPS_IP RENDER_PDU_IP

# --- prerequisites -------------------------------------------------------
# gettext-base gives us envsubst; nut-snmp is the snmp-ups driver binary
# (the `nut` metapackage does NOT pull it on Debian). Missing either is a
# hard stop for the render/restart below.
_missing=()
command -v envsubst >/dev/null            || _missing+=(gettext-base)
[ -x /lib/nut/snmp-ups ] || [ -x /usr/lib/nut/snmp-ups ] || _missing+=(nut-snmp)
if [ "${#_missing[@]}" -gt 0 ]; then
  apt-get update -qq && apt-get install -y -qq "${_missing[@]}"
fi

# --- render /etc/nut ---------------------------------------------------------

install -d -m 0755 /etc/nut
_grp=root; getent group nut >/dev/null && _grp=nut

render() {  # render <template> <dest> <mode> '<restricted var list>'
  # $4 is a literal envsubst allow-list ("${RENDER_X} ${RENDER_Y}") — the
  # single quotes at the call sites are deliberate, envsubst wants the token
  # strings, not their values.
  envsubst "$4" < "${SCRIPT_DIR}/templates/$1" > "$2"
  chown "root:${_grp}" "$2"
  chmod "$3" "$2"
}

# shellcheck disable=SC2016  # envsubst allow-lists — literal ${...} on purpose
render ups.conf.tmpl    /etc/nut/ups.conf    0640 '${RENDER_UPS_IP} ${RENDER_PDU_IP} ${RENDER_UPS_COMMUNITY} ${RENDER_PDU_COMMUNITY}'
render upsd.conf.tmpl    /etc/nut/upsd.conf   0640 ''
# shellcheck disable=SC2016
render upsd.users.tmpl   /etc/nut/upsd.users  0640 '${RENDER_MON_USER} ${RENDER_MON_PASS} ${RENDER_PAD_USER} ${RENDER_PAD_PASS}'
# shellcheck disable=SC2016
render upsmon.conf.tmpl  /etc/nut/upsmon.conf 0640 '${RENDER_MON_USER} ${RENDER_MON_PASS}'
# shellcheck disable=SC2016
render loadshed.sh.tmpl  /etc/nut/loadshed.sh 0700 '${RENDER_PDU_IP} ${RENDER_PDU_COMMUNITY}'

install -m 0755 "${SCRIPT_DIR}/notify.sh" /etc/nut/notify.sh

# nut.conf never varies by deployment — written directly so this script is
# the single writer of everything under /etc/nut.
printf 'MODE=netserver\n' > /etc/nut/nut.conf
chmod 0644 /etc/nut/nut.conf

# --- restart ---------------------------------------------------------------
# nut-driver-enumerator (a Type=oneshot) regenerates the per-device
# nut-driver@<name> instances from the fresh ups.conf and wires them into
# nut-driver.target. Then: clear any auto-restart backoff from a prior bad
# run, reload, and bounce drivers + server + monitor by explicit name.
systemctl restart nut-driver-enumerator.service
systemctl reset-failed 'nut-driver@*.service' 2>/dev/null || true
systemctl daemon-reload
systemctl restart nut-driver.target nut-server.service nut-monitor.service

_bad=""
for u in nut-server.service nut-monitor.service; do
  systemctl is-active --quiet "$u" || _bad="$_bad $u"
done

# Drivers report readiness to upsd, not just to systemd, and the first SNMP
# poll of an APC card can take 10-15s — retry before declaring failure.
_wait_driver() {  # _wait_driver <upsname>
  local tries=15
  while [ "$tries" -gt 0 ]; do
    upsc "$1" device.model >/dev/null 2>&1 && return 0
    tries=$((tries - 1))
    sleep 2
  done
  return 1
}
_wait_driver rack_UPS || _bad="$_bad rack_UPS-driver"
_wait_driver rack_PDU || _bad="$_bad rack_PDU-driver"

if [ -z "$_bad" ]; then
  echo "nut-config-templates: /etc/nut rendered, NUT up (both drivers serving upsd)"
else
  echo "nut-config-templates: not healthy —$_bad. Check: systemctl status 'nut-driver@*' nut-server nut-monitor" >&2
  exit 1
fi
