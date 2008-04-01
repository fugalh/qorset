#!/bin/sh
# qorset QoS script
# Copyright (C) 2008 Hans Fugal <hans@fugal.net>
# GPL2

# usage: qorset ([start]|stop)
# 
# You need iproute2, kernel support for htb and sfq queueing disciplines, imq,
# kernel and iptables support for connmark, dscp, tos, l7-filter, multiport
#
# qorset is a Quality of Service (QoS) script. It divides your network traffic
# up into different classes and gives preference to some classes and
# antipreference to others. It does not merely restrict bandwidth, so when the
# link is otherwise idle a p2p application (for example) will be able to
# utilize the entire link.

# The classes are:
#  - expedited forwarding (EF). This class is for hard-realtime traffic like
#    VOIP
#  - interactive (INT). This class is for things like ssh that are 
#    soft-realtime
#  - best effort (default)
#  - bulk. Traffic that should get there but at a lower priority, e.g. SMTP
#  - dregs. This class gets whatever is left over. If any of the above classes
#    are utilizing all of the link, this class will get almost nothing. Good
#    for p2p, e.g. bittorrent
#
# For best results, ensure that your software sets an appropriate TOS field.
# Alternatively, you can specify classification by ports below.

# The interface to apply QoS to. Required
QOS_IF=eth0

# All bandwidth numbers are kilobit/second (1024 bits/s). You want to measure
# the real-world download and upload bandwidth, and set these values to
# something slightly lower.  The reserve is the amount of bandwidth you want to
# be instantly available for expedited forwarding, e.g. VOIP calls. 80 kbit in
# each direction is enough for one G.711 call.

## Download. Required
DL=1299
DL_RESERVE=80

## Upload
UL=820
UL_RESERVE=80

# Destination ports (tcp and udp) for each class. Syntax is that of iptables
# -m multiport --dports
EF_DPORTS=5060,4569,53
INT_DPORTS=22,23
BULK_DPORTS=25
DREGS_DPORTS=

# Source ports (tcp and udp) for each class. Syntax is that of iptables
# -m multiport --sports
EF_SPORTS=
INT_SPORTS=
BULK_SPORTS=
DREGS_SPORTS=

# If you need more complicated matches, feel free to add iptables rules in the
# filter section below

# Source configuration file (it's probably best to put changes here)
. /etc/qorset.conf

### end configuration

### reset
ipt="iptables -t mangle"
(
    tc qdisc del dev $QOS_IF root
    tc qdisc del dev imq0    root
    $ipt -N qorset
    $ipt -D PREROUTING  -i $QOS_IF -j qorset
    $ipt -D POSTROUTING -o $QOS_IF -j qorset
    $ipt -D PREROUTING  -i $QOS_IF -j IMQ --todev 0
    $ipt -F qorset
    $ipt -X qorset
) 2>/dev/null


[ "$1" = "stop" ] && exit

### qdiscs and classes
# 1:0 root htb qdisc
#   1:1 root class (to allow for sharing)
#     1:10 priority class
#       1:11 expedited forwarding
#       1:12 interactive
#     1:20 best effort class
#       1:21 normal/reliable
#       1:22 bulk
#       1:23 dregs

## egress
class="tc class add dev $QOS_IF"
qdisc="tc qdisc add dev $QOS_IF"
UL_BE=$(($UL - $UL_RESERVE))
$qdisc root handle 1:0 htb default 21
  $class parent 1:0  classid 1:1  htb rate ${UL}kbit
    $class parent 1:1  classid 1:10 htb rate ${UL_RESERVE}kbit ceil ${UL}kbit prio 1
      $class parent 1:10 classid 1:11 htb rate $(($UL_RESERVE/2))kbit ceil ${UL}kbit prio 1
        $qdisc parent 1:11 sfq
      $class parent 1:10 classid 1:12 htb rate $(($UL_RESERVE/2))kbit ceil ${UL}kbit prio 2
        $qdisc parent 1:12 sfq
    $class parent 1:1  classid 1:20 htb rate ${UL_BE}kbit ceil ${UL}kbit prio 2
      $class parent 1:20 classid 1:21 htb rate $(($UL_BE*66/100))kbit ceil ${UL}kbit prio 1
        $qdisc parent 1:21 sfq
      $class parent 1:20 classid 1:22 htb rate $(($UL_BE*32/100))kbit ceil ${UL}kbit prio 2
        $qdisc parent 1:22 sfq
      $class parent 1:20 classid 1:23 htb rate $(($UL_BE*1/100))kbit ceil ${UL}kbit prio 3
        $qdisc parent 1:23 sfq

