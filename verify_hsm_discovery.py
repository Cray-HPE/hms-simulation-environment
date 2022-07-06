#!/usr/bin/env python3

# MIT License
#
# (C) Copyright [2021-2022] Hewlett Packard Enterprise Development LP
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



import json
from base64 import b64decode
import requests
from kubernetes import client, config

##############################################################################
# Generate per-cabinet details containing info on nodes, NodeBMCs, RouterBMCs,
# CabinetPDUControllers.   A Higher level func will do these by type -- river,
# and hill/mountain.   This func will print FAIL/PASS/WARNING as needed along
# with relevant data, and of: "Not present in HSM State Components"
#                             "Not Present in HSM RedfishEndpoints"
#                             "No mgmt port association"

# Each mountain cabinet has 8 ChassisBMC. It is expected that all 8 are
# discovered. (pass/fail)
# Each hill cabinet has 2 ChassisBMCs (c1 and c3), It is expected that both are
# discovered. (pass/fail)

# For each River Cabinet provide a summary of the number of Management NCNs,
# Application, and Compute nodes in each cabinet

# For each River BMC/Component in SLS verify that it exists under
# RedfishEndpoints and State Components in HSM

# For RouterBMCs/NodeBMCs/Nodes this can be made PASS/FAIL

# For the Master Management NCNs it is acceptable to that 1 of them has a BMC
# not connected to the HMN. Provide an information message for the master NCN
# BMCs that are not connected to the HMN, also provide the alias of the nodes.

# For CMCs if they are missing should be a warning
# Intel CMCs are not expected to be discovered

# For CabinetPDUControllers this should be made a Warning
# HPE PDUs are not expected to be discovered
##############################################################################


# Data structure to contain cabinet info.

class CabInfo():
	def __init__(self, xn, xc):
		self.xname = xn
		self.xclass = xc

# Create a k8s client object for use in getting auth tokena.

def getK8sClient():
	config.load_kube_config()
	k8sClient = client.CoreV1Api()
	return k8sClient

# Fetch auth token for HMS REST API calls.

def getAuthenticationToken():
	URL = "https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token"

	kSecret = getK8sClient().read_namespaced_secret("admin-client-auth", "default")
	secret = b64decode(kSecret.data['client-secret']).decode("utf-8")

	DATA = {
		"grant_type": "client_credentials",
		"client_id": "admin-client",
		"client_secret": secret
	}

	try:
		r = requests.post(url=URL, data=DATA)
	except OSError:
		return ""

	result = json.loads(r.text)
	return result['access_token']

# Func to get a JSON payload from a URL.  It's assumed to be a full URL.
# Also note that we'll only ever be contacting HMS services.

def doRest(uri, authToken):
	getHeaders = {'Authorization': 'Bearer %s' % authToken,}
	r = requests.get(url=uri, headers=getHeaders)
	retJSON = r.text

	if r.status_code >= 300:
		ret = 1
	else:
		ret = 0

	return retJSON, ret


# Get HSM component data

def getHSMComponents(authToken):
	# url = "https://api-gw-service-nmn.local/apis/smd/hsm/v1/State/Components"
	url = "http://localhost:27779/hsm/v1/State/Components"
	compsJSON, rstat = doRest(url, authToken)
	return compsJSON, rstat



# Get HSM RFEP data

def getHSMRFEP(authToken):
	# url = "https://api-gw-service-nmn.local/apis/smd/hsm/v1/Inventory/RedfishEndpoints"
	url = "http://localhost:27779/hsm/v1/Inventory/RedfishEndpoints"
	rfepJSON, rstat = doRest(url, authToken)
	return rfepJSON, rstat


# Get SLS HW data

def getSLSHWData(authToken):
	# url = "https://api-gw-service-nmn.local/apis/sls/v1/hardware"
	url = "http://localhost:8376/v1/hardware"
	slsJSON, rstat = doRest(url, authToken)
	return slsJSON, rstat


# Returns a list of cabinets and their type (RV,MT,HILL).
# This is taken from the SLS data.

def getCabList(slsJSON):
	cabList = []

	j = json.loads(slsJSON)

	for comp in j:
		if comp['TypeString'] == "Cabinet":
			cabList.append(CabInfo(comp['Xname'], comp['Class']))

	return cabList


# Given a BMC, return a list of connected mgmt port NICs.

def findNodeNics(bmc, slsJSON):
	nics = []
	for comp in slsJSON:
		if not "ExtraProperties" in comp:
			continue

		if not "NodeNics" in comp['ExtraProperties']:
			continue

		for nic in comp['ExtraProperties']['NodeNics']:
			if nic == bmc:
				nics.append(comp['Xname'])

	return nics


