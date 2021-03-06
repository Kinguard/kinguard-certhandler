#!/bin/bash
function debug {
	if [ $VERBOSE ]; then
		args=$@
		logger "CertHandler: $args"
		echo $args
	fi
}

function usage {
	echo "Use '${ME} [-cfrsv] [-d domain]"
	echo "  -a 			: Stand alone, will launch and shut down nginx"
	echo "  -c 			: tries to retreive/update a Let's Encrypt certificate"
	echo "       		  for the name stated in sysinfo.conf"
	echo "  -f 			: same as '-c' but also forces a renewal of the certificate"
	echo "       		  even if it has not expired"
	echo "  -d domain	: Create the certificate for 'domain' instade of what is in the sysinfo.conf"
	echo "  -r 			: Removes the Let's Encrypt certificate and restores default config"	
	echo "  -s 			: Use Let's Encrypt staging servers,"
	echo "        		  working but not signed certificates will be generated"
	echo "  -v 			: Makes the script talk back"
	echo ""
}

function getargs {
	QUIET=" -q"
	while getopts "acd:frsv" OPTION; do
		case "$OPTION" in
		a)
			STANDALONE="true"
			;;
		c)
			CMD="create"
			;;
		d)
			DOMAIN=$OPTARG
			debug "Setting domain to ${DOMAIN}"
			;;
		f)
			CMD="force"
			;;
		r)
			CMD="revoke"
			;;
		s)
			CONFIG="-f ${DIR}/dehydrated/staging-config"
			;;
		v)
			VERBOSE=true
			QUIET=""
			;;
		*)
			usage #print help message
			exit 0
			;;
		esac
	done

}

function create_configs {
	local OC_WELLKNOWN="/usr/share/opi-control/web/.well-known" # well-known path for opi-control
	local WEB_TARGET=$(dirname ${WELLKNOWN})
	
	# check to see that a symlink to "well-known" exists from opi-control dir
	if [ ! -L "$OC_WELLKNOWN" ]; then
		debug "Creating symlink for opi-control use"
		mkdir -p $(dirname ${OC_WELLKNOWN})
		ln -s ${WEB_TARGET} ${OC_WELLKNOWN}
	fi

}

function restore_configs {
	ORG_CERT=$(kgp-sysinfo -c webcertificate -k defaultcert -p)
	ORG_KEY=$(kgp-sysinfo -c webcertificate -k defaultkey -p)

	rm -f ${CERT}
	ln -s ${ORG_CERT} ${CERT}
	rm -f ${KEY}		
	ln -s ${ORG_KEY} ${KEY}
}

function nginx_restart {
	local status
	debug "Check nginx config"
	# do not exit on failure here
	set +e
	nginx -t &> /dev/null
	status=$?
	if [ $status -ne 0 ]; then
		debug "Nginx config error, not restarting"
		return 1
		# can't set "-e" here, then it would terminate script when returning "1"
	fi
	if [ "$webserver" != "nginx" ]; then
		# do not restart nginx if it was not used
		return 0
	fi
	set -e
	service nginx status &> /dev/null 
	if [ $? -ne 0 ]; then
		logger "Kinguard Certhandler: (Re)starting webserver"
		debug "(Re)starting webserver"
		service nginx restart &> /dev/null 
	else
		logger "Kinguard Certhandler: Reloading webserver"
		debug "Reloading webserver"
		service nginx reload &> /dev/null 
	fi
	service nginx status &> /dev/null 
	if [ $? -ne 0 ]; then
		debug "Webserver not running after restart command"
		return 1
	else
		return 0
	fi
}

function nginx_stop {
	debug "Stopping webserver"
	logger "Kinguard Certhandler: Stopping webserver"
	service nginx stop &> /dev/null 
}

