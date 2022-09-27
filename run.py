#! /usr/bin/env python3
#
# MIT License
#
# (C) Copyright 2021-2022 Hewlett Packard Enterprise Development LP
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
import argparse
from distutils.log import error
import subprocess
import shutil
import sys
import re
import semver
import json
import yaml
import requests
import hvac
import docker
import datetime
import string
import secrets
import pathlib
import jinja2
import base64

from time import sleep
from rich.console import Console
from gen_hardware_config_files import generate_hardware_config_files

class SubprocessException(Exception):
    def __init__(self, result: subprocess.CompletedProcess):
        self.result = result

class IllegalStateException(Exception):
    def __init__(self, msg):
        self.msg = msg

class State:

    def __init__(self, args: argparse.Namespace, sls_state: dict, console: Console, error_console: Console):
        self.args = args
        self.sls_state = sls_state
        self.console = console
        self.error_console = error_console

        self.generated_config_files = None
        self.credentials = {}

        # Setup Vault Client
        self.vaultClient = hvac.Client(url='http://localhost:8200')
        self.vaultClient.token = "hms"

        # Setup Docker Client
        self.dockerClient = docker.from_env()

    #
    # Helper functions
    #

    def __wait_for_service(self, service_name, url, expected_status_code):
        attempts = 120
        for i in range(1, attempts+1):
            try: 
                result = requests.get(url)
                if result.status_code == expected_status_code: 
                    break
                    
            except requests.exceptions.ConnectionError: 
                pass
            if i >= attempts:
                raise IllegalStateException(f"Exhausted attempts waiting for {service_name} to become ready")

            self.console.log(f"Waiting for {service_name} to become ready. Attempt {i}/{attempts}")
            sleep(1)

        self.console.log(f"{service_name} is ready")

    #
    # Task functions
    #

    def verify_docker_compose_version(self):
        # Verify docker-compose is installed
        docker_path = shutil.which('docker')
        self.console.log(f"Verified docker is present at {docker_path}")

        # Verify docker-compose is at version 2.6.1 or greater.
        result = subprocess.run(["docker", "compose", "version", "--short"], capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        # We only care about the major/minor/patch versions.
        docker_compose_version = re.search('([0-9]+\.[0-9]+\.[0-9]+)', result.stdout.strip()).group(0)

        if semver.compare("2.6.1", docker_compose_version) == 1:
            raise IllegalStateException(f'Unexpected docker-compose version installed "{docker_compose_version}" expected 2.6.1 or greater')

        self.console.log(f"Verified docker-compose is at version {docker_compose_version}")
            
    def teardown_environment(self):
        running_containers = len(self.dockerClient.containers.list(filters={"label": ["com.docker.compose.project=hms-simulation-environment"]}))
        if running_containers > 0:
            # Stop any running containers
            self.console.log(f"Found {running_containers} existing containers")
            result = subprocess.run(["docker", "compose", "down", "--remove-orphans"], capture_output=True, text=True)
            if result.returncode != 0:
                raise SubprocessException(result)

            self.console.log(f"Removed existing containers")
        else:
            self.console.log("No existing containers were running")

    def generate_secrets_and_credentials(self):
        # Generate a random credentials
        alphabet = string.ascii_letters + string.digits
        self.credentials["root_password"] = ''.join(secrets.choice(alphabet) for i in range(10))
        self.credentials["snmp_auth_password"] = ''.join(secrets.choice(alphabet) for i in range(10))
        self.credentials["snmp_priv_password"] = ''.join(secrets.choice(alphabet) for i in range(10))
        self.console.log("Generated BMC and SNMP credentials")

        with open("configs/cray-meds-vault-loader.env", "w") as f:
            payload = json.dumps({
                "Username": "root",
                "Password": self.credentials["root_password"]
            })
            env_lines = [f"VAULT_REDFISH_DEFAULTS='{payload}'\n"]
            f.writelines(env_lines)

        self.console.log("Wrote configs/cray-meds-vault-loader.env")
            
        with open("configs/cray-reds-vault-loader.env", "w") as f:
            bmc_payload = json.dumps({
                "Cray": {
                    "Username": "root",
                    "Password": self.credentials["root_password"]
                }
            })
            snmp_payload = json.dumps({
                "SNMPUsername": "testuser",
                "SNMPAuthPassword": self.credentials["snmp_auth_password"],
                "SNMPPrivPassword": self.credentials["snmp_auth_password"],
            })

            env_lines = [
                f"VAULT_REDFISH_BMC_DEFAULTS='{bmc_payload}'\n",
                f"VAULT_REDFISH_SWITCH_DEFAULTS='{snmp_payload}'\n"
            ]
            f.writelines(env_lines)

        self.console.log("Wrote configs/cray-reds-vault-loader.env")

        # Verify openssl is installed
        openssl_path = shutil.which('openssl')
        self.console.log(f"Verified openssl is present at {openssl_path}")

        # Generate HTTPs certificates for Nginx
        certs_directory = pathlib.Path("configs/nginx/certs")
        certs_directory.mkdir(parents=True, exist_ok=True)
        command = ["openssl", "req", "-newkey", "rsa:4096", "-x509", "-sha256",
            "-days", "7",
            "-nodes",
            "-subj", "/C=US/ST=Minnesota/L=Bloomington/O=HPE/OU=Engineering/CN=hpe.com",
            "-out", str(certs_directory)+"/cert.crt",
            "-keyout", str(certs_directory)+"/cert.key"
        ]

        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        self.console.log(f"Generated TLS certificate for API gateway at {certs_directory}/cert.{{key,pem}}")

    def generate_hardware_configuration_files(self):
        # Generate the config files
        self.generated_config_files = generate_hardware_config_files(self.args.rie_image, self.sls_state["Hardware"], self.credentials["root_password"])
        self.rie_xnames = list(self.generated_config_files["docker_compose"]["services"].keys())

        # Generate Nginx RIE proxy configuration
        environment = jinja2.Environment(loader=jinja2.FileSystemLoader("configs/nginx/conf.d/proxy"))
        nginx_rie_template = environment.get_template("rie.conf.j2")
        nginx_rie_content = nginx_rie_template.render({
            "xnames": self.rie_xnames,
            "credentials_b64": base64.b64encode(f'root:{self.credentials["root_password"]}'.encode('utf-8')).decode('utf-8')
        })

        # Write out generated files
        with open("configs/nginx/conf.d/proxy/rie.conf", "w") as f:
            f.write(nginx_rie_content)
        self.console.log("Wrote configs/nginx/conf.d/rie.conf")


        with open("docker-compose.hardware.yaml", "w") as f:
            yaml.dump(self.generated_config_files["docker_compose"], f)
        self.console.log("Wrote docker-compose.hardware.yaml")

        with open("configs/portNumberMap.json", "w") as f:
            json.dump(self.generated_config_files["port_number_maps"], f, indent=4, sort_keys=True)
        self.console.log("Wrote configs/portNumberMap.json")

        with open("configs/portMap.json", "w") as f:
            json.dump(self.generated_config_files["port_maps"], f, indent=4, sort_keys=True)
        self.console.log("Wrote configs/portMap.json")

        with open("configs/macPortMap.json", "w") as f:
            json.dump(self.generated_config_files["mac_port_maps"], f, indent=4, sort_keys=True)
        self.console.log("Wrote configs/macPortMap.json")

        with open("configs/seed_ethernet_interfaces.json", "w") as f:
            json.dump(self.generated_config_files["seed_ethernet_interfaces"], f, indent=4, sort_keys=True)
        self.console.log("Wrote configs/seed_ethernet_interfaces.json")

        self.console.log("Generated hardware configuration files from provided SLS file")

    def start_hardware(self):
        if len(self.rie_xnames) == 0:
            self.console.log("Skipping starting emulated hardware, as no emulated hardware was generated.")
            return

        result = subprocess.run(["docker", "compose", "-f", "docker-compose.hardware.yaml", "up", "-d"], capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        self.console.log("Started emulated hardware")

    def start_vault(self):
        result = subprocess.run(["docker", "compose", "-f", "docker-compose.yaml", "-f", "docker-compose.health.yaml", "up", "-d", "vault"], capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        self.console.log("Started Vault Services")

    def start_hms_services(self):
        result = subprocess.run(["docker", "compose", "-f", "docker-compose.yaml", "-f", "docker-compose.health.yaml", "up", "-d"], capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        self.console.log("Started HMS Services")

    def wait_for_sls(self):
        self.__wait_for_service("SLS", "http://localhost:8376/v1/readiness", 204)

    def wait_for_hsm(self):
        self.__wait_for_service("HSM", "http://localhost:27779/hsm/v2/service/ready", 200)

    def perform_sls_loadstate(self):
        payload = {
            "sls_dump": json.dumps(self.sls_state)
        }

        result = requests.post("http://localhost:8376/v1/loadstate", files=payload)
        result.raise_for_status()

        self.console.log("SLS load state operation successful")

    def wait_for_vault(self):
        attempts = 120
        for i in range(1, attempts+1):
            try: 
                if self.vaultClient.sys.is_initialized():
                    break
                
            except requests.exceptions.ConnectionError:
                pass

            if i >= attempts:
                raise IllegalStateException("Exhausted attempts waiting for HSM to become ready")

            self.console.log(f"Waiting for Vault to become ready. Attempt {i}/{attempts}")
            sleep(1)

        self.console.log("Vault is ready")

        # Wait for Vault to stabilize
        for i in range(0, 30):
            try: 
                self.console.log("Vault Initialized", self.vaultClient.sys.is_initialized())
                
            except requests.exceptions.ConnectionError as e:
                self.console.log(e)
            sleep(1)

    def provision_vault(self):
        # The previous of vault in pervious iterations of the hms-simulation-environment has been fragile
        # so we will stand up each init job one at a time after we know that vault is healthy.
        for service in ["vault-kv-enabler", "cray-reds-vault-loader", "cray-meds-vault-loader"]:
            result = subprocess.run(["docker", "compose", "-f", "docker-compose.yaml", "up", "--exit-code-from", service, service], capture_output=True, text=True)
            if result.returncode != 0:
                raise SubprocessException(result)

            self.console.log(f"Provisioned Vault with {service}")

        # Verify default credentials exist in vault
        for key in ["meds-cred/global/ipmi", "reds-creds/defaults", "reds-creds/switch_defaults"]:
            try:
                self.vaultClient.secrets.kv.v1.read_secret(key)
                self.console.log(f"Verified secret/{key} exists in Vault")
            except hvac.exceptions.InvalidPath as e:
                self.error_console.log(f"Expected secret secret/{key} does not exist in Vault")
                raise e

    def seed_hsm_with_ethernet_interfaces(self):
        # For context, this function is taking the place of KEA partially. Normally BMCs DHCP with KEA, and then KEA updates
        # HSM with the MAC address and IP address of a BMC.
        seed_ethernet_interfaces = self.generated_config_files["seed_ethernet_interfaces"]
    
        if len(seed_ethernet_interfaces) == 0:
            self.console.log("No ethernet interfaces generated to seed in HSM")
            return

        # Query docker to build a mapping from xname to IP address
        xnames_ips = {}
        for container in self.dockerClient.containers.list(filters={"label": ["com.docker.compose.project=hms-simulation-environment", "com.github.cray-hpe.hms-simulation-environment.xname"]}):
            xname = container.labels["com.github.cray-hpe.hms-simulation-environment.xname"]

            # The following is equivalent to: docker inspect "hms-test-env-${xname}-1" | jq '.[0].NetworkSettings.Networks[].IPAddress' -r
            ip_address = list(container.attrs['NetworkSettings']["Networks"].values())[0]["IPAddress"]
            xnames_ips[xname] = ip_address

            # TODO potential optimization for MAC addresses to consider
            # - RIE should read the BMC MAC address from docker
            # - Then the seed ethernetinterfaces should be build from that MAC address
            # mac_address = list(container.attrs['NetworkSettings']["Networks"].values())[0]["IPAddress"]


        # Merge the the seed_ethernet_interfaces with data from docker
        for ei in seed_ethernet_interfaces:
            xname = ei["ComponentID"]

            # Remove the component ID from the payload to allow the hms-discovery cronjob to fill it in later
            del ei["ComponentID"]

            # Determine the IP address of the ethernet interface
            ei["IPAddresses"] = [{
                "IPAddress": xnames_ips[xname]
            }]

            # Push the updated ethernet interface into HSM
            result = requests.post('http://localhost:27779/hsm/v2/Inventory/EthernetInterfaces', json=ei)
            result.raise_for_status()

            self.console.log(f"Seeded EthernetInterface in HSM for {xname}: " + json.dumps(ei))

    def run_hms_discovery(self):
        result = subprocess.run(["docker", "compose", "-f", "docker-compose.yaml", "up", "--exit-code-from", "hms-discovery", "hms-discovery"], capture_output=True, text=True)
        if result.returncode != 0:
            raise SubprocessException(result)

        self.console.log("Completed hms-discovery run")

    def wait_for_hardware_to_be_discovered(self):
        # Determine how many BMCs are expected to be discovered. A quick hack would be to parse the generated hardware docker-compose.yaml file
        expected_bmc_count = len(self.rie_xnames)

        if expected_bmc_count == 0:
            self.console.log("Skipping discovery check, as no emulated hardware was generated.")
            return

    
        # Wait for hardware to get discovered
        attempts = self.args.wait_attempts_for_discovered_hardware
        for i in range(1, attempts+1):
            discovery_status_counts = {}
            redfish_endpoints_to_rediscover = []

            result = requests.get("http://localhost:27779/hsm/v2/Inventory/RedfishEndpoints")
            if result.status_code != 200:
                self.error_console.log(f"Failed to query HSM for RedfishEndpoints. Received {result.status_code} status code, expected 200") 
                sleep(5)
                continue
            
            for redfish_endpoint in result.json()["RedfishEndpoints"]:
                discovery_status = redfish_endpoint["DiscoveryInfo"]["LastDiscoveryStatus"]

                # Build up a list of discovery counts,
                if discovery_status not in discovery_status_counts:
                    discovery_status_counts[discovery_status] = 0
                discovery_status_counts[discovery_status] += 1

                # Identify redfish endpoints that are not DiscoverOK or DiscoveryStarted 
                if discovery_status not in ["DiscoverOK", "DiscoveryStarted", "NotYetQueried"]:
                    redfish_endpoints_to_rediscover.append(redfish_endpoint["ID"])
        
            if "DiscoverOK" in discovery_status_counts and discovery_status_counts["DiscoverOK"] == expected_bmc_count:
                break

            if i >= attempts:
                raise IllegalStateException(f"Exhausted attempts waiting for redfish endpoints to become discovered")
            
            self.console.log(f"Waiting for {expected_bmc_count} redfish endpoints to become discovered. {json.dumps(discovery_status_counts)} Attempt {i}/{attempts}")
            
            # Rediscover all redfish endpoints that are not DiscoverOK or DiscoveryStarted. This is taking the place of the hms-discovery job
            if len(redfish_endpoints_to_rediscover) > 0:
                self.console.log("Issuing a rediscovery on: ", json.dumps(redfish_endpoints_to_rediscover))
                result = requests.post('http://localhost:27779/hsm/v2/Inventory/Discover', json={"xnames": redfish_endpoints_to_rediscover})
                result.raise_for_status()
            
            # Verify default credentials exist in vault
            for key in ["meds-cred/global/ipmi", "reds-creds/defaults", "reds-creds/switch_defaults"]:
                try:
                    self.vaultClient.secrets.kv.v1.read_secret(key)
                    self.console.log(f"Verified secret/{key} exists in Vault")
                except hvac.exceptions.InvalidPath as e:
                    self.error_console.log(f"Expected secret secret/{key} does not exist in Vault")
                    # raise e

            sleep(5)



        self.console.log("Hardware has been discovered by HSM")

    def wait_for_redfish_event_subscriptions(self):
        expected_bmc_count = len(self.rie_xnames)
        if expected_bmc_count == 0:
            self.console.log("Skipping redfish event subscription check, as no emulated hardware was generated.")
            return

        bmcs_with_subscriptions = set()

        # Wait for each to have at least 1 event subscriptions
        attempts = self.args.wait_attempts_for_redfish_events
        for i in range(1, attempts+1):            
            for xname in self.rie_xnames:
                # Only checkup on the BMCs that do not have subscriptions
                if xname in bmcs_with_subscriptions:
                    continue
                
                # Query the BMC for event subscriptions
                # Need to go through the API gateway due to no exports being exposed on the host system for the BMCs.
                response = requests.get(f"http://localhost:8080/{xname}/redfish/v1/EventService/Subscriptions")
                response.raise_for_status()

                # If there is 1 or more subscription, then the collector has done its job.
                if len(response.json()["Members"]):
                    bmcs_with_subscriptions.add(xname)
            
            if len(bmcs_with_subscriptions) == len(self.rie_xnames):
                break
        
            if i >= attempts:
                raise IllegalStateException(f"Exhausted attempts waiting for redfish event subscriptions to be created")

            self.console.log(f"Waiting for {expected_bmc_count} redfish endpoints to have event subscriptions, currently at {len(bmcs_with_subscriptions)}. Attempt {i}/{attempts}")
            sleep(5)

        self.console.log(f"Redfish event subscriptions have been setup on {len(bmcs_with_subscriptions)} BMCs")  


def main():
    # Keep track of the time when the script start, so we can know how long the script takes to run.
    start = datetime.datetime.now()

    #
    # Argument parsing
    #
    parser = argparse.ArgumentParser()
    # SLS should have a '@rie.mockup' annotation to specify the hardware type of a device in the extra properties
    # TODO add in useful help text
    # TODO we should have mockups created from different falvors of management NCNs, as they have different hardware configurations, and therefor would have different redfish data
    parser.add_argument("sls_file", help="Seed SLS file to generate a environment from.")
    parser.add_argument("--rie-image", default="artifactory.algol60.net/csm-docker/stable/csm-rie:1.3.0")
    parser.add_argument("--wait-attempts-for-discovered-hardware", type=int, default=120)
    parser.add_argument("--wait-attempts-for-redfish-events", type=int, default=120)
    # TODO add args for default hardware types. This might just be hard coded
    # parser.add_argument("--default-mockup-management-ncn", type=str, default="DL325")
    # parser.add_argument("--default-mockup-air-cooled-compute", type=str, default="Gigabyte")
    # parser.add_argument("--default-mockup-liquid-cooled-compute", type=str, default="EX425")

    args = parser.parse_args()

    #
    #
    #
    console = Console()
    error_console = Console(stderr=True, style="bold red")


    # Read in the SLS file here
    sls_state = None
    with open(args.sls_file, "r") as f:
        sls_state = json.load(f)

    #
    # Build up task list
    #
    state = State(args=args, sls_state=sls_state, console=console, error_console=error_console)

    tasks = [
        {
            "in_progress": "Verifying docker-compose installation",
            "run": state.verify_docker_compose_version
        }, {
            "in_progress": "Removing any existing containers...",
            "run": state.teardown_environment
        }, {
            "in_progress": "Generating ephemeral secrets and credentials...",
            "run": state.generate_secrets_and_credentials
        }, {
            "in_progress": "Generating hardware configuration files from SLS file...",
            "run": state.generate_hardware_configuration_files
        }, {
            "in_progress": "Starting emulated hardware...",
            "run": state.start_hardware
        }, {
            "in_progress": "Starting Vault...",
            "run": state.start_vault
        }, {
            "in_progress": "Waiting for Vault to become ready...",
            "run": state.wait_for_vault
        }, {
            "in_progress": "Provisioning Vault...",
            "run": state.provision_vault
        }, {
            "in_progress": "Starting HMS services...",
            "run": state.start_hms_services
        }, {
            "in_progress": "Waiting for SLS to become ready...",
            "run": state.wait_for_sls
        }, {
            "in_progress": "Waiting for HSM to become ready...",
            "run": state.wait_for_hsm
        }, {
            "in_progress": "Performing SLS load state operation...",
            "run": state.perform_sls_loadstate        
        }, {
            "in_progress": "Seeding HSM with EthernetInterfaces...",
            "run": state.seed_hsm_with_ethernet_interfaces
        }, {
            "in_progress": "Running hms-discovery to discovery River hardware...",
            "run": state.run_hms_discovery
        }, {
            "in_progress": "Waiting for hardware to get discovered...",
            "run": state.wait_for_hardware_to_be_discovered
        }, {
            "in_progress": "Waiting for redfish event subscriptions to be setup...",
            "run": state.wait_for_redfish_event_subscriptions
        }
    ]

    #
    # Run tasks
    #
    try:
        for task in tasks:
            with console.status("[bold green]"+task["in_progress"], spinner="bouncingBar") as status:
                # Do the thing
                if "run" in task:
                    task["run"]()
                else:
                    sleep(1)
                # Done

            if "success" in task:
                console.log(task["success"])
    except SubprocessException as e:
        error_console.log(f"Failed to execute command: {' '.join(e.result.args)}")
        error_console.log(f"Exit code: {e.result.returncode}")
        error_console.log(f"Standard out: {e.result.stdout}")
        error_console.log(f"Standard error: {e.result.stderr}")
        return 1
    except KeyboardInterrupt as e:
        error_console.log("Received keyboard interrupt")
        return 1
    # except Exception as e:
    #     error_console.log(type(e), str(e))
    #    return 1

    # Figure out how long the script took to run
    end = datetime.datetime.now()
    duration = end - start
    minutes, seconds = divmod(duration.total_seconds(), 60)

    console.log(f"The HMS hardware simulation environment is ready in {minutes}m{seconds}s")
    return 0

if __name__ == "__main__":
    sys.exit(main())
