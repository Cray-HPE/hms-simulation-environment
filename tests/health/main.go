package main

import (
	"log"
	"time"

	securestorage "github.com/Cray-HPE/hms-securestorage"
)

func main() {
	var secureStorage securestorage.SecureStorage

	// Setup Vault. It's kind of a big deal, so we'll wait forever for this to work.
	log.Println("Connecting to Vault...")
	for {
		var err error
		// Start a connection to Vault
		if secureStorage, err = securestorage.NewVaultAdapter("secret"); err != nil {
			log.Printf("Unable to connect to Vault (%s)...trying again in 5 seconds.\n", err)
			time.Sleep(5 * time.Second)
		} else {
			log.Println("Connected to Vault.")
			break
		}
	}

	for {
		time.Sleep(time.Second)

		var result map[string]interface{}
		if err := secureStorage.Lookup("meds-cred/global/ipmi", &result); err != nil {
			log.Println("Error: ", err)
			continue
		}

		if _, ok := result["Password"]; ok {
			result["Password"] = "Redacted"
		}

		log.Println(result)
	}
}
