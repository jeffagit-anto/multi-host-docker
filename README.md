# Multi-host Docker Networking using OpenVSwitch

This repository contains Haskell code for provisioning and configuring a bunch of machines to run docker over a virtual network overlaid over actual network, using [OpenVSwitch](https://github.com/openvswitch/ovs/) to route packets across bridges and GRE tunnels. The "theory" behind this configuration is beyond the scope of this README, and beyond my capabilities and knowledge, but the basic principle is quite simple:

* Use OpenSwitch to manage a *bridge* network interface,
* Plug docker into that bridge so that created containers use it,
* Create [GRE tunnel](http://lartc.org/howto/lartc.tunnel.gre.html)s between each managed hosts to route packets between containers.

# Documentation

## Building

This code relies on a fork of the excellent configuration management tool [propellor](http://propellor.branchable.com) which is linked to the main repository as a [git submodule]() To retrieve it:

```
$ git submodules init
$ git submodules update
```

This repository contains Haskell code. It uses [stack](http://docs.haskellstack.org) for building:

```
$ stack setup
$ stack build
```

This should give you an executable named `multi-host-docker-network` somewhere in your `.stack-work` directory.

## Running

The `multi-host-docker-network` executable can be used to do one the following *actions*:

* Provision number of hosts on [DigitalOcean](http://digitalocean.com) using [hdo](https://github.com/capital-match/hdo), a Haskell client for DO,
* Build locally using [docker](http://docker.io) a Propellor-based configuration program to setup those hosts (or any host to which you have SSH access to),
* Run built Propellor-based configuration program on remote hosts,
* Build locally an [OpenVSwitch](https://github.com/openvswitch/ovs/) version compatible with remote hosts (assume Ubuntu...).

Here is an example workflow. First, let's build the openvswitch Debian packages that we will need to configure our remote hosts:

```
$ multi-host-docker-network buildopenvswitch
Sending build context to Docker daemon  2.56 kB
Step 1 : FROM ubuntu:trusty
 ---> ffbf13a52255
Step 2 : RUN apt-get update && apt-get install -y build-essential fakeroot debhelper                         autoconf automake bzip2 libssl-dev                         openssl graphviz python-all procps                         python-qt4 python-zopeinterface                         python-twisted-conch libtool
 ---> Using cache
 ---> ba197aaa1f2c
Step 3 : RUN apt-get install -y wget
 ---> Using cache
 ---> e84ee1d34f11
Step 4 : RUN wget -O - http://openvswitch.org/releases/openvswitch-2.3.1.tar.gz | tar xzf -
[... quite a few minutes later ...]
Successfully built b04a2ece350d
1021+1 records in
1021+1 records out
523114 bytes (523 kB) copied, 0.0324031 s, 16.1 MB/s
```

This should leave a bunch of `.deb` files in the current directory.

Then we can provision and configure a bunch of hosts. Let's configure 3 machines:

```
$ multi-host-docker-network createdroplets --numberOfDroplets 3 --userKey 429079 --compilePropellor --deployPropellor
Creating 3 hosts
creating host 2 with AUTH_KEY Just "somekey"
creating host 1 with AUTH_KEY Just "somekey"
creating host 3 with AUTH_KEY Just "somekey"
waiting for droplet host1 to become Active: 60s
waiting for droplet host2 to become Active: 60s
waiting for droplet host3 to become Active: 60s
waiting for droplet host1 to become Active: 59s
[...quite lengthy too...]
146.185.173.222 overall ... done
```

The `--userKey` parameter is of course specific to one's configuration on Digital Ocean. To provision the droplets, define an environment variable `AUTH_TOKEN` containing authentication token for DO API access. Note the flags used:

* `--compilePropellor` means we will run local docker-based compilation of configuration program to be sent for execution on remote hosts,
* `--deployPropellor` means we will actually run deployment on the built hosts.

It is also possible to run propellor build and run separately:

* `multi-host-docker-network buildpropellor`: Build a `propell` executable by running `stack build` inside current directory. Can be customized if one needs to build something different, 
* `multi-host-docker-network runpropellor --allHosts 1.2.3.4 --allHosts 2.3.4.5 --allHosts 3.4.5.6 --hostname 2.3.4.5`: run propellor configuration on given remote `hostname` passing the addresses/names of all the other hosts in the "cluster". It is important to pass exactly the same list to all configured hosts as this is used to define the GRE interfaces names in a way that matches pair of hosts.

## Testing

The configured hosts should be rebooted before testing configuration in order to ensure interfaces are correctly setup. Alternatively, one needs to do the following after propellor configuration has run:

* `service docker stop` to stop running docker: We will change its configuration and interface,
* `ip link delete docker0`: remove existing `docker0` interface created initially when we first installed docker,
* `ifup br0`: Start OVS bridge interface and bind GRE ports,
* `ifup docker0`: Start new docker interface,
* `service docker start`: Start docker.


Then log into on one of the remote hosts:

```
# docker run -ti ubuntu:trusty bash
root@e17699213c7e:/# ip addr eth0
7: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1462 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:02:00 brd ff:ff:ff:ff:ff:ff
    inet 172.17.2.0/16 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::42:acff:fe11:200/64 scope link 
    valid_lft forever preferred_lft forever
```

log into another remote host:

```
# docker run -ti ubuntu:trusty bash
root@23a4e9cbab72:/# ip addr
7: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1462 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:03:00 brd ff:ff:ff:ff:ff:ff
    inet 172.17.3.0/16 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::42:acff:fe11:300/64 scope link 
       valid_lft forever preferred_lft forever
root@23a4e9cbab72:/# ping 172.17.2.0
PING 172.17.2.0 (172.17.2.0) 56(84) bytes of data.
64 bytes from 172.17.2.0: icmp_seq=1 ttl=64 time=0.569 ms
64 bytes from 172.17.2.0: icmp_seq=2 ttl=64 time=0.485 ms
```

and in the first host:

```
root@e17699213c7e:/# ping 172.17.3.0
PING 172.17.3.0 (172.17.3.0) 56(84) bytes of data.
64 bytes from 172.17.3.0: icmp_seq=1 ttl=64 time=2.26 ms
64 bytes from 172.17.3.0: icmp_seq=2 ttl=64 time=0.681 ms
```