function is_webserver_running {
	#function will also print which webserver is using the port
	server=$(netstat -tpln | grep -E '(^tcp.*\:443\s|^tcp.*\:80\s)')
	running=$?
	server=$(echo ${server} | sed -n 's%.*\/\([a-z\-]*\).*$%\1%p')
	if [ $running -eq 0 ]; then
		if [ -z "$server" ]; then
			echo="Unknown webserver"
		else
			echo "$server"
		fi
	fi
	return $running
}
	
function run {
	debug "Running script '$@'"
	if [ $VERBOSE ]; then
		$@
	else
		$@ &> /dev/null
	fi
	return $?
}

function dehydrated_env {
	D_CONFIG="$(${SCRIPT} -e ${useDns01} | grep ' WELLKNOWN')"
	WELLKNOWN=$(echo $D_CONFIG | sed -n 's%.*WELLKNOWN=\"\(.*\)\"%\1%p')
	debug "WELLKNOWN: ${WELLKNOWN}"

	# dehydrated reads "CERTDIR" from sysconfig from it's own configs.
	D_CONFIG="$(${SCRIPT} -e ${useDns01} | grep ' CERTDIR')"
	CERTDIR=$(echo $D_CONFIG | sed -n 's%.*CERTDIR=\"\(.*\)\"%\1%p')
	debug "CERTDIR: $CERTDIR"

	CERTLINK="${CERTDIR}/${DOMAIN}/fullchain.pem"
	KEYLINK="${CERTDIR}/${DOMAIN}/privkey.pem"

	debug "CERTLINK: ${CERTLINK}"
	debug "KEYLINK: ${KEYLINK}"
}

function check443 {
	# function to to check if system is accessible from the "outside"

	# generate random string
	alive="/var/www/static/.well-known/alive.txt"
	uuid=$(cat /proc/sys/kernel/random/uuid)
	echo $uuid > $alive
	debug "Writing $uuid to alive.txt"
	status=$(curl -k -o /dev/null --silent --head --write-out '%{http_code}\n' "https://setup.op-i.me/check443.php?fqdn=${DOMAIN}&uuid=${uuid}")
	ret=$?
	debug "check443 exit value: $ret"
	debug "check443 response: $status"
	debug "Removing alive.txt"
	rm -f $alive
	if [[ "$status" -ne 200 ]]; then
		reachable=false
	else
		reachable=true
	fi
}

function exitfail {

	(>&2 echo "CertHander Exit: $1")
	if [[ $webserver_status -ne 0 ]]; then
		# webserver was not running before, lets stop it again
		# opi-c is never started from this script, so only need to shut down nginx
		debug "Webserver was not running when started"
		debug "Make sure it is stopped."
		nginx_stop
	fi
	exit 1
}

function validcertdate {

		# Check if the existing certificate is too old, < 3 days remaining
		# 3days = 259200 secs
		NOW=$(date +%s)
		CERTDATE=$(openssl x509 -text -noout -in $CERT | sed -n 's/\s*Not After :\s*\(.*\)/\1/p')
		debug "Certificate expires on: ${CERTDATE}"
		CERTDATESECS=$(date --date="$CERTDATE" +%s)
		debug "Certificate secs: $CERTDATESECS"

		let DIFF=$CERTDATESECS-$NOW
		debug "DIFF: $DIFF"
		if [ $DIFF -lt 259200 ]; then
			debug "WARNING: Certificate expires within 3 days"
			validcert=false
		else
			validcert=true
		fi
}

function validcertdomain {
	certdomain=$(openssl x509 -text -noout -in $CERT | awk '/Subject:.* CN/ {print $NF}')
	debug "Cert domain: $certdomain"
	if [ "$certdomain" != "$DOMAIN" ]; then
		validcert=false
	else
		validcert=true
	fi

}

## ------------------   Script start ---------------------##

ME=`basename "$0"`
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

VERBOSE=$(kgp-sysinfo -p -c webcertificate -k debug)

enabled=$(kgp-sysinfo -p -c webcertificate -k enabled)
if [[ $? -ne 0 ]]; then
	(>&2 echo "Missing configuration parameter 'enabled'.")
	exit 1
fi

if [[ $enabled -ne 1 ]];then
	(>&2 echo "Service not enabled.")
	exit 0
fi

opi_name=$(kgp-sysinfo -p -c hostinfo -k hostname)
domain=$(kgp-sysinfo -p -c hostinfo -k domain)
BACKEND=$(kgp-sysinfo -p -c webcertificate -k backend)
CERT=$(kgp-sysinfo -p -c webcertificate -k activecert)
KEY=$(kgp-sysinfo -p -c webcertificate -k activekey)

# All config parameters that could fail the script have been read.
# Let script exit on failed sys calls.
set -e

CONFIG="-f ${DIR}/dehydrated/config"


if [ ! -z ${opi_name} ] && [ ! -z ${domain} ] ; then
	DOMAIN="${opi_name}.${domain}"
fi

SCRIPT="${DIR}/dehydrated/dehydrated"


getargs "$@" #get the script arguments

case $BACKEND in
	LETSENCRYPT)
		debug "Using Let's Encrypt backend"
		;;
	CUSTOMCERT)
		debug "Using user defined certificates, nothing to do here"
		exit 0
		;;
	*)
		exitfail "Unknown certificate backend, aborting"
		;;
esac

# check if we have domain control for use with dns-01 challange type
doms=$(kgp-sysinfo -p -c dns -k availabledomains | tr "," "\n") 
for dom in $doms
do
	if [[ ${DOMAIN} == *${dom} ]]; then
		useDns01=" -t dns-01"
		debug "Using dns-01 to challange domain"
	fi
done


