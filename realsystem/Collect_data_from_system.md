# Collection data from system
1.  Create a Python virtual environment and install required dependencies:
    1.  Create virtual environment:
        ```bash
        python3 -m venv venv
        . venv/bin/activate
        ```
   
    2.  Install dependencies:
        ```bash
        pip install -r requirements.txt
        ```

1. Collect data from the system.
    > TODO the script could be made to run locally and copy stuff over.
   1. Copy the `collect.sh` script out to the system
   2. Run the `collect.sh` script
   3. Copy the `$SYSTEM_NAME.tgz` tarball off the system

2. Extract the copied over data
    ```
    cd ./realsystem/data
    tar -xvf surtur.tgz 
    cd ../../
    ```

    ```
    $ ls -1 surtur 
    bss-bootparameters.json
    sls-dumpstate.json
    smd.sql
    ```

3.  Generate files require for simulation from a SLS file:
    > There are a few different example SLS files in the `configs/sls` directory.

    ```bash
    ./gen_hardware_config_files.py configs/sls/EX2000_River.json
    ```

3.  **SKIP**  Generate files require for simulation from a SLS file:

    ```bash
    ./gen_hardware_config_files.py realsystem/data/surtur/sls-dumpstate.json
    ```

4.  Stop any perviously running containers:
    ```bash
    docker-compose down --remove-orphans
    ```

1.  Modify docker-compose file to load data from HSM

    ```bash
    yq -i e '.services.cray-smd-init.command = "/data/fill-smd-db.sh && /entrypoint.sh smd-init"' docker-compose.yaml
    yq -i e '.services.cray-smd-init.volumes[0] = "./realsystem/data:/data"' docker-compose.yaml
    cp realsystem/data/surtur/smd.sql realsystem/data
    ```

5.  In a **different terminal** standup the simulated BMCs and a partial HMS software stack:

    **TODO** hardware is not being used at the moment

    ```bash
    docker-compose -f docker-compose.yaml up 
    ```

6. Load date into SLS:

    ```bash
    ./load_sls.sh realsystem/data/surtur/sls-dumpstate.json
    ```

7. Load data into BSS:

    ```bash
    ./load_bss_bootparameters.sh -u http://localhost:27778/boot/v1/bootparameters -f realsystem/data/surtur/bss-bootparameters.json
    ```

8. Start fake kea:

    ```
    pip3 install flask
    python3 ./realsystem/fake_kea.py
    ```

## NCN testing
```
cd ./scripts/operations/node_management/Add_Remove_Replace_NCNs

python3 -m venv venv
./venv/bin/activate

pip install requests netaddr==0.7.19 requests==2.24.0 jsonschema==3.2.0
```

```
(venv) [~/Documents/Github/docs-csm-csm-temp/scripts/operations/node_management/Add_Remove_Replace_NCNs]$ ./ncn_status.py --all -t                                                         *[CASMINST-5299-1.3]
first_master_hostname: ncn-m002
ncns:
    ncn-m001 x3000c0s1b0n0 master
    ncn-m002 x3000c0s2b0n0 master
    ncn-m003 x3000c0s3b0n0 master
    ncn-w001 x3000c0s4b0n0 worker
    ncn-w002 x3000c0s5b0n0 worker
    ncn-w003 x3000c0s6b0n0 worker
    ncn-w004 x3000c0s30b0n0 worker
    ncn-s001 x3000c0s7b0n0 storage
    ncn-s002 x3000c0s8b0n0 storage
    ncn-s003 x3000c0s9b0n0 storage
```

```
(venv) [~/Documents/Github/docs-csm-csm-temp/scripts/operations/node_management/Add_Remove_Replace_NCNs]$ ./ncn_status.py --xname  x3000c0s30b0n0 -t
x3000c0s30b0:
    xname: x3000c0s30b0
    type: NodeBMC, , 
    sources: bss, hsm
    connectors: x3000c0w14j45
    ip_reservations: 10.254.1.21
    ip_reservations_name: ncn-w004-mgmt
    ip_reservations_mac: b4:7a:f1:c2:12:a8
    redfish_endpoint_enabled: True
    ifnames: 
x3000c0w14j45:
    xname: x3000c0w14j45
    type: MgmtSwitchConnector, , 
    sources: sls
    ifnames: 
x3000c0s30e0:
    xname: x3000c0s30e0
    type: NodeEnclosure, , 
    sources: hsm
    ifnames: 
x3000c0s30b0n0:
    xname: x3000c0s30b0n0
    name: ncn-w004
    parent: x3000c0s30b0
    type: Node, Management, Worker
    sources: bss, hsm, sls
    ip_reservations: 10.1.1.11, 10.103.11.143, 10.103.11.201, 10.103.11.28, 10.252.1.13, 10.254.1.22
    ip_reservations_name: ncn-w004-mtl, ncn-w004-can, ncn-w004-chn, ncn-w004-cmn, ncn-w004-nmn, ncn-w004-hmn
    ip_reservations_mac: 14:02:ec:e1:bd:a8, 14:02:ec:e1:bd:a8, , , 14:02:ec:e1:bd:a8, 14:02:ec:e1:bd:a8
    ifnames: mgmt0:14:02:ec:e1:bd:a8, mgmt1:14:02:ec:e1:bd:a9, hsn0:88:e9:a4:02:94:14, hsn1:88:e9:a4:02:84:cc
ncn_macs:
    ifnames: mgmt0:14:02:ec:e1:bd:a8, mgmt1:14:02:ec:e1:bd:a9, hsn0:88:e9:a4:02:94:14, hsn1:88:e9:a4:02:84:cc
    bmc_mac: # Unknown. To get this value set the environment variable, IPMI_PASSWORD, with the password for the BMC
```

```
./remove_management_ncn.py --xname x3000c0s30b0n0 --test-urls --skip-kea --skip-etc-hosts
```


```
./add_management_ncn.py allocate-ips --xname x3000c0s30b0n0 --alias ncn-w004 \
    --url-bss http://localhost:27778/boot/v1 \
    --url-hsm http://localhost:27779/hsm/v2 \
    --url-sls http://localhost:8376/v1 \
    --url-kea http://localhost:8090/api \
    --skip-etc-hosts
```

```
./add_management_ncn.py ncn-data \
    --xname x3000c0s30b0n0 \
    --alias ncn-w004 \
    --mac-mgmt0 14:02:ec:e1:bd:a8 \
    --mac-mgmt1 14:02:ec:e1:bd:a9 \
    --mac-hsn0 88:e9:a4:02:94:14 \
    --mac-hsn1 88:e9:a4:02:84:cc \
    --mac-bmc b4:7a:f1:c2:12:a8 \
    --bmc-mgmt-switch-connector x3000c0w14j45 \
    --url-bss http://localhost:27778/boot/v1 \
    --url-hsm http://localhost:27779/hsm/v2 \
    --url-sls http://localhost:8376/v1  \
    --url-kea http://localhost:8090/api
```