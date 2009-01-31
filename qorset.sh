#!/bin/sh
# qorset QoS script
# Copyright (C) 2009 Hans Fugal <hans@fugal.net>
# GPL2

# usage: qorset ([start]|stop)
#   
# qorset is a Quality of Service (QoS) script. It divides your network traffic
# up into different classes and gives preference to some classes and
# antipreference to others. It does not merely restrict bandwidth, so when the
# link is otherwise idle a p2p application (for example) will be able to
# utilize the entire link.
#
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
#
# This script is written with openwrt in mind, but could easily be adapted to
# generic linux.
# 
# You need iproute2, kernel support for htb, sfq, and red queueing disciplines,
# imq, kernel and iptables support for connmark, dscp, tos, l7-filter, and
# multiport.
# 
# For openwrt, this means install the following packages:
#   tc
#   iptables-mod-conntrack
#   iptables-mod-extra
#   iptables-mod-filter
#   iptables-mod-imq
#   iptables-mod-ipopt
#
# and add the following modules to /etc/modules:
#   imq
#   sch_htb                                                                                                                                                                            
#   sch_sfq                                                                                                                                                                            
#   sch_red                                                                                                                                                                            
#   cls_u32                                                                                                                                                                            
#   cls_fw                                                                                                                                                                             
#   ipt_layer7                                                                                                                                                                         
#   ipt_IMQ                                                                                                                                                                            
#   ipt_CONNMARK                                                                                                                                                                       

# The interface to apply QoS to. Required
#QOS_IF=$(nvram get wan_ifname) # OpenWRT
QOS_IF=eth0

# All bandwidth numbers are kilobit/second (1024 bits/s). You want to measure
# the real-world download and upload bandwidth, and set these values to
# something slightly lower.  The reserve is the amount of bandwidth you want to
# be instantly available for expedited forwarding, e.g. VOIP calls. 80 kbit in
# each direction is enough for one G.711 call.

## Download. Required
DL=1200
DL_RESERVE=80

## Upload. Required
UL=820
UL_RESERVE=80

# Ports (tcp and udp) for each class. Syntax is that of 
# iptables -m multiport --ports
EF_PORTS=5060,4569
# I don't include 22 (ssh) here, because OpenSSH (at least) does a good job of
# setting TOS bits, and if we match indiscriminantly on port 22 we catch scp
# too, which is bulk traffic.
INT_PORTS=23,53
BULK_PORTS=21,25
DREGS_PORTS=6881:6999

# If you need more complicated matches, feel free to add iptables rules in the
# filter section below

# Source configuration file (it's probably best to put changes here)
[ -r qorset.conf ] && . qorset.conf
[ -r /etc/qorset.conf ] && . /etc/qorset.conf

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

sfq() {
    $qdisc parent 1:$1 handle $1 sfq
}

## egress
class="tc class add dev $QOS_IF"
qdisc="tc qdisc add dev $QOS_IF"
UL_BE=$(($UL - $UL_RESERVE))
Q=1500
$qdisc root handle 1:0 htb default 21
  $class parent 1:0  classid 1:1  htb rate ${UL}kbit
    $class parent 1:1  classid 1:10 htb rate ${UL_RESERVE}kbit ceil ${UL}kbit prio 1
      $class parent 1:10 classid 1:11 htb rate $(($UL_RESERVE/2))kbit ceil ${UL}kbit prio 1 quantum $Q
        sfq 11
      $class parent 1:10 classid 1:12 htb rate $(($UL_RESERVE/2))kbit ceil ${UL}kbit prio 2 quantum $Q
        sfq 12
    $class parent 1:1  classid 1:20 htb rate ${UL_BE}kbit ceil ${UL}kbit prio 2
      $class parent 1:20 classid 1:21 htb rate $(($UL_BE*75/100))kbit ceil ${UL}kbit prio 1 quantum $Q
        sfq 21
      $class parent 1:20 classid 1:22 htb rate $(($UL_BE*24/100))kbit ceil ${UL}kbit prio 2 quantum $Q
        sfq 22
      $class parent 1:20 classid 1:23 htb rate $(($UL_BE*1/100))kbit ceil ${UL}kbit prio 3 quantum $Q
        sfq 23

## ingress
ip link set imq0 up
class="tc class add dev imq0"
qdisc="tc qdisc add dev imq0"

# Random Early Detection. Only parameter is parent's minor number.
red() {
    MTU=1500
    limit=$((40*$MTU))
    min=$((5*$MTU))
    max=$((20*$MTU))
    avpkt=$(($MTU*6/10))
    burst=16
    probability=0.015
    $qdisc parent 1:$1 handle $1 red limit $limit min $min max $max avpkt $avpkt burst $burst probability $probability
}

DL_BE=$(($DL - $DL_RESERVE))
$qdisc root handle 1:0 htb default 21
  $class parent 1:0  classid 1:1  htb rate ${DL}kbit
    $class parent 1:1  classid 1:10 htb rate ${DL_RESERVE}kbit ceil ${DL}kbit prio 1
      $class parent 1:10 classid 1:11 htb rate $(($DL_RESERVE/2))kbit ceil ${DL}kbit prio 1 quantum $Q
        sfq 11
      $class parent 1:10 classid 1:12 htb rate $(($DL_RESERVE/2))kbit ceil ${DL}kbit prio 2 quantum $Q
        sfq 12
    $class parent 1:1  classid 1:20 htb rate ${DL_BE}kbit ceil ${DL}kbit prio 2
      $class parent 1:20 classid 1:21 htb rate $(($DL_BE*75/100))kbit ceil ${DL}kbit prio 1 quantum $Q
        sfq 21
      $class parent 1:20 classid 1:22 htb rate $(($DL_BE*24/100))kbit ceil ${DL}kbit prio 2 quantum $Q
        sfq 22
      # dregs on ingress is intentionally ceil DL_BE unlike on egress, since we
      # have less control and we really want that reserve to be available
      $class parent 1:20 classid 1:23 htb rate $(($DL_BE*1/100))kbit ceil ${DL_BE}kbit prio 3 quantum $Q
        sfq 23

### filters
# filter on fw mark (see below)
for i in 11 12 21 22 23; do
    tc filter add dev $QOS_IF protocol ip prio 1 parent 1:0 handle $i fw flowid 1:$i
    tc filter add dev imq0    protocol ip prio 1 parent 1:0 handle $i fw flowid 1:$i
done

# filter on TOS field
tos() {
    tc filter add dev $1 parent 1:0 protocol ip prio 0 u32 \
        match ip tos $2 $3 \
        flowid 1:$4
}
for dev in $QOS_IF imq0; do
    tos $dev 0xb8 0xff 11 # expedited forwarding
    tos $dev 0x10 0x10 12 # minimum-delay
    tos $dev 0x80 0x80 12 # ip precedence >= 4
    tos $dev 0x04 0x40 21 # maximize-reliability
    tos $dev 0x08 0x08 22 # maximize-throughput
done

## qos chain
# Mark based on ports: ports, mark
ports() {
    if [ -n "$1" ]; then
    	for proto in tcp udp; do 
            $ipta -p $proto -m multiport --ports "$1" -j MARK --set-mark $2
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
ports "$BULK_PORTS" 22
l7 smtp 22

# normal best-effort: mark 21 or don't mark at all

# interactive: mark 12
$ipta -p icmp -j MARK --set-mark 12
$ipta -p ipv6-icmp -j MARK --set-mark 12
ports "$INT_PORTS" 12

# expedited: mark 11
ports "$EF_PORTS" 11
l7 "ntp" 11

# dregs: mark 23
l7 "bittorrent fasttrack gnutella" 23
ports "$DREGS_PORTS" 23

# save connection marks
$ipta -j CONNMARK --save-mark

# this has to happen after mark saving, or we end up marking bulk traffic as
# interactive due to the mark restoration (e.g. scp), when the true tos is
# stripped (e.g. comcast)
$ipta -p tcp -m length --length 0:128 --tcp-flags SYN,RST,ACK ACK -j MARK --set-mark 12

# now some empty rules for easy accounting
$ipta -m mark --mark 11
$ipta -m mark --mark 12
$ipta -m mark --mark 21
$ipta -m mark --mark 22
$ipta -m mark --mark 23

## end qos chain

# call qos chain to set marks
$ipt -A PREROUTING  -i $QOS_IF -j qorset
$ipt -A POSTROUTING -o $QOS_IF -j qorset

# ingress through imq0
$ipt -A PREROUTING  -i $QOS_IF -j IMQ --todev 0

# vim:nowrap
