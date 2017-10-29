# WiFi Hijack

Description:

        Scans for wireless access points, then lets you choose one to impersonate. Requires two interfaces:
        one to maintain an internet connection to pass through to the client, and one to host the evil twin.
        The first interface can connect to the same access point you intend to spoof with the second interface.
        Make sure the second interface is offline before running this script (ifconfig wlan0 down).
        If the evil twin signal is stronger than the target access point, it will pick up clients automatically.
        If you want to target a particular client, use the --deauth flag to kick it off the target access point.


Required Package Dependencies:

- macchanger
- hostapd
- dnsmasq


Optional Tools:

- wireshark
- mitmproxy
- sslstrip


Usage: ./hijack.sh [options]


Options:

- -w, --wan <interface>               Interface name for the passthrough internet connection (default eth0)
- -l, --lan <interface>               Interface name for the evil twin access point (default wlan0)
- -b, --bridge <interface>            Interfacename for the bridge interface between wan and lan (default br0)
- -s, --ssid <ssid>                   SSID of the target access point (will prompt if not specified)
- -p, --passphrase <passphrase>       Passphrase for the target access point (will prompt if needed)
- -m, --mac <mac>                     MAC address to assign to the evil twin (random if not specified)
- -d, --deauth <mac>                  MAC address of a wireless client to deauthenticate
- -r, --rescan <number>               0=Don't scan (use previous results), 1=Scan once (default), 2=Scan twice, 3=Scan thrice
- --wireshark                         Launch wireshark and start capturing on the bridge interface
- --mitmproxy                         Launch mitmproxy to monitor and inject HTTP traffic
- --sslstrip                          Launch ssltrip to downgrade HTTPS to HTTP (when possible) and log POST requests
- --cleanup                           Remove configuration files and shut down services (to recover after an interruption)
