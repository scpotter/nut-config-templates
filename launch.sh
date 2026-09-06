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

# --- render /etc/nut ---------------------------------------------------------
command -v envsubst >/dev/null || { apt-get update -qq && apt-get install -y -qq gettext-base; }

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
# nut-driver-enumerator regenerates the per-UPS nut-driver@<name> units from
# the fresh ups.conf; then bounce drivers, server, monitor.
systemctl restart nut-driver-enumerator.service 2>/dev/null || true
if systemctl cat nut.target >/dev/null 2>&1; then
  systemctl restart nut.target
else
  systemctl restart 'nut-driver@*.service' nut-server.service nut-monitor.service 2>/dev/null \
    || systemctl restart nut-server.service nut-monitor.service
fi

if systemctl is-active --quiet nut-server.service && systemctl is-active --quiet nut-monitor.service; then
  echo "nut-config-templates: /etc/nut rendered, NUT restarted"
else
  echo "nut-config-templates: a NUT unit is not active — systemctl status nut-server nut-monitor" >&2
  exit 1
fi