# Convenience function, checks SLS components to see if they are present in
# HSM component data, HSM RedfishEndpoint data, and if there is a mgmt port
# associated with it in SLS.  Returns a message with relevant info.

def doChecks(xclass, comp, bname, ctype, compJSON, rfepJSON, slsJSON):
	noc = ""

	# Check state components presence
	flds = compJSON['Components']
	filtered = list(filter(lambda f: (f['ID'] == bname), flds))
	if not filtered:
		noc = "Not found in HSM Components"

	# Check RF Endpoints presence
	flds = rfepJSON['RedfishEndpoints']
	filtered = list(filter(lambda f: (f['ID'] == bname), flds))
	if not filtered:
		if len(noc) > 0:
			noc += "; "
		noc += "Not found in HSM Redfish Endpoints"

	if xclass == "River":
		# Check mgmt port connection
		filtered = findNodeNics(bname, slsJSON)
		if not filtered:
			if len(noc) > 0:
				noc += "; "
			noc += "No mgmt port connection"
			if ctype == "NodeBMC":
				# Check if this is a mgmt NCN, if so, print alias.  This is
				# determined by looking at the Role -- look for Management.
				# Then, grab the ExtraProperties/Aliases.
				if comp['ExtraProperties']['Role'] == "Management":
					noc += "; BMC of mgmt node " + comp['ExtraProperties']['Aliases'][0]

	return noc


# Generate a per-cabinet summary containing numbers of nodes, BMCs, etc.
# This needs to be gotten from HSM component data.  TODO: should we be using
# the RF endpoints instead?

def genSummary(slsData, compData):
	cabList = getCabList(slsData)
	# Sort by cab num
	clSorted = sorted(cabList, key=lambda cab: cab.xname)

	print("HSM Cabinet Summary")
	print("===================")

	cdata = json.loads(compData)

	for cab in clSorted:
		nodes = 0
		nodebmcs = 0
		rtrbmcs = 0
		chassisbmcs = 0
		cabpducontrollers = 0
		appNodes = 0
		mgmtNodes = 0
		compNodes = 0

		for comp in cdata['Components']:
			if not comp['ID'].startswith(cab.xname):
				continue

			ctype = comp['Type']
			if ctype == "Node":
				nodes += 1
				if comp['Role'] == "Compute":
					compNodes += 1
				elif comp['Role'] == "Management":
					mgmtNodes += 1
				elif comp['Role'] == "Application":
					appNodes += 1
			elif ctype == "NodeBMC":
				nodebmcs += 1
			elif ctype == "RouterBMC":
				rtrbmcs += 1
			elif ctype == "ChassisBMC":
				chassisbmcs += 1
			elif ctype == "CabinetPDUController":
				cabpducontrollers += 1

		print("%s (%s)" % (cab.xname, cab.xclass))
		if cab.xclass == "River":
			print("  Discovered Nodes:         %3d (%d Mgmt, %d Application, %d Compute)" %
				(nodes, mgmtNodes, appNodes, compNodes))
		else:
			print("  Discovered Nodes:         %3d" % (nodes))

		print("  Discovered Node BMCs:     %3d" % (nodebmcs))
		print("  Discovered Router BMCs:   %3d" % (rtrbmcs))
		print("  Discovered Chassis BMCs:  %3d" % (chassisbmcs))
		if cab.xclass == "River":
			print("  Discovered Cab PDU Ctlrs: %3d" % (cabpducontrollers))

	print("")


# Generate River cabinet detailed report.

