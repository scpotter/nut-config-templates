#!/bin/bash
#
# NUT NOTIFYCMD handler. Copied verbatim to /etc/nut/notify.sh by
# ../launch.sh (no substitutions, no secrets). Carried forward unchanged
# from the previous deployment — logs every upsmon event to syslog and
# dispatches the power-relevant ones to loadshed.sh.

LOGTAG="nut-notify"
UPS="$1"
EVENT="$2"

logger -t "$LOGTAG" "Notify event: UPS=$UPS EVENT=$EVENT"

case $EVENT in
    ONBATT|LOWBATT|ONLINE|REPLBATT|COMMBAD|COMMOK)
        /etc/nut/loadshed.sh
        ;;
    FSD)
        logger -t "$LOGTAG" "Forced shutdown event received"
        ;;
    *)
        logger -t "$LOGTAG" "Unhandled event: $EVENT"
        ;;
esac
