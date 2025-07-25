#!/bin/sh

# Alle Regeln löschen, alle Chains auf ACCEPT setzen (clean slate)
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Eingehenden Traffic erlauben, nur aus 192.168.170.0/24 (z.B. VPN-Subnetz)
iptables -A INPUT -s 192.168.170.0/24 -j ACCEPT

# ICMP Echo Request (Ping) für INPUT erlauben aus 192.168.170.0/24
iptables -A INPUT -p icmp --icmp-type echo-request -s 192.168.170.0/24 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -s 192.168.170.0/24 -j ACCEPT

# FORWARD erlauben: von 192.168.170.0/24 und 192.168.10.0/24 über eth1 nach wg0
iptables -A FORWARD -s 192.168.170.0/24 -i eth1 -o wg0 -j ACCEPT
iptables -A FORWARD -s 192.168.10.0/24 -i eth1 -o wg0 -j ACCEPT

# ICMP im FORWARD erlauben für Ping (Echo Request + Reply) aus 192.168.170.0/24
iptables -A FORWARD -s 192.168.170.0/24 -p icmp --icmp-type 8 -j ACCEPT
iptables -A FORWARD -d 192.168.170.0/24 -p icmp --icmp-type 0 -j ACCEPT

# NAT Masquerade auf wg0 Interface (ausgehend)
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
