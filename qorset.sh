#!/bin/sh
# usage: qorset (start|stop)
# 
# You need iproute2, kernel support for htb and sfq queueing disciplines, imq,
# kernel and iptables support for connmark, dscp, tos, ipp2p, multiport

#### User Configuration

# The interface to apply QoS to.
QOS_IF=eth0

# All bandwidth numbers are kilobit/second (1024 bits/s). You want to measure the
# real-world download and upload bandwidth, and set these values to something
# slightly lower.  The reserve is the amount of bandwidth you want to be
# instantly available for expedited forwarding, e.g. VOIP calls. 80 kbit in
# each direction is enough for one G.711 call.

## Download
DL=1250
DL_RESERVE=80

## Upload
UL=800
UL_RESERVE=80

# Destination ports (tcp and udp) for each class. Syntax is that of iptables
# -m multiport --dports
EF_DPORTS=
INT_DPORTS=
BULK_DPORTS=
DREGS_DPORTS=

# Source ports (tcp and udp) for each class. Syntax is that of iptables
# -m multiport --sports
EF_SPORTS=
INT_SPORTS=
BULK_SPORTS=
DREGS_SPORTS=

# If you need more complicated matches, feel free to add iptables rules in the
# filter section below.

#### End user configuration

### reset
tc qdisc del dev $QOS_IF root &>/dev/null
tc qdisc del dev imq0    root &>/dev/null
iptables -t mangle  -F qorset &>/dev/null

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
# filter on fw mark
for i in 11 12 21 22 23; do
    tc filter add dev $QOS_IF protocol ip parent 1:0 handle $i fw flowid 1:$i
    tc filter add dev imq0    protocol ip parent 1:0 handle $i fw flowid 1:$i
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
ipt="iptables -t mangle"
$ipt -N qorset &>/dev/null

# restore connection marks
ipta="$ipt -A qorset"
$ipta -j CONNMARK --restore-mark

# the order in which we do this matters
# bulk: mark 22
$ipta -m tos --tos Maximize-Throughput -j MARK --set-mark 22
$ipta -m tos --tos Minimize-Cost       -j MARK --set-mark 22
ports "$BULK_SPORTS" "$BULK_DPORTS" 22

# normal: mark 21 or don't mark at all
$ipta -m dscp --dscp BE -j MARK --set-mark 21
$ipta -m tos --tos Maximize-Reliability -j MARK --set-mark 21

# interactive: mark 12
$ipta -m tos --tos Minimize-Delay -j MARK --set-mark 12
for i in 4 5 6 7; do
    $ipta  -m tos --dscp-class CS$i -j MARK --set-mark 12
done
$ipta -p tcp -m length --length :128 --tcp-flags SYN,RST,ACK ACK -j MARK --set-mark 12
$ipta -p icmp -j MARK --set-mark 12
$ipta -p ipv6-icmp -j MARK --set-mark 12
if [ -n "$BULK_DPORTS" ]; then
    for proto in tcp udp; do
        $ipta -p $proto -m multiport --dports $BULK_DPORTS
    done
fi
ports "$INT_SPORTS" "$INT_DPORTS" 12

# expedited: mark 11
$ipta -m dscp --dscp-class EF -j MARK --set-mark 11
ports "$EF_SPORTS" "$EF_DPORTS" 11

# dregs: mark 23
$ipta -m ipp2p --ipp2p -j MARK --set-mark 23
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
# - maybe do tos bits with tc filter, for the mask ability?
# - test it
# - use a config file
# - release stuff

# vim:nowrap