## ingress
ip link set imq0 up
class="tc class add dev imq0"
qdisc="tc qdisc add dev imq0"
DL_BE=$(($DL - $DL_RESERVE))
$qdisc root handle 1:0 htb default 21
  $class parent 1:0  classid 1:1  htb rate ${DL}kbit
    $class parent 1:1  classid 1:10 htb rate ${DL_RESERVE}kbit ceil ${DL}kbit prio 1
      $class parent 1:10 classid 1:11 htb rate $(($DL_RESERVE/2))kbit ceil ${DL}kbit prio 1
        $qdisc parent 1:11 sfq
      $class parent 1:10 classid 1:12 htb rate $(($DL_RESERVE/2))kbit ceil ${DL}kbit prio 2
        $qdisc parent 1:12 sfq
    $class parent 1:1  classid 1:20 htb rate ${DL_BE}kbit ceil ${DL}kbit prio 2
      $class parent 1:20 classid 1:21 htb rate $(($DL_BE*66/100))kbit ceil ${DL}kbit prio 1
        $qdisc parent 1:21 sfq
      $class parent 1:20 classid 1:22 htb rate $(($DL_BE*32/100))kbit ceil ${DL}kbit prio 2
        $qdisc parent 1:22 sfq
      # dregs on ingress is intentionally ceil DL_BE unlike on egress, since we
      # have less control and we really want that reserve to be available
      $class parent 1:20 classid 1:23 htb rate $(($DL_BE*1/100))kbit ceil ${DL_BE}kbit prio 3
        $qdisc parent 1:23 sfq

### filters
# filter on fw mark (see below)
for i in 11 12 21 22 23; do
    tc filter add dev $QOS_IF protocol ip prio 1 parent 1:0 handle $i fw flowid 1:$i
    tc filter add dev imq0    protocol ip prio 1 parent 1:0 handle $i fw flowid 1:$i
done

# filter on TOS field
tos() {
    tc filter add dev $1 parent 1:0 protocol ip prio 2 u32 \
        match ip tos $2 $3 \
        flowid 1:$4
}
for dev in $QOS_IF imq0; do
    tos $dev 0xb8 0xff 11 # expedited forwarding
    tos $dev 0x10 0x10 12 # minimum-delay
    tos $dev 0x80 0x80 12 # ip precedence >= 4
    tos $dev 0x04 0x04 21 # maximize-reliability
    tos $dev 0x08 0x08 22 # maximize-throughput
    tos $dev 0x02 0x02 23 # minimize-cost
done

## qos chain
# Mark based on ports: sports, dports, mark
ports() {
    if [ -n "$1" ]; then
        for proto in tcp udp; do
            $ipta -p $proto -m multiport --sports "$1" -j MARK --set-mark $3
        done
    fi
    if [ -n "$2" ]; then
        for proto in tcp udp; do
            $ipta -p $proto -m multiport --dports "$2" -j MARK --set-mark $3
        done
    fi
}

# Mark based on l7-filter: protocols, mark
l7() {
    for proto in $1; do
        $ipta -m layer7 --l7proto $proto -j MARK --set-mark $2
    done
}

$ipt -N qorset &>/dev/null

ipta="$ipt -A qorset"

# restore connection marks
$ipta -j CONNMARK --restore-mark

# the order in which we do all this matters

# bulk: mark 22
ports "$BULK_SPORTS" "$BULK_DPORTS" 22
l7 smtp 22

# normal best-effort: mark 21 or don't mark at all

# interactive: mark 12
$ipta -p tcp -m length --length :128 --tcp-flags SYN,RST,ACK ACK -j MARK --set-mark 12
$ipta -p icmp -j MARK --set-mark 12
$ipta -p ipv6-icmp -j MARK --set-mark 12
l7 "ssh sip telnet" 12
ports "$INT_SPORTS" "$INT_DPORTS" 12

# expedited: mark 11
ports "$EF_SPORTS" "$EF_DPORTS" 11
l7 "ntp dns" 11

# dregs: mark 23
l7 "bittorrent fasttrack gnutella" 23
ports "$DREGS_SPORTS" "$DREGS_DPORTS" 23

# save connection marks
$ipta -j CONNMARK --save-mark

## end qos chain

# call qos chain to set marks
$ipt -A PREROUTING  -i $QOS_IF -j qorset
$ipt -A POSTROUTING -o $QOS_IF -j qorset

# ingress through imq0
$ipt -A PREROUTING  -i $QOS_IF -j IMQ --todev 0

# TODO
# - detect VOIP
# - test it
# - release stuff
# - l7 user configuration?

# vim:nowrap