def genRiverDetails(slsData, compData, rfepData):
	numErrs = 0

	slsJSON = json.loads(slsData)
	compJSON = json.loads(compData)
	rfepJSON = json.loads(rfepData)

	cabList = getCabList(slsData)
	# Sort by cab num
	clSorted = sorted(cabList, key=lambda cab: cab.xname)

	print("River Cabinet Checks")
	print("====================")

	for cab in clSorted:
		errs = []

		# For each cab, filter for river class, ignore mountain/hill.
		if cab.xclass != "River":
			continue

		print("%s" % (cab.xname))

		# Iterate all nodes in SLS.  Check for not present in comps/rfeps,
		# mgmt ports.  Any missing/mismatch is a FAIL.

		nodes = list(filter(lambda f: (f['TypeString'] == "Node"), slsJSON))
		for comp in nodes:
			if not comp['Xname'].startswith(cab.xname):
				continue

			flds = compJSON['Components']
			filtered = list(filter(lambda f: (f['ID'] == comp['Xname']), flds))
			if not filtered:
				# Not all river nodes have NIDs, so check for that.
				nidStr = "N/A"
				if "NID" in comp['ExtraProperties']:
					nidStr = "%d" % (comp['ExtraProperties']['NID'])

				errs.append("- %s (%s, NID %s) - Not found in HSM Components." %
					(comp['Xname'], comp['ExtraProperties']['Role'], nidStr))

		# Print out the node info.
		if not errs:
			print("  Nodes: PASS")
		else:
			numErrs += 1
			print("  Nodes: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))


		# Iterate NodeBMCs in SLS.  This is tricky, the SLS data doesn't have
		# node BMCs, need to infer them from the nodes using the Parent field.
		# Check for presence in comps/RFEPs and mgmt ports, mismatches == FAIL.
		# If no mgmt port, check if it's a mgmt NCN and if so, report it as
		# info.

		errs = []
		warns = []
		mappedComps = {}

		for comp in nodes:
			if not comp['Xname'].startswith(cab.xname):
				continue

			bname = comp['Parent']
			if bname in mappedComps:
				continue

			mappedComps[bname] = True
			noc = doChecks(cab.xclass, comp, bname, "NodeBMC", compJSON, rfepJSON, slsJSON)

			if len(noc) > 0:
				if "BMC of mgmt node" in noc:
					warns.append("- %s - %s." % (bname, noc))
				else:
					errs.append("- %s - %s." % (bname, noc))

		# Print out the Node BMC info.
		if len(errs) > 0:
			numErrs += 1
			print("  NodeBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))

		if len(warns) > 0:
			print("  NodeBMCs: WARNING")
			for emsg in warns:
				print("    %s" % (emsg))

		if not errs and not warns:
			print("  NodeBMCs: PASS")


		# Iterate RouterBMCs in SLS.  Easy since SLS data contains these
		# directly.  Check for comps/RFEP/mgmt ports.  Mismatches == FAIL.

		errs = []

		rtrs = list(filter(lambda f: (f['TypeString'] == "RouterBMC"), slsJSON))
		for comp in rtrs:
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = doChecks(cab.xclass, comp, bname, "RouterBMC", compJSON, rfepJSON, slsJSON)

			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Node BMC info.
		if not errs:
			print("  RouterBMCs: PASS")
		else:
			numErrs += 1
			print("  RouterBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))


		# Iterate ChassisBMCs in SLS.  These are really GB CMCs.

		errs = []

		rtrs = list(filter(lambda f: (f['TypeString'] == "ChassisBMC"), slsJSON))
		for comp in rtrs:
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = doChecks(cab.xclass, comp, bname, "ChassisBMC", compJSON, rfepJSON, slsJSON)

			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Node BMC info.
		if not errs:
			print("  ChassisBMCs/CMCs: PASS")
		else:
			numErrs += 1
			print("  ChassisBMCs/CMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))


		# Check CabPDUControllers in SLS.  Check comps/RFEP.  Mgmt port?
		# Mismatches are WARNING.

		errs = []

		pdus = list(filter(lambda f: (f['TypeString'] == "CabinetPDUController"), slsJSON))
		for comp in pdus:
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = doChecks(cab.xclass, comp, bname, "CabinetPDUController", compJSON, rfepJSON, slsJSON)
			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Node BMC info.
		if not errs:
			print("  CabinetPDUControllers: PASS")
		else:
			print("  CabinetPDUControllers: WARNING")
			for emsg in errs:
				print("    %s" % (emsg))



	print("")
	return numErrs


# Generate Mountain/Hill cabinet detailed report.

def genMountainDetails(slsData, compData, rfepData):
	numErrs = 0

	slsJSON = json.loads(slsData)
	compJSON = json.loads(compData)
	rfepJSON = json.loads(rfepData)

	cabList = getCabList(slsData)
	# Sort by cab num
	clSorted = sorted(cabList, key=lambda cab: cab.xname)

	print("Mountain/Hill Cabinet Checks")
	print("============================")

	numCabs = 0

	for cab in clSorted:
		# For each cab, filter for river class, ignore mountain/hill.
		if cab.xclass == "River":
			continue

		numCabs += 1
		print("%s (%s)" % (cab.xname, cab.xclass))


		# Check ChassisBMCs.  All 8 must be present in each cabinet for
		# Mountain, c1 and c3 must be present for Hill.  NOTE!!!  It is assumed
		# that the SLS data contains all requisite ChassisBMCs and this app
		# does not have to verify the counts or e.g. that c1 and c3 are both
		# present in SLS for Hill.

		errs = []
		nodes = list(filter(lambda f: (f['TypeString'] == "ChassisBMC"), slsJSON))
		for comp in nodes:
			# ChassisBMC names in SLS and HSM components don't have the 'bX'
			# suffix, but they do in the RFEP data.  Yuck, can't use the
			# convenience func...
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = ""

			# Check state components presence
			flds = compJSON['Components']
			filtered = list(filter(lambda f: (f['ID'] == bname), flds))
			if not filtered:
				noc = "Not found in HSM Components"

			# Check RF Endpoints presence
			flds = rfepJSON['RedfishEndpoints']
			filtered = list(filter(lambda f: (f['ID'] == bname), flds))
			if not filtered:
				if len(noc) > 0:
					noc += "; "
				noc += "Not found in HSM Redfish Endpoints"


			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Chassis BMC info.
		if not errs:
			print("  ChassisBMCs: PASS")
		else:
			numErrs += 1
			print("  ChassisBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))


		# Check Nodes.  Missing == WARNING.

		# Iterate all nodes in SLS.  Check for not present in comps/rfeps,
		# mgmt ports.  Any missing/mismatch is a FAIL.

		errs = []
		nodes = list(filter(lambda f: (f['TypeString'] == "Node"), slsJSON))
		for comp in nodes:
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			flds = compJSON['Components']
			filtered = list(filter(lambda f: (f['ID'] == comp['Xname']), flds))
			if not filtered:
				errs.append("- %s (%s, NID %d) - Not found in HSM Components." %
					(comp['Xname'], comp['ExtraProperties']['Role'],
					comp['ExtraProperties']['NID']))

		# Print out the node info.
		if not errs:
			print("  Nodes: PASS")
		else:
			print("  Nodes: WARNING")
			for emsg in errs:
				print("    %s" % (emsg))


		# Check NodeBMCs.  Missing == WARNING.  This is tricky, the SLS data
		# doesn't have node BMCs, need to infer them from the nodes using the
		# Parent field.  Check for presence in comps/RFEPs and mgmt ports,
		# mismatches == WARNING.
		# if so, report it as info.

		errs = []
		mappedComps = {}

		for comp in nodes:
			if not comp['Xname'].startswith(cab.xname):
				continue

			bname = comp['Parent']
			if bname in mappedComps:
				continue

			mappedComps[bname] = True
			noc = doChecks(cab.xclass, comp, bname, "NodeBMC", compJSON, rfepJSON, slsJSON)

			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Node BMC info.
		if not errs:
			print("  NodeBMCs: PASS")
		else:
			print("  NodeBMCs: WARNING")
			for emsg in errs:
				print("    %s" % (emsg))


		# Check RouterBMCs.  Missing == WARNING.

		errs = []
		nodes = list(filter(lambda f: (f['TypeString'] == "RouterBMC"), slsJSON))
		for comp in nodes:
			bname = comp['Xname']
			if not bname.startswith(cab.xname):
				continue

			noc = doChecks(cab.xclass, comp, bname, "RouterBMC", compJSON, rfepJSON, slsJSON)
			if len(noc) > 0:
				errs.append("- %s - %s." % (bname, noc))

		# Print out the Chassis BMC info.
		if not errs:
			print("  RouterBMCs: PASS")
		else:
			numErrs += 1
			print("  RouterBMCs: FAIL")
			for emsg in errs:
				print("    %s" % (emsg))

	if numCabs == 0:
		print("None Found.")

	print("")
	return numErrs


# Entry point

def main():
	#authToken = getAuthenticationToken()
	# if authToken == "":
	# 	print("ERROR: No/empty auth token, can't continue.")
	# 	return 1
	authToken = "foo"

	compData, stat = getHSMComponents(authToken)
	if stat != 0:
		print("HSM components returned non-zero.")
		return 1

	rfepData, stat = getHSMRFEP(authToken)
	if stat != 0:
		print("HSM RFEPs returned non-zero.")
		return 1

	slsData, stat = getSLSHWData(authToken)
	if stat != 0:
		print("SLS data returned non-zero.")
		return 1

	genSummary(slsData, compData)
	numErrs =  genRiverDetails(slsData, compData, rfepData)
	numErrs += genMountainDetails(slsData, compData, rfepData)

	if numErrs > 0:
		return 1

	return 0

if __name__ == "__main__":
	ret = main()
	exit(ret)