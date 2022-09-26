# hms-simulation-environment

The HMS Simulation Environment provides... (change to enable)
* ...an environment for automated tests to be ran against the HMS stack and hardware.
   * Allows for destructive automated testing development without harming a real system.
   * Development of new tests without the need for real hardware.
* an environment for local development testing against simulated hardware.


## Usage
1.  Create a Python virtual environment and install required dependencies:
    > If running Python 3.10 on macOS, then issues may arise when installing the Cray CLI. 
    >
    > To enable installing the Cray CLI under Python 3.10 on macOS the following workaround can be applied..
    > 1. Install Python 3.8
    > ```bash
    > brew install python@3.8
    > ```
    > 1. Set `PYTHON_EXE` to `python3.8`. This will change which Python interpreter the script `setup_venv.sh` uses.
    >   ```bash
    >   export PYTHON_EXE=python3.8
    >   ```
    > 1. Remove any existing Python virtual enviroment.
    >   ```bash
    >   rm -rv venv
    >   ```
    > 1. Create the Python Virtual Enviroment:
    >   ```bash
    >   ./setup_venv.sh
    >   ```

    ```bash
    ./setup_venv.sh
    ```

1.  **If desired**, install and configure the [Cray CLI](https://github.com/Cray-HPE/Craycli).

    1. Install the Cray CLI.

        ```bash
        git clone https://github.com/Cray-HPE/craycli.git
        pushd craycli/
        pip install -e . 
        popd
        ```

    1. Configure the Cray CLI:

        ```bash
        cray config set core hostname=https://localhost:8443
        ```

1. Standup the simulation environment with a desired hardware topology:

    ```bash
    ./run.py configs/sls/small_mountain.json
    ```

    The desired hardware topology can selected by choosing one of the existing SLS state files present in the `configs/sls/`.

    The `--rie-image` flag can be specified 

1.  The simulation environment is now ready for use. All hardware has been discovered, and ready for use. See the [Use cases](#use-cases) section for some things to try out.


    Port listing:
    | Name         | Port  | URL                                                                    |
    | ------------ | ----- | ---------------------------------------------------------------------- |
    | BSS          | 27778 | [http://localhost:27778/boot/v1](http://localhost:27778/boot/v1)       |
    | CAPMC        | 27777 | [http://localhost:27777/capmc/v1/](http://localhost:27777/capmc/v1/)   |
    | FAS          | 28800 | [http://localhost:28800](http://localhost:28800)                       |
    | Kafka        | 2181  |                                                                        |
    | HSM          | 27779 | [http://localhost:27779/hsm/v2/](http://localhost:27779/hsm/v2/)       |
    | HSM Database | 54322 |                                                                        |
    | S3           | 9000  | [http://localhost:8376/v1/](http://localhost:8376/v1)                  |
    | SLS          | 8376  | [http://localhost:82000](http://localhost:82000)                       | 
    | SLS Database | 54321 |                                                                        |
    | Vault        | 8200  | [http://localhost:82000](http://localhost:82000)                       | 


    API Gateway Paths.
    | Name                 | Production API Path | URL                                                                                              |
    | -------------------- | ------------------- | ------------------------------------------------------------------------------------------------ |
    | BSS                  | Yes                 | [https://localhost:8443/apis/bss/boot/v1/](https://localhost:8443/apis/bss/boot/v1/)             |
    | CAPMC                | Yes                 | [https://localhost:8443/apis/capmc/capmc/v1/](https://localhost:8443/apis/capmc/capmc/v1/)       |
    | Collector Ingress    | No                  | [https://localhost:8443/apis/collector-ingress/](https://localhost:8443/apis/collector-ingress/) |
    | Collector Poll       | No                  | [https://localhost:8443/apis/collector-poll/](https://localhost:8443/apis/collector-poll/)       |
    | FAS                  | Yes                 | [https://localhost:8443/apis/fas/v1/](https://localhost:8443/apis/fas/v1/)                       |
    | HSM                  | Yes                 | [https://localhost:8443//apis/smd/hsm/v2/](https://localhost:8443//apis/smd/hsm/v2/)             |
    | REDS                 | Yes                 | [https://localhost:8443/apis/reds/v1/](https://localhost:8443/apis/reds/v1/)                     |
    | SLS                  | Yes                 | [https://localhost:8443/apis/sls/v1/](https://localhost:8443/apis/sls/v1/)                       |
    | RIE Redfish Instance | No                  | [https://localhost:8443/BMC_XNAME/redfish/v1/](https://localhost:8443/BMC_XNAME/redfish/v1/)     |
    > The paths under `/api` are meant to match a production deployment of the HMS Services, with the exception of the collector. The collector is not normally accessible via the NMN or CMN Istio API gateways on a production system, only the HMN Istio API Gateway. For developer, convenience the the API endpoints for the Ingress and Poll instances of the collector have been added.
    
1.  Teardown the simulation environment:
    ```bash
    docker compose down --remove-orphans
    ```

## Use cases
### Update HMS service image.

1. Update `docker-compose.yaml` to specify a different container image version.

1. Use docker compose to re-create the service with the new image. Remove the `-d` flag if you want to have the service run in the foreground. 
    ```bash
    docker compose up --force-recreate --no-deps -d cray-fas
    ```

### Run CT tests against the environment.
> **Warning** The following steps are based off of the steps to run Smoke and Tavern tests written for this repo. 
> These steps should be applicable to run Smoke and Tavern tests from other HMS services against the simulation environment. Though the arguments may need to be updated for the tests to work.

1. Build image:

    ```bash
    docker build ./tests/ct -t hse-test:local 
    ```

1. Smoke test 
    ```bash
    docker run --rm -it --network hms-simulation-environment_simulation hse-test:local smoke -f smoke-api-gateway-services.json
    ```

1. Tavern Tests:
    ```bash
    docker run --rm -it --network hms-simulation-environment_simulation hse-test:local tavern -c /src/app/tavern_global_config_ct_test.yaml -p /src/app/integration
    ```    

### Access Redfish on a simulated BMC.
The API gateway also proxies accesses to the Redfish API on each of the BMCs: 

```bash
curl -k https://localhost:8443/BMC_XNAME/redfish/v1/
```

### Verify discovery status of hardware with the `verify_hsm_discovery.py` script:

```bash
./verify_hsm_discovery.py
```

Example output:
```
HSM Cabinet Summary
===================
x3000 (River)
    Discovered Nodes:          13 (10 Mgmt, 2 Application, 1 Compute)
    Discovered Node BMCs:      13
    Discovered Router BMCs:     2
    Discovered Chassis BMCs:    0
    Discovered Cab PDU Ctlrs:   0
x9000 (Hill)
    Discovered Nodes:          64
    Discovered Node BMCs:      32
    Discovered Router BMCs:    16
    Discovered Chassis BMCs:    2

River Cabinet Checks
====================
x3000
    Nodes: PASS
    NodeBMCs: WARNING
    - x3000c0s1b0 - No mgmt port connection; BMC of mgmt node ncn-m001.
    RouterBMCs: PASS
    ChassisBMCs/CMCs: PASS
    CabinetPDUControllers: WARNING
    - x3000m1 - Not found in HSM Components; Not found in HSM Redfish Endpoints.
    - x3000m0 - Not found in HSM Components; Not found in HSM Redfish Endpoints.

Mountain/Hill Cabinet Checks
============================
x9000 (Hill)
    ChassisBMCs: PASS
    Nodes: PASS
    NodeBMCs: PASS
    RouterBMCs: PASS
```

### Power on a node off and on with the Cray CLI
```bash
# Check the current power state
cray capmc get_xname_status create --xnames 'x1000c0s0b[0-1]n[0-1]'
cray hsm state components list --type Node --format json | jq

# Use CAPMC to power off the node
cray capmc xname_off create --xnames 'x1000c0s0b[0-1]n[0-1]'

# Check HSM to see the power state change to off
cray hsm state components list --type Node --format json | jq

# Use CAPMC to power on the node backup
cray capmc xname_on create --xnames 'x1000c0s0b[0-1]n[0-1]'

# Check HSM to see the power state change to on
cray hsm state components list --type Node --format json | jq
```

## Troubleshooting
### View redfish event subscriptions on a BMC:
```bash
curl -k https://localhost:8443/x1000c0b0/redfish/v1/EventService/Subscriptions
```

### Updating NGINX API gateway configuration:
1. Edit configuration files under `configs/nginx`
2. Restart NGINX
    ```bash
    docker compose restart api-gateway
    ```

### Redfish event troubleshooting:
1. View Redfish events received in Kafka
    ```bash
    docker compose exec -it cray-shared-kafka bash
    kafka-console-consumer --bootstrap-server cray-shared-kafka:9092  --topic cray-dmtf-resource-event --from-beginning
    ``` 

2. Sent a test event:
    ```bash
    curl -i -k -X POST https://localhost:8443/apis/collector-ingress/ -d '{
        "Context": "bar",
        "Events": [{
            "EventId": "0000001",
            "EventTimestamp": "2022-09-22T13:15:05-05:00",
            "Severity": "OK",
            "Message": "The power state of resource /foo has changed to type Off.",
            "MessageId": "CrayAlerts.1.0.ResourcePowerStateChanged",
            "MessageArgs": ["/foo", "Off"],
            "OriginOfCondition": "/foo"
        }],
        "Events@odata.count": 1
    }'
    ```

### Log into a RIE simulated BMC:
```bash
docker compose exec -it x1000c0s0b0 sh 
```
