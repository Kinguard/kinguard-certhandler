#!/bin/bash

function debug {
	if [ $VERBOSE ]; then
		echo $1
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
	echo "This script will make a of copy of any active virtual hosts file, change the certificate pointers to the Let's Encrypt certificates and activate the new configs. It will not touch any vhosts that are not enabled or that does not use ssl."
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
	
	if [ ! -e  ${ORG_CERT} ]; then
		debug "Copy original cert and create symlink"
		mv ${CERT} ${ORG_CERT}
		ln -s ${ORG_CERT} ${CERT}
	fi 
	if [ ! -e  ${ORG_KEY} ]; then
		debug "Copy original key and create symlink"
		mv ${KEY} ${ORG_KEY}
		ln -s ${ORG_KEY} ${KEY}
	fi 

	# check to see that a symlink to "well-known" exists from opi-control dir
	if [ ! -L "$OC_WELLKNOWN" ]; then
		debug "Creating symlink for opi-control use"
		mkdir -p $(dirname ${OC_WELLKNOWN})
		ln -s ${WEB_TARGET} ${OC_WELLKNOWN}
	fi

}

function restore_configs {
	if [ -e  ${ORG_CERT} ] && [ -e  ${ORG_KEY} ]; then
		debug "Restore original cert"
		rm -f ${CERT}
		mv ${ORG_CERT} ${CERT}
		rm -f ${KEY}		
		mv ${ORG_KEY} ${KEY}
	else
		debug "Missing original key/cert"
		return 1
	fi 
}

function nginx_restart {
	debug "Check nginx config"
	nginx -t &> /dev/null
	if [ $? -ne 0 ]; then
		debug "Nginx config error, not restarting"
		return 1
	fi
	debug "(Re)starting webserver"
	service nginx restart &> /dev/null 
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
			echo $server
		fi
	fi
	return $running
}
	
function run {
	if [ $VERBOSE ]; then
		echo "Running script '$@'"
		$@
	else
		$@ &> /dev/null
	fi
	return $?
}

function dehydrated_env {
	D_CONFIG="$(${SCRIPT} -e | grep WELLKNOWN)"
	WELLKNOWN=$(echo $D_CONFIG | sed -n 's%.*WELLKNOWN=\"\(.*\)\"%\1%p')
	debug "WELLKNOWN: ${WELLKNOWN}"

	D_CONFIG="$(${SCRIPT} -e | grep CERTDIR)"
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
	status=$(curl -o /dev/null --silent --head --write-out '%{http_code}\n' "https://setup.op-i.me/check443.php?fqdn=${DOMAIN}&uuid=${uuid}")
	debug "check443 response: $status"
	debug "Removing alive.txt"
	rm -f $alive
	if [[ "$status" -ne 200 ]]; then
		debug "System not reachable from internet"
	fi
}

ME=`basename "$0"`
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SYSCONFIG="/etc/opi/sysinfo.conf"
HANDLER_CONFIG="/etc/kinguard/kinguard-certhandler.conf"
CONFIG="-f ${DIR}/dehydrated/config"

if [ -e $SYSCONFIG ]; then 
	# get name and domain from sysconfig.
	source $SYSCONFIG
else
	debug "No sysinfo file found"
fi

if [ -e $HANDLER_CONFIG ]; then 
	source $HANDLER_CONFIG
else
	echo "Missing config file, exit"
	exit 1
fi

CERT="/etc/opi/web_cert.pem"
KEY="/etc/opi/web_key.pem"

ORG_CERT="/etc/opi/org_cert.pem"
ORG_KEY="/etc/opi/org_key.pem"

if [ ! -z ${opi_name} ] && [ ! -z ${domain} ] ; then
	DOMAIN="${opi_name}.${domain}"
fi

SCRIPT="${DIR}/dehydrated/dehydrated"


getargs "$@" #get the script arguments

case $BACKEND in
	LETSENCRYPT)
		debug "Using Let's Encrypt backend"
		;;
	USER)
		debug "Using user defined certificates, nothing to do here"
		exit 0
		;;
	*)
		debug "Unknown certificate backend, aborting"
		exit 1
		;;
esac

# check internet access to port 443.
# check will terminate script if it does not succeed.
check443


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

	OPTIONS="-c -d ${DOMAIN} ${CONFIG}"
	if [ "$CMD" = "force" ]; then
		OPTIONS="$OPTIONS --force"
	fi

	debug "Requesting cert"
	debug "OPTIONS: ${OPTIONS}"


	if [ $STANDALONE ] && [ "${webserver_status}" -ne 0 ]; then
		debug "Standalone mode, starting webserver"
		nginx_restart
	elif [ "${webserver_status}" -ne 0 ]; then
		debug "No webserver running and stand-alone not specified, aborting"
		exit 1		
	fi
	
	run ${SCRIPT} ${OPTIONS}
	
	script_res=$?
	debug "Cert script returned ${script_res}"

	if [ $script_res -eq 0 ]; then



		if [ $webserver_status -ne 0 ]; then
			# webserver was not running before, lets stop it again
			debug "Standalone mode, stopping webserver"
			nginx_stop
		else
			case $webserver in
				nginx)
					# Nginx is shall already be restarted by dehydrated hook-script
					debug "Nginx is current webserver. Skipping restart, it should aldreay have been restarted."
					#nginx_restart
					;;
				opi-control)
					debug "Restart webserver to load new cert"
					debug "opi-control running"
					service opi-control restart
					;;
				*)
					debug "Unknown webserver"
					;;
			esac
		fi
		
		#clean up unused certs
		OPTIONS="--cleanup -d ${DOMAIN} ${CONFIG}"
		run ${SCRIPT} ${OPTIONS}

		# cert script returned success value
		if [ ! -L "$CERTLINK" ]; then # check if the symlink exists
			debug "Symlink to cert not found, abort"
			exit 1
		fi
		if [ ! -L "$KEYLINK" ]; then # check if the symlink exists
			debug "Symlink to key not found, abort"
			exit 1
		fi

		# make sure that the original key and certificate is still present
		if [ -e ${ORG_CERT} ] && [ -e ${ORG_KEY} ]; then  
			rm -f ${CERT}
			ln -s ${CERTLINK} ${CERT}

			rm -f ${KEY}
			ln -s ${KEYLINK} ${KEY}
		fi

		exit 0

	else
		debug "Failed to retreive certificate"
		exit 1
	fi

elif [ "$CMD" = "revoke" ]; then
	debug "Restoring original config"
	restore_configs
	nginx_restart
	
else
	usage # print help message
fi

exit 0

