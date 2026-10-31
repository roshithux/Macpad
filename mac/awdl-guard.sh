#!/bin/sh
# Phone Trackpad Wi-Fi lag fix. Runs as root through launchd.
#
# AWDL (the radio behind AirDrop, AirPlay Receiver and Universal Control) makes the
# Mac's Wi-Fi hop channels now and then, which stalls trackpad input for ~100 ms.
# Keep AWDL off only while a phone is connected to the trackpad app on port 9876,
# and turn it back on once the phone disconnects. If AWDL was already off when the
# phone connected, it is left alone.

PORT=9876
FLAG=/var/run/phonetrackpad-awdl-off   # set while AWDL is off because of us

phone_connected() {
    netstat -an -p tcp | awk -v p=".$PORT" '
        $6 == "ESTABLISHED" && substr($4, length($4) - length(p) + 1) == p { found = 1 }
        END { exit !found }'
}

awdl_up() {
    ifconfig awdl0 2>/dev/null | head -1 | grep -q '<UP'
}

while true; do
    if phone_connected; then
        if awdl_up; then
            ifconfig awdl0 down && touch "$FLAG"
        fi
    elif [ -f "$FLAG" ]; then
        ifconfig awdl0 up
        rm -f "$FLAG"
    fi
    sleep 2
done
