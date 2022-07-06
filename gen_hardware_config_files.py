#! /usr/bin/env python3

# MIT License
#
# (C) Copyright [2022] Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

from sqlite3 import connect
import yaml
import json
import os
import sys
import random
import itertools

RIE_IMAGE="artifactory.algol60.net/csm-docker/stable/csm-rie:1.3.0"
NETWORK="meds"

def make_emulator(xname, mockup, network):
    return {
        "hostname": xname,
        "image": RIE_IMAGE,
        "environment": [
            "MOCKUPFOLDER={}".format(mockup),
            "XNAME={}".format(xname),
            "AUTH_CONFIG=root:root_password:Administrator",
            "PORT=443",
        ],
        "networks": [network]
    }

def generate_mac_address() -> str:
    rndMAC = [ 0x00, 0x40, 0xa6,
            random.randint(0x00, 0x7f),
            random.randint(0x00, 0xff),
            random.randint(0x00, 0xff)]
    return ':'.join(map(lambda x: "%02x" % x, rndMAC))

#
# Read in SLS file
#
sls_hardware = None
with open(sys.argv[1], "r") as f:
    sls_hardware = json.load(f)["Hardware"]

#
# Identify Mountain/Hill Hardware
#
liquid_cooled_chassis = []
for _, hardware in sls_hardware.items():
    if hardware["Class"] not in ["Hill", "Mountain"]:
        continue

    if hardware["TypeString"] != "Chassis":
        continue

    liquid_cooled_chassis.append(hardware)


#
# Identify River Hardware 
#
river_nodes = []
river_router_bmcs = []
river_pdus = []
mgmt_switch_connectors = []
leaf_bmc_switches = []

for xname, hardware in sls_hardware.items():
    if hardware["Class"] != "River":
        continue

    if hardware["TypeString"] == "Node":
        river_nodes.append(hardware)
    elif hardware["TypeString"] == "RouterBMC":
        river_router_bmcs.append(hardware)
    elif hardware["TypeString"] == "CabinetPDUController":
        # TODO 
        # river_pdus.append(hardware)
        pass
    elif hardware["TypeString"] == "MgmtSwitchConnector":
        mgmt_switch_connectors.append(hardware)
    elif hardware["TypeString"] == "MgmtSwitch":
        leaf_bmc_switches.append(hardware)
    

endpoints = {}

#
# Build up docker-compose file
#

# Liquid-cooled BMCs
for chassis in liquid_cooled_chassis:
    # Chassis BMC
    chassisBMCXname = chassis["Xname"]+"b0"
    endpoints[chassisBMCXname] = make_emulator(chassisBMCXname, "CMM", NETWORK)

    for slot in ["s0", "s1", "s2","s3","s4", "s5", "s6", "s7"]:
        for nodeBMC in ["b0", "b1"]:
            # NodeBMC
            nodeBMCXname = chassis["Xname"]+slot+nodeBMC
            endpoints[nodeBMCXname] = make_emulator(nodeBMCXname, "EX425", NETWORK)
    for slot in ["r0", "r1", "r2","r3","r4", "r5", "r6", "r7"]:
        for routerBMC in ["b0"]:
            # RouterBMC
            routerBMCXname = chassis["Xname"]+slot+routerBMC
            endpoints[routerBMCXname] = make_emulator(routerBMCXname, "Slingshot_Switch_Blade", NETWORK)


# River BMCs
for hardware in river_nodes:
    bmc_xname = hardware["Parent"]
    if hardware["ExtraProperties"]["Role"] == "Compute":
        endpoints[bmc_xname] = make_emulator(bmc_xname, "Gigabyte", NETWORK)
    elif hardware["ExtraProperties"]["Role"] in ["Management", "Application"]:
        endpoints[bmc_xname] = make_emulator(bmc_xname, "DL325", NETWORK)
    else:
        print("Unable to handle node {}".format(hardware))
        sys.exit(1)

for hardware in river_router_bmcs:
    endpoints[hardware["Xname"]] = make_emulator(hardware["Xname"], "Slingshot_Switch_Blade", NETWORK)

# Build docker-compose
docker_compose = {
    "version": "3.7",
    "networks": {
        "meds": {}
    },
    "services": endpoints
}

#
# Build up mock SMNP information
# This is an approximation
#
port_number_maps = {}
port_maps = {}
for switch in leaf_bmc_switches:
    port_number_map = {}
    port_map = {}

    # 1 gig ports
    index = 11 # Start at 11 for some reason
    for port in range(1, 49):
        index += 1

        interfaceName = None
        if switch["ExtraProperties"]["Brand"] == "Aruba":
            interfaceName = "1/1/{}".format(port)
        elif switch["ExtraProperties"]["Brand"] == "Dell":
            interfaceName = "ethernet1/1/{}".format(port)
        else:
            print("Unable to handle switch {}".format(switch))    

        port_number_map["{}".format(index)] = port
        port_map["{}".format(index)] = interfaceName

    port_number_maps[switch["Xname"]] = port_number_map
    port_maps[switch["Xname"]] = port_map

seed_ethernet_interfaces = {}
mac_port_maps = {}
for mgmt_switch_connector in mgmt_switch_connectors:
    mac_address = generate_mac_address()
    mac_address_no_colons = mac_address.replace(":", "")
    if mac_address_no_colons in seed_ethernet_interfaces:
        print("Generated a duplicate MAC!!!!", mac_address)
        sys.exit(1)

    connected_bmc = mgmt_switch_connector["ExtraProperties"]["NodeNics"][0]
    switch_interface = mgmt_switch_connector["ExtraProperties"]["VendorName"]
    mgmt_switch = mgmt_switch_connector["Parent"]

    # HACK, we don't support river PDUs
    if "m0" in connected_bmc or "m1" in connected_bmc:
        continue

    # Add it to initial set of EthernetInterfaces to seed HSM. This is taking the place of DHCP/KEA
    seed_ethernet_interfaces[mac_address_no_colons] = {
        "MACAddress": mac_address,
        "Description": connected_bmc
    }

    # Add it to the mac to port map.
    if mgmt_switch not in mac_port_maps:
        mac_port_maps[mgmt_switch] = {}
    mac_port_maps[mgmt_switch][mac_address_no_colons] = switch_interface

#
# Write out config files
#

print("Writing docker-compose.hardware.yaml...")
with open("docker-compose.hardware.yaml", "w") as f:
    yaml.dump(docker_compose, f)

print("Writing configs/portNumberMap.json...")
with open("configs/portNumberMap.json", "w") as f:
    json.dump(port_number_maps, f, indent=4, sort_keys=True)

print("Writing configs/portMap.json...")
with open("configs/portMap.json", "w") as f:
    json.dump(port_maps, f, indent=4, sort_keys=True)

print("Writing configs/macPortMap.json...")
with open("configs/macPortMap.json", "w") as f:
    json.dump(mac_port_maps, f, indent=4, sort_keys=True)

print("Writing configs/seed_ethernet_interfaces.json...")
with open("configs/seed_ethernet_interfaces.json", "w") as f:
    json.dump(seed_ethernet_interfaces, f, indent=4, sort_keys=True)