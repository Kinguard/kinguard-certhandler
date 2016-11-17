#!/bin/bash

ME=`basename "$0"`
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SYSCONFIG="/etc/opi/sysinfo.conf"
source $SYSCONFIG

CERT="/etc/opi/web_cert.pem"
KEY="/etc/opi/web_key.pem"

ORG_CERT="/etc/opi/org_cert.pem"
ORG_KEY="/etc/opi/org_key.pem"


if [ ! -z ${opi_name} ]; then
	DOMAIN="${opi_name}.op-i.me"
fi
NORESTART=false

SCRIPT="${DIR}/dehydrated/dehydrated"

function nginx_restart {
	debug "Check nginx config"
	nginx -t &> /dev/null
	if [ $? -ne 0 ]; then
		debug "Nginx config error, not restarting"
		return 1
	fi
	if [ $NORESTART == true ]; then
		debug "Not restarting Nginx by request"
		return 0
	fi
	debug "Restarting webserver"
	service nginx restart &> /dev/null 
	service nginx status &> /dev/null 
	if [ $? -ne 0 ]; then
		debug "Webserver not running after restart command"
		return 1
	else
		return 0
	fi
}

function usage {
	echo "Use '${ME} [-cfrsv] [-d domain]"
	echo "  -c 			: tries to retreive/update a Let's Encrypt certificate"
	echo "       		  for the name stated in sysinfo.conf"
	echo "  -f 			: same as '-c' but also forces a renewal of the certificate"
	echo "       		  even if it has not expired"
	echo "  -d domain	: Create the certificate for 'domain' instade of what is in the sysinfo.conf"
	echo "  -n			: Do not restart nginx, useful when only the cert is needed"
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
	while getopts "cd:fnrsuv" OPTION; do
		case "$OPTION" in
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
		n)
			NORESTART=true
			;;
		r)
			CMD="revoke"
			;;
		s)
			STAGING="-f ${DIR}/dehydrated/staging-config"
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

function debug {
	if [ $VERBOSE ]; then
		echo $1
	fi
}

function create_configs {
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
}

function restore_configs {
	if [ -e  ${ORG_CERT} ]; then
		debug "Restore original cert"
		rm -f ${CERT}
		mv ${ORG_CERT} ${CERT}
	fi 
	if [ -e  ${ORG_KEY} ]; then
		debug "Restore original key"
		rm -f ${KEY}		
		mv ${ORG_KEY} ${KEY}
	fi 
}

function run {
	if [ $VERBOSE ]; then
		echo "Running script"
		$@
	else
		$@ &> /dev/null
	fi
	return $?
}

function get_cert_links {
	D_CONFIG="$(${SCRIPT} -e | grep CERTDIR)"
	CERTDIR=${D_CONFIG//*CERTDIR=/}
	CERTDIR="${CERTDIR//\"/}"  

	CERTLINK="${CERTDIR}/${DOMAIN}/fullchain.pem"
	KEYLINK="${CERTDIR}/${DOMAIN}/privkey.pem"

	debug "CERTLINK: ${CERTLINK}"
	debug "KEYLINK: ${KEYLINK}"
}

getargs "$@" #get the script arguments

if [ -z ${DOMAIN} ]; then
	debug "Empty DOMAIN, nothing to do"
	exit 0
fi

debug "Running Let's Encrypt certificate generation for ${DOMAIN}"

get_cert_links	

if [ "$CMD" = "create" ] || [ "$CMD" = "force" ] || [ "$CMD" = "renew" ]; then


	create_configs  # generate configuration files if needed

	if [ -n "$STAGING" ]; then
		debug "Using staging servers"
	fi

	OPTIONS="-c -d ${DOMAIN} ${STAGING}"
	if [ "$CMD" = "force" ]; then
		OPTIONS="$OPTIONS --force"
	fi

	debug "Requesting cert"
	debug "OPTIONS: ${OPTIONS}"

	run ${SCRIPT} ${OPTIONS}

	debug "Cert script returned ${?}"

	if [ $? -eq 0 ]; then
		# cert script returned success value
		if [ ! -L "$CERTLINK" ]; then # check if the symlink exists
			debug "Symlink to cert not found, abort"
			exit 1
		fi
		if [ ! -L "$KEYLINK" ]; then # check if the symlink exists
			debug "Symlink to key not found, abort"
			exit 1
		fi


		if [ -e ${ORG_CERT} ] && [ -e ${ORG_KEY} ]; then  # make sure that the original key and certificate is still present
			rm -f ${CERT}
			ln -s ${CERTLINK} ${CERT}

			rm -f ${KEY}
			ln -s ${KEYLINK} ${KEY}
		fi

		nginx_restart
		if [ $? -ne 0 ]; then
			echo "Failed to reload nginx configuration, restoring old config"
			restore_configs
			nginx_restart
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