if [ "$CMD" = "create" ] || [ "$CMD" = "force" ] || [ "$CMD" = "renew" ]; then

	if [ -z ${DOMAIN} ]; then
		debug "Empty DOMAIN, nothing to do"
		exit 0
	fi

	DOMAIN="$(echo ${DOMAIN} | tr '[:upper:]' '[:lower:]')"  # make lowercase fqdn

	debug "Running Let's Encrypt certificate generation for ${DOMAIN}"
	dehydrated_env	
	create_configs  # generate configuration files if needed

	webserver=$(is_webserver_running)
	webserver_status=$?
	if [ $webserver_status -eq 0 ]; then
		debug "Using $webserver"
	fi


	if [ ! -z "$useDns01" ]; then
		# only request wildcard if we have dns-01 support
		# http-01 does not support wildcard certificat generation.
		OPTIONS="-c -d ${DOMAIN} -d *.${DOMAIN} ${CONFIG} ${useDns01}"
	else
		OPTIONS="-c -d ${DOMAIN} ${CONFIG}"
	fi

	if [ "$CMD" = "force" ]; then
		OPTIONS="$OPTIONS --force"
	fi

	if [ $STANDALONE ]; then
		OPTIONS="$OPTIONS --hook ${DIR}/dehydrated/hooks-standalone.sh"
	fi

	debug "Requesting cert"
	debug "OPTIONS: ${OPTIONS}"


	if [ $STANDALONE ] && [ "${webserver_status}" -ne 0 ]; then
		debug "Standalone mode, starting webserver"
		nginx_restart
	elif [ "${webserver_status}" -ne 0 ]; then
		exitfail "No webserver running and stand-alone not specified, aborting"
	fi

	if [ -z "$useDns01" ]; then
		# check internet access to port 443.
		# check will terminate script if it does not succeed.
	 	check443
	 	if [ $reachable == false ]; then
	 		# check if the domain has changed or if the exiting certificate has expired.
	 		# In this case we need to use the fallback, OP-signed certificate since the LE cert is not valid
	 		# for the configured domain.
	 		debug "Validate certificate name against opiname"
	 		validcert=false
	 		validcertdomain
	 		if [ $validcert == false ]; then
	 			# we have a new domain, but the system is not reachable from the internet
	 			# so not possible to get an LE cert.
	 			# Use fallback with OP cert, but do NOT restart webserver.
	 			# The only way to set a new fqdn is from web UI (using opi-backend), and the browser 
	 			# needs to have the response before restarting webserver, otherwise the response will be
	 			# generated with the new certificate and rejected by the broswer.
	 			# opi-backend will reload webserver when the response has been sent.
	 			debug "Domain has changed, LE not available."
	 			debug "Using OP fallback certificate"
	 			restore_configs
	 			nginx_restart
	 		fi
	 
	 		# check the time remaining on the certificate
	 		debug "Validate certificate expire date"
	 		validcert=false
	 
	 		validcertdate
	 		if [ $validcert == false ]; then
	 			# LE cert should always have more then 30days left, now less then 3
	 			# so use the fallback.
	 			debug "Certificate is too close to (or past) exire date, use fallback."
	 			restore_configs
	 			nginx_restart
	 		else
	 			debug "Certificate has not exipired."
	 		fi
	 
	 		# It the system using a custom certificate?
	 		currentcertpath=$(realpath $CERT)
	 		customcertpath=$(kgp-sysinfo -c webcertificate -k customcert -p)
	 		if [ "$currentcertpath" == "$customcertpath" ]; then
	 			debug "System is configured for LE cert but a custom cert is active, restore default."
	 			restore_configs
	 			nginx_restart
	 		fi
	 		exitfail "System not reachable from internet. Skipping LE generation."
	 	fi
	fi	
	# check if we have an account
	set +e  # allow fail here
	find ${DIR}/dehydrated/accounts/ -name registration_info.json -exec grep "Status" {} \; | grep -q "valid"
	valid_account=$?
	set -e
	
	if [[ $valid_account -ne 0 ]]; then
		debug "Creating account"
		CREATE_OPTIONS="${CONFIG} --register --accept-terms"
		run ${SCRIPT} ${CREATE_OPTIONS}
		
	else
		debug "Found existing account"
	fi
	
	run ${SCRIPT} ${OPTIONS}
	
	script_res=$?
	debug "Cert script returned ${script_res}"

	if [ $script_res -eq 0 ]; then

		if [ $webserver_status -ne 0 ]; then
			# webserver was not running before, lets stop it again
			debug "Standalone mode, stopping webserver"
			nginx_stop
		fi
		
		#clean up unused certs
		if [ ! -z "$useDns01" ]; then
			OPTIONS="--cleanup -d ${DOMAIN} -d *.${DOMAIN} ${useDns01} ${CONFIG}"
		else
			OPTIONS="--cleanup -d ${DOMAIN} ${CONFIG}"
		fi
		run ${SCRIPT} ${OPTIONS}

		# cert script returned success value
		if [ ! -L "$CERTLINK" ]; then # check if the symlink exists
			exitfail "Symlink to cert not found, abort"
		fi
		if [ ! -L "$KEYLINK" ]; then # check if the symlink exists
			exitfail "Symlink to key not found, abort"
		fi

		rm -f ${CERT}
		ln -s ${CERTLINK} ${CERT}

		rm -f ${KEY}
		ln -s ${KEYLINK} ${KEY}

		if [ $webserver_status -eq 0 ]; then
			# reload webserver config with new certs
			# if nginx config fails, dont exit restore configs instead.
			set +e
			nginx_restart
			if [ $? -ne 0 ]; then
				set -e # not set if nginx failed previously.
				debug "Restoring original config"
				restore_configs
				nginx_restart
			fi
		fi

		exit 0

	else
		exitfail "Failed to retreive certificate"
	fi

elif [ "$CMD" = "revoke" ]; then
	debug "Restoring original config"
	restore_configs
	nginx_restart
	
else
	usage # print help message
fi

exit 0

