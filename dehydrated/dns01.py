#!/usr/bin/python3
import sys
import pylibopi as pylibopi
import getopt
import requests

def dprint( msg ):
	if debug:
		print(msg)

def help():
	print('Syntax: dns01.py options command')
	print("  Command is passed to serverside (deploy_challange,clean_challange)")
	print("  Supported options:")
	print('\t-v:\tVerbose, print debug messages')
	print('\t-d:\tDomain to deploy challange for')
	print('\t-t:\tToken/Challange to use')
	print('\t-h:\tPrint this help')

### -------------- MAIN ---------------
if __name__=='__main__':
	debug = False
	authServer = "https://auth.openproducts.com"
	authPath = "/dns01.php"
	domain = ""

	if ( len(sys.argv) < 2):
		# always need a command argument
		print("Missing command argument")
		help()

	try:
		opts, args = getopt.getopt(sys.argv[1:],"vhd:t:")
	except getopt.GetoptError:
		print("\nInvalid options.\n")
		help()
		sys.exit(1)

	for opt, arg in opts:
		if opt == "-v":
			debug = True
		elif opt == "-h":
			help()
			sys.exit(0)
		elif opt == "-t":
			dns01token = arg
		elif opt == "-d":
			domain = arg

	if ( len(args) != 1 ):
		print("Invalid command syntax")
		help()
		sys.exit(1)
	else:
		dns01cmd = args[0]

	dprint("Command set to %s" % dns01cmd)

	try:
		dprint("Token: '%s'" % dns01token)
	except:
		print("Missing arguments for '%s'" % dns01cmd)

	
	ca = pylibopi.GetKeyAsString("hostinfo","cafile")
	postargs = {}
	postheaders = {}
	postargs["dns-01-token"] = dns01token
	postargs["dns-01-cmd"] = dns01cmd

	if domain:
		# override config file with cmd arg.
		postargs["fqdn"] = domain
	else:
		try:
			postargs["fqdn"] = pylibopi.GetKeyAsString("hostinfo","hostname")+"."+pylibopi.GetKeyAsString("hostinfo","domain")
		except ValueError:
			print("No domain specified / avaialble")
			sys.exit(1)

	try:
		postargs["unit_id"] = pylibopi.GetKeyAsString("hostinfo","unitid")
		dprint("Trying to get OP login token")
		try:
			authToken=pylibopi.AuthLogin()
		except Exception as e:
			dprint("Failed to get token")
			dprint(e)
			# if a unit id exists, we should get a token.
			sys.exit(1)

		dprint("Token: '%s'" % authToken)
		postheaders = {'token': authToken }
	except ValueError:
		dprint("No unitid available")
	
	authUrl = authServer + authPath
	dprint("Using url: '%s'" % authUrl)

	r = requests.post(authUrl, headers=postheaders, data=postargs, verify=ca)