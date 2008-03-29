#!/bin/sh
# usage: qorset ([start]|stop)
# 
# You need iproute2, kernel support for htb and sfq queueing disciplines, imq,
# kernel and iptables support for connmark, dscp, tos, ipp2p, multiport
#
# Copyright (C) 2008 Hans Fugal <hans@fugal.net>
# GPL2

source /etc/qorset.conf

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

ipt="iptables -t mangle"
$ipt -N qorset &>/dev/null

ipta="$ipt -A qorset"

# restore connection marks
$ipta -j CONNMARK --restore-mark

# the order in which we do all this matters

# bulk: mark 22
ports "$BULK_SPORTS" "$BULK_DPORTS" 22

# normal: mark 21 or don't mark at all

# interactive: mark 12
$ipta -p tcp -m length --length :128 --tcp-flags SYN,RST,ACK ACK -j MARK --set-mark 12
$ipta -p icmp -j MARK --set-mark 12
$ipta -p ipv6-icmp -j MARK --set-mark 12
ports "$INT_SPORTS" "$INT_DPORTS" 12

# expedited: mark 11
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
# - test it
# - release stuff

# vim:nowrap
