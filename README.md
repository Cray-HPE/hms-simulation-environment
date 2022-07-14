# hms-simulation-environment

## Usage
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

2.  Install docker-compose version 2.6.1 or greater.

3.  Generate files require for simulation from a SLS file:
    > There are a few different example SLS files in the `configs/sls` directory.

    ```bash
    ./gen_hardware_config_files.py configs/sls/EX2000_River.json
    ```

    Expected Output
    ```text
    Writing docker-compose.hardware.yaml...
    Writing configs/portNumberMap.json...
    Writing configs/portMap.json...
    Writing configs/macPortMap.json...
    Writing configs/seed_ethernet_interfaces.json...
    ```

4.  Stop any perviously running containers:
    ```bash
    docker-compose down --remove-orphans
    ```

5.  In a **different terminal** standup the simulated BMCs and a partial HMS software stack:

    ```bash
    docker-compose -f docker-compose.yaml -f docker-compose.hardware.yaml up 
    ```

6.  Wait for all of the containers to launch and become ready.

7.  Load in seed data in HSM and SLS:

    1.  Load the seed ethernet interface data in HSM:
        ```bash
        ./load_ethernet_interfaces.sh configs/seed_ethernet_interfaces.json  
        ``` 
    
    2.  Load SLS with the SLS state file that was used to generate the configuration files:
        ```bash
        ./load_sls.sh configs/sls/EX2000_River.json
        ```

8.  Run the hms-discovery cronjob:
    ```bash
    docker-compose -f docker-compose.hms-discovery-cronjob.yaml up
    ```

9.  Verify discovery status of hardware:
    
    1.  Overall discovery status:
        ```bash
        curl -s http://localhost:27779/hsm/v1/Inventory/RedfishEndpoints | jq '.RedfishEndpoints[].DiscoveryInfo.LastDiscoveryStatus' | sort | uniq -c
        ```

        Expected output:
        ```text
        65 "DiscoverOK"
        ```


    1. Run the `verify_hsm_discovery.py` script:

        ```bash
        ./verify_hsm_discovery.py
        ```

        Expected output:
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

1.  Clean up:
    ```bash
    docker-compose down --remove-orphans
    ```