#! /usr/bin/env python3
#
# MIT License
#
# (C) Copyright 2022 Hewlett Packard Enterprise Development LP
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
#

import yaml
import json
import re
import sys
import random

NETWORK="simulation"

# This is the list of mockups that are validated to work with the simulation environment.
SUPPORTED_MOCKUP_TYPES = {
    "CMM": ["Hill", "Mountain"],
    "DL325": ["River"],
    "EX235a": ["Hill", "Mountain"],
    "EX235n": ["Hill", "Mountain"],
    "EX420": ["Hill", "Mountain"],
    "EX425": ["Hill", "Mountain"],
    "EX4252": ["Hill", "Mountain"],
    "Gigabyte": ["River"],
    "Intel": ["River"],
    "public-rackmount1": ["River"],
    "Slingshot_Switch_Blade": ["River", "Hill", "Mountain"],
    "XL675d_A40":  ["River"],
}

EXPECTED_BLADE_BMCS = {
        "EX235a": ["b0", "b1"], # Bard Peak
        "EX235n": ["b0"],       # Grizzly Peak
        "EX425":  ["b0", "b1"], # Windom
        "EX420":  ["b0", "b1"], # Castle
        "EX255a": ["b0", "b1"], # Parry Peak
        "EX4252": ["b0"],       # Antero
        "EX254n": ["b0", "b1"], # Blanca Peak
    }

EXPECTED_BMC_NODES = {
    "EX235a": ["n0"],                   # Bard Peak
    "EX235n": ["n0", "n1"],             # Grizzly Peak
    "EX425":  ["n0", "n1"],             # Windom
    "EX420":  ["n0", "n1"],             # Castle
    "EX255a": ["n0"],                   # Parry Peak
    "EX4252": ["n0", "n1", "n2", "n3"], # Antero
    "EX254n": ["n0"],                   # Blanca Peak
}

def make_emulator(rie_image: str, xname: str, mockup: str, network: str, root_password: str) -> dict:
    return {
        "hostname": xname,
        "image": rie_image,
        "environment": [
            f"MOCKUPFOLDER={mockup}",
            f"XNAME={xname}",
            f"AUTH_CONFIG=root:{root_password}:Administrator",
            "PORT=443",
        ],
        "labels": [
            f"com.github.cray-hpe.hms-simulation-environment.xname={xname}"
        ],
        "networks": [network]
    }

def generate_mac_address() -> str:
    rndMAC = [ 0x00, 0x40, 0xa6,
            random.randint(0x00, 0x7f),
            random.randint(0x00, 0xff),
            random.randint(0x00, 0xff)]
    return ':'.join(map(lambda x: "%02x" % x, rndMAC))

# UnsupportedMockupException is raised when a mockup type is not present in the SUPPORTED_MOCKUP_TYPES table.
class UnsupportedMockupException(Exception):

    def __init__(self, xname, mockup):
        self.xname = xname
        self.mockup = mockup

# UnsupportedMockupClassException is raised when a mockup type is trying to be used with a SLS class/cabinet type that is
# is not listed in SUPPORTED_MOCKUP_TYPES table.
class UnsupportedMockupClassException(Exception):

    def __init__(self, xname, mockup, slsClass):
        self.xname = xname
        self.mockup = mockup
        self.slsClass = slsClass


def get_mockup_type(hardware: dict, default: str):
    mockup = default
    if "ExtraProperties" in hardware and "@rie.mockup" in hardware["ExtraProperties"]:
        mockup = hardware["ExtraProperties"]["@rie.mockup"]


    # Determine if this is a supported mockup
    if mockup not in SUPPORTED_MOCKUP_TYPES:
        raise UnsupportedMockupException(hardware["Xname"], mockup)
    
    # Determine if this mockup is being used in the correct context
    if hardware["Class"] not in SUPPORTED_MOCKUP_TYPES[mockup]:
        raise UnsupportedMockupClassException(hardware["Xname"], mockup, hardware["Class"])

    return mockup

def generate_hardware_config_files(rie_image: str, sls_hardware: dict, root_password: str) -> dict:
    #
    # Identify Mountain/Hill Hardware
    #
    liquid_cooled_chassis = []
    liquid_cooled_compute_blades = {}
    liquid_cooled_router_blades = {}
    for _, hardware in sls_hardware.items():
        if hardware["Class"] not in ["Hill", "Mountain"]:
            continue

        if hardware["TypeString"] == "Chassis":
            liquid_cooled_chassis.append(hardware)

        if hardware["TypeString"] == "ComputeModule":
            if hardware["Parent"] not in liquid_cooled_compute_blades:
                liquid_cooled_compute_blades[hardware["Parent"]] = []
            liquid_cooled_compute_blades[hardware["Parent"]].append(hardware)

        if hardware["TypeString"] == "RouterModule":
            if hardware["Parent"] not in liquid_cooled_router_blades:
                liquid_cooled_router_blades[hardware["Parent"]] = []
            liquid_cooled_router_blades[hardware["Parent"]].append(hardware)

    # Add in default blades types for all nodes that did not have a explicit blade type specified.
    for _, hardware in sls_hardware.items():
        if hardware["Class"] not in ["Hill", "Mountain"]:
            continue

        if hardware["TypeString"] != "Node":
            continue

        # Determine the xname of of the chassis slot
        matches = re.findall("^((x[0-9]{1,4}c[0-7])s[0-9])+b[0-9]+n[0-9]+$", hardware["Xname"])
        if len(matches) != 1:
            print("Unable to extract blade slot xname from node xname", hardware["Xname"])
            sys.exit(1)
        chassis_slot, chassis = matches[0]
        
        # If this is the first time we are seeing the chassis, create a empty list of blades for it
        if chassis not in liquid_cooled_compute_blades:
            liquid_cooled_compute_blades[chassis] = []

        # Check to see if we already know the RIE mockup type for the blade
        if chassis_slot in list(map(lambda e: e["Xname"],liquid_cooled_compute_blades[chassis])):
            continue

        # Add in the default blade type. The default will be chosen when creating the mockup
        liquid_cooled_compute_blades[chassis].append({
            "Parent": chassis,
            "Xname": chassis_slot,
            "Type": "comptype_compmod",
            "TypeString": "ComputeModule",
            "Class": hardware["Class"],
        })

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
        endpoints[chassisBMCXname] = make_emulator(rie_image, chassisBMCXname, "CMM", NETWORK, root_password)

        # Identify slots in use
        if chassis["Xname"] in liquid_cooled_compute_blades: 
            for blade in liquid_cooled_compute_blades[chassis["Xname"]]:
                # By default assume windom blades
                mockup = get_mockup_type(blade, "EX425")
                
                for nodeBMC in EXPECTED_BLADE_BMCS[mockup]:
                    # NodeBMC
                    nodeBMCXname = blade["Xname"]+nodeBMC
                    endpoints[nodeBMCXname] = make_emulator(rie_image, nodeBMCXname, mockup, NETWORK, root_password)
        if chassis["Xname"] in liquid_cooled_router_blades: 
            for blade in liquid_cooled_router_blades[chassis["Xname"]]:
                # By default assume Slingshot_Switch_Blade blades
                mockup = get_mockup_type(blade, "Slingshot_Switch_Blade")
                
                # RouterBMC
                routerBMCXname = blade["Xname"]+"b0"
                endpoints[routerBMCXname] = make_emulator(rie_image, routerBMCXname, mockup, NETWORK, root_password)


    # River BMCs
    for hardware in river_nodes:
        bmc_xname = hardware["Parent"]
        if hardware["ExtraProperties"]["Role"] == "Compute":
            # By default assume Gigabyte compute nodes
            mockup = get_mockup_type(hardware, "Gigabyte")
            endpoints[bmc_xname] = make_emulator(rie_image, bmc_xname, mockup, NETWORK, root_password)
        elif hardware["ExtraProperties"]["Role"] in ["Management", "Application"]:
            # By default assuming DL325 for NCN nodes
            mockup = get_mockup_type(hardware, "DL325")
            endpoints[bmc_xname] = make_emulator(rie_image, bmc_xname, mockup, NETWORK, root_password)
        else:
            print("Unable to handle node {}".format(hardware))
            sys.exit(1)

    for hardware in river_router_bmcs:
        # By default assume Slingshot_Switch_Blade blades
        mockup = get_mockup_type(hardware, "Slingshot_Switch_Blade")

        endpoints[hardware["Xname"]] = make_emulator(rie_image, hardware["Xname"], mockup, NETWORK, root_password)

    # Build docker-compose
    docker_compose = {
        "version": "3.7",
        "networks": {
            "simulation": {}
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

    seed_ethernet_interfaces_map = {}
    mac_port_maps = {}
    for mgmt_switch_connector in mgmt_switch_connectors:
        mac_address = generate_mac_address()
        mac_address_no_colons = mac_address.replace(":", "")
        if mac_address_no_colons in seed_ethernet_interfaces_map:
            print("Generated a duplicate MAC!!!!", mac_address)
            sys.exit(1)

        connected_bmc = mgmt_switch_connector["ExtraProperties"]["NodeNics"][0]
        switch_interface = mgmt_switch_connector["ExtraProperties"]["VendorName"]
        mgmt_switch = mgmt_switch_connector["Parent"]

        # HACK, we don't support river PDUs
        if "m0" in connected_bmc or "m1" in connected_bmc:
            continue

        # Add it to initial set of EthernetInterfaces to seed HSM. This is taking the place of DHCP/KEA
        seed_ethernet_interfaces_map[mac_address_no_colons] = {
            "MACAddress": mac_address,
            "ComponentID": connected_bmc
        }

        # Add it to the mac to port map.
        if mgmt_switch not in mac_port_maps:
            mac_port_maps[mgmt_switch] = {}
        mac_port_maps[mgmt_switch][mac_address_no_colons] = switch_interface

    seed_ethernet_interfaces = []
    for ei in seed_ethernet_interfaces_map.values():
        seed_ethernet_interfaces.append(ei)

    return {
        "docker_compose": docker_compose,
        "port_number_maps": port_number_maps,
        "port_maps": port_maps, 
        "mac_port_maps": mac_port_maps,
        "seed_ethernet_interfaces": seed_ethernet_interfaces,
    }

if __name__ == "__main__":
    #
    # Read in SLS file
    #
    sls_hardware = None
    with open(sys.argv[1], "r") as f:
        sls_hardware = json.load(f)["Hardware"]

    #config_files = generate_hardware_config_files("artifactory.algol60.net/csm-docker/stable/csm-rie:1.3.0", sls_hardware, "")
    config_files = generate_hardware_config_files("artifactory.algol60.net/csm-docker/unstable/csm-rie:1.5.0-20231030221753.5865473", sls_hardware, "")

    #
    # Write out config files
    #

    print("Writing docker-compose.hardware.yaml...")
    with open("docker-compose.hardware.yaml", "w") as f:
        yaml.dump(config_files["docker_compose"], f)

    print("Writing configs/portNumberMap.json...")
    with open("configs/portNumberMap.json", "w") as f:
        json.dump(config_files["port_number_maps"], f, indent=4, sort_keys=True)

    print("Writing configs/portMap.json...")
    with open("configs/portMap.json", "w") as f:
        json.dump(config_files["port_maps"], f, indent=4, sort_keys=True)

    print("Writing configs/macPortMap.json...")
    with open("configs/macPortMap.json", "w") as f:
        json.dump(config_files["mac_port_maps"], f, indent=4, sort_keys=True)

    print("Writing configs/seed_ethernet_interfaces.json...")
    with open("configs/seed_ethernet_interfaces.json", "w") as f:
        json.dump(config_files["seed_ethernet_interfaces"], f, indent=4, sort_keys=True)
