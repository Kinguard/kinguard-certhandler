#!/bin/bash

ME=`basename "$0"`
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SYSCONFIG="/etc/opi/sysinfo.conf"
source $SYSCONFIG

DOMAIN="${opi_name}.op-i.me"
NORESTART=false

SCRIPT="${DIR}/certbot-auto"
WEBROOT="/var/www/static"

CERTPATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEYPATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
CERTLINK="/etc/opi/kinguard_le.pem"
KEYLINK="/etc/opi/kinguard_lekey.pem"

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
	echo "  -c 			: tries to retreive a Let's Encrypt certificate"
	echo "       		  for the name stated in sysinfo.conf"
	echo "  -f 			: same as '-c' but also forces a renewal of the certificate"
	echo "       		  even if it has not expired"
	echo "  -d domain	: Create the certificate for 'domain' instade of what is in the sysinfo.conf"
	echo "  -n			: Do not restart nginx, useful when only the cert is needed"
	echo "  -r 			: Removes the Let's Encrypt certificate and restores default config"	
	echo "  -s 			: Use Let's Encrypt staging servers,"
	echo "        		  working but not signed certificates will be generated"
	echo "  -u 			: Updates the current certificates"
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
			STAGING=" --staging --break-my-certs "		
			;;
		u)
			CMD="renew"
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
	for file in /etc/nginx/sites-enabled/*; do

		# are the vhosts already using ssl?
		grep ssl_certificate $file &> /dev/null 
	
		if [ $? -eq 0 ]; then # certificates are used in the vhost
			grep "_le[key]*\.pem" $file &> /dev/null 
			if [ $? -eq 0 ]; then
				#Let's Encrypt cert already in use, do nothing
				debug "Already using Let's Encrypt Certificates"
				continue
			fi
		
			# Create a copy of the vhost file
			targetfile=$(basename "$file")
			target="/etc/nginx/sites-available/${targetfile}_LE"
			if [ -f "$target" ]; then
				debug "Target (${target}) exist"
			else
				debug "Copy config: $targetfile"
				cp $file $target
			fi
		
			# change the ssl configs to Let's Encrypts certs
			sed -i 's/ssl_certificate\s.*/ssl_certificate \/etc\/opi\/kinguard_le.pem;/' /etc/nginx/sites-available/keep_LE
			sed -i 's/ssl_certificate_key\s.*/ssl_certificate_key \/etc\/opi\/kinguard_lekey.pem;/' /etc/nginx/sites-available/keep_LE
		fi
	done
}

function restore_configs {
	for file in /etc/nginx/sites-enabled/*; do
		# is it already usng a Let's Encrypt cert?
		grep "_le[key]*\.pem" $file &> /dev/null 
		if [ $? -eq 0 ]; then
			debug "Restore config for $file"
			targetfile=$(basename "$file")
			if [[ "$file" == *_LE ]]; then			
				target=${targetfile::-3}
			else
				# not our file do not touch it
				debug "Not our file"
				continue
			fi
			rm -f $file
			ln -s /etc/nginx/sites-available/${target} /etc/nginx/sites-enabled/
		fi
	done
}

getargs "$@" #get the script arguments

debug "Running Let's Encrypt certificate generation for ${DOMAIN}"

if [ "$CMD" = "create" ] || [ "$CMD" = "force" ]; then
	
	EMAIL="admin@${DOMAIN}"
	create_configs  # generate configuration files if needed

	if [ -n "$STAGING" ]; then
		debug "Using staging servers"
	fi

	OPTIONS="certonly ${STAGING} --agree-tos --email ${EMAIL} -n ${QUIET} --no-self-upgrade --webroot -w ${WEBROOT} -d ${DOMAIN}"
	if [ "$CMD" = "force" ]; then
		OPTIONS="$OPTIONS --force-renewal"
	fi

	debug "Requesting cert"
	debug "OPTIONS: ${OPTIONS}"

	${SCRIPT} ${OPTIONS}
	res=$?

	debug "Certbot-auto returned ${res}"

	if [ $res -eq 0 ]; then
		# certbot returned success value
		debug "Installing cert"
		if [ ! -L "$CERTLINK" ]; then # check if the symlink exists
			debug "Creating symlink for cert"
			ln -s $CERTPATH $CERTLINK
		fi
		if [ ! -L "$KEYLINK" ]; then # check if the symlink exists
			debug "Creating symlink for key"
			ln -s $KEYPATH $KEYLINK
		fi

		for file in /etc/nginx/sites-enabled/*; do
			# is it already usng a Let's Encrypt cert?
			grep "_le[key]*\.pem" $file &> /dev/null 
			if [ $? -eq 0 ]; then
				#Let's Encrypt cert already in use, do nothing
				debug "Already using Let's Encrypt Certificates"
				continue
			fi
			
			# is there a Let's Encrypt config available for the vhost?
			LE_config=$(basename "$file")
			ConfigTarget="/etc/nginx/sites-available/${LE_config}_LE"
			if [ -f  "$ConfigTarget" ]; then
				debug "Exchanging config file: $LE_config";
				rm -f $file
				ln -s $ConfigTarget /etc/nginx/sites-enabled/
			fi
		done

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
elif [ "$CMD" = "renew" ]; then
	debug "Check if certificates are used"
	grep "_le[key]*\.pem" /etc/nginx/sites-enabled/* &> /dev/null 
	if [ $? -ne 0 ]; then
		debug "Let's Encrypt certificates not used"
		exit 0
	fi
	debug "Renewing certs"
	OPTIONS="renew -n ${QUIET}"
	${SCRIPT} ${OPTIONS}
	if [ $? -ne 0 ]; then
		debug "Failed to renew certificates"
	fi

	service nginx status &> /dev/null 
	if [ $? -eq 0 ]; then # only restart nginx if it is running
		nginx_restart
	fi

elif [ "$CMD" = "revoke" ]; then
	debug "Restoring original config"
	restore_configs
	nginx_restart
	
else
	usage # print help message
fi

exit 0
