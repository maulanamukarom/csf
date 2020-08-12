#!/bin/bash

export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# table nat
iptables -t nat -N DOCKER
iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER

for network_id in $(docker network ls | grep -Ev 'host|none|NETWORK' | awk '{print $1}'); do
    bridge_name=$(docker network inspect $network_id -f '{{(index .Options "com.docker.network.bridge.name")}}')
    if [[ -z "$bridge_name" ]]; then
        bridge_name="br-$network_id"
    fi
    subnet=$(docker network inspect $network_id -f '{{(index .IPAM.Config 0).Subnet}}')

    iptables -t nat -A POSTROUTING -s $subnet ! -o $bridge_name -j MASQUERADE
    iptables -t nat -A DOCKER -i $bridge_name -j RETURN
done

for container_id in $(docker ps -q); do
    for network_mode in $(docker inspect $container_id -f '{{range $bridge, $conf := .NetworkSettings.Networks}}{{$bridge}}{{end}}'); do
        ip_address=$(docker inspect $container_id -f "{{(index .NetworkSettings.Networks \"${network_mode}\").IPAddress}}")
        bridge_name=$(docker network inspect $network_mode -f '{{(index .Options "com.docker.network.bridge.name")}}')
        if [[ -z "$bridge_name" ]]; then
            bridge_name="br-$(docker network inspect ${network_mode} -f '{{.Id}}' | cut -c -12)"
        fi
        for port in $(docker inspect $container_id -f '{{range $port, $conf := .NetworkSettings.Ports}}{{$port}};{{end}}' | tr ';' "\n"); do
            protocol=$(echo $port | awk -F/ '{print $2}')
            container_port=$(echo $port | awk -F/ '{print $1}')
            host_port=$(docker inspect $container_id -f "{{(index (index .NetworkSettings.Ports \"${port}\") 0).HostPort}}" 2>/dev/null)
            if [[ ! -z "$host_port" ]]; then
                iptables -t nat -A POSTROUTING -s $ip_address/32 -d $ip_address/32 -p $protocol -m $protocol --dport $container_port -j MASQUERADE
                iptables -t nat -A DOCKER ! -i $bridge_name -p $protocol -m $protocol --dport $host_port -j DNAT --to-destination $ip_address:$container_port
            fi
        done
    done
done

# table filter
iptables -N DOCKER
iptables -N DOCKER-ISOLATION-STAGE-1
iptables -N DOCKER-ISOLATION-STAGE-2
iptables -N DOCKER-USER

iptables -A FORWARD -j DOCKER-USER
iptables -A FORWARD -j DOCKER-ISOLATION-STAGE-1

for network_id in $(docker network ls | grep -Ev 'host|none|NETWORK' | awk '{print $1}'); do
    bridge_name=$(docker network inspect $network_id -f '{{(index .Options "com.docker.network.bridge.name")}}')
    if [[ -z "$bridge_name" ]]; then
        bridge_name="br-$network_id"
    fi
    iptables -A FORWARD -o $bridge_name -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -o $bridge_name -j DOCKER
    iptables -A FORWARD -i $bridge_name ! -o $bridge_name -j ACCEPT
    iptables -A FORWARD -i $bridge_name -o $bridge_name -j ACCEPT
done

for container_id in $(docker ps -q); do
    for network_mode in $(docker inspect $container_id -f '{{range $bridge, $conf := .NetworkSettings.Networks}}{{$bridge}}{{end}}'); do
        ip_address=$(docker inspect $container_id -f "{{(index .NetworkSettings.Networks \"${network_mode}\").IPAddress}}")
        bridge_name=$(docker network inspect $network_mode -f '{{(index .Options "com.docker.network.bridge.name")}}')
        if [[ -z "$bridge_name" ]]; then
            bridge_name="br-$(docker network inspect ${network_mode} -f '{{.Id}}' | cut -c -12)"
        fi
        for port in $(docker inspect $container_id -f '{{range $port, $conf := .NetworkSettings.Ports}}{{$port}};{{end}}' | tr ';' "\n"); do
            protocol=$(echo $port | awk -F/ '{print $2}')
            container_port=$(echo $port | awk -F/ '{print $1}')
            host_port=$(docker inspect $container_id -f "{{(index (index .NetworkSettings.Ports \"${port}\") 0).HostPort}}" 2>/dev/null)
            if [[ ! -z "$host_port" ]]; then
                iptables -A DOCKER -d $ip_address/32 ! -i $bridge_name -o $bridge_name -p $protocol -m $protocol --dport $container_port -j ACCEPT
            fi
        done
    done
done

for network_id in $(docker network ls | grep -Ev 'host|none|NETWORK' | awk '{print $1}'); do
    bridge_name=$(docker network inspect $network_id -f '{{(index .Options "com.docker.network.bridge.name")}}')
    if [[ -z "$bridge_name" ]]; then
        bridge_name="br-$network_id"
    fi
    iptables -A DOCKER-ISOLATION-STAGE-1 -i $bridge_name ! -o $bridge_name -j DOCKER-ISOLATION-STAGE-2 
    iptables -A DOCKER-ISOLATION-STAGE-2 -o $bridge_name -j DROP
done

iptables -A DOCKER-ISOLATION-STAGE-1 -j RETURN
iptables -A DOCKER-ISOLATION-STAGE-2 -j RETURN
iptables -A DOCKER-USER -j RETURN
