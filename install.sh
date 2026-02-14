#!/bin/bash

# 's:' means the script expects a value after the -s flag
while getopts "s:" opt; do
  case $opt in
    s)
      HOST="$OPTARG"
      ;;
    r)
      REPAIR="true"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

DL_DIR=$(pwd)

clean_installation() {
   
    # Check if HOST was actually set
    if [ -z "$HOST" ]; then
        echo "Error: Host is not set. Use -s <hostname>"
        exit 1
    fi

    echo "The HOST is set to: $HOST"


    # wget -qO- https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh | \
    #     bash -s -- -v jammy-300 -s "$HOST" -e dev@intellecta-lk.com

    wget -P "$DL_DIR"  https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh
    chmod +x "$DL_DIR/bbb-install.sh"
    # install without ssl by ommiting -e (email) flag, which is required for certbot to work
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" 

    # Check if bbb-playback-video is not installed
    if ! dpkg -l | grep -q bbb-playback-video; then
        apt install -y bbb-playback-video
        # systemctl restart bbb-rap-resque-worker.service
    fi
    
    # Check if the file does NOT exist (!)
    if [ ! -f "/etc/bigbluebutton/watermark.txt" ]; then
        echo "Watermark not found. Proceeding with move..."
        sudo cp -r ./etc/* /etc/
    else
        echo "Skipping: /etc/bigbluebutton/watermark.txt already exists."
    fi

    nginx_hash_bucket_size_increase

    # Install SSL and configure nginx for BigBlueButton
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" -e dev@intellecta-lk.com
}


nginx_hash_bucket_size_increase() {
    CONF_FILE="/etc/nginx/nginx.conf"
    NEW_VALUE="server_names_hash_bucket_size 128;"

    # if ! dpkg -l | grep -q nginx; then
    #     apt install -y nginx
    # fi

    # 1. Check if the setting is already there (even if commented out)
    if grep -q "server_names_hash_bucket_size" "$CONF_FILE"; then
        echo "Updating existing setting..."
        # Replace the existing line (commented or not) with the new value
        sudo sed -i "s/.*server_names_hash_bucket_size.*/    $NEW_VALUE/" "$CONF_FILE"
    else
        echo "Adding setting to http block..."
        # Insert it right after the 'http {' line
        sudo sed -i "/http {/a \    $NEW_VALUE" "$CONF_FILE"
    fi

    # 2. Always verify syntax before reloading
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "Nginx reloaded successfully."
    else
        echo "Syntax error detected! Reverting changes is recommended."
    fi
}

freeswitch_ip_update() {
    # 1. Detect the current public IP
    # We use a reliable service like icanhazip.com
    PUBLIC_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

    # 2. Define the target file
    FS_VARS="/opt/freeswitch/etc/freeswitch/vars.xml"

    # 3. Check if the file exists
    if [ ! -f "$FS_VARS" ]; then
        echo "Error: FreeSWITCH vars.xml not found at $FS_VARS"
        exit 1
    fi

    # 4. Find the old IP currently set in the file
    OLD_IP=$(grep "local_ip_v4" "$FS_VARS" | sed -n 's/.*data="local_ip_v4=\([^"]*\)".*/\1/p')

    if [ -z "$OLD_IP" ]; then
        echo "Could not find a local_ip_v4 entry to replace."
        exit 1
    fi

    if [ "$OLD_IP" == "$PUBLIC_IP" ]; then
        echo "IP is already up to date ($PUBLIC_IP). No changes needed."
        exit 0
    fi

    echo "Updating FreeSWITCH IP from $OLD_IP to $PUBLIC_IP..."

    # 5. Perform the replacement using sed
    # We use a different delimiter (|) in case the IP extraction gets messy
    sudo sed -i "s|$OLD_IP|$PUBLIC_IP|g" "$FS_VARS"

    # 6. Verify and Restart
    echo "Replacement complete. Restarting BigBlueButton services..."
}

install_ssl() {
  if ! grep -q "$HOST" /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml; then
    bbb-conf --setip "$HOST"
  fi

  mkdir -p /etc/nginx/ssl

  if [ -z "$PROVIDED_CERTIFICATE" ]; then
    apt-get update
    need_pkg certbot

    if [[ -f "/etc/letsencrypt/live/$HOST/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/renewal/$HOST.conf" ]] \
        && ! grep -q '/var/www/bigbluebutton-default/assets' "/etc/letsencrypt/renewal/$HOST.conf"; then
      sed -i -e 's#/var/www/bigbluebutton-default#/var/www/bigbluebutton-default/assets#' "/etc/letsencrypt/renewal/$HOST.conf"
      if ! certbot renew; then
        err "Let's Encrypt SSL renewal request for $HOST did not succeed - exiting"
      fi
    fi
  fi

  if [ ! -f "/etc/letsencrypt/live/$HOST/fullchain.pem" ]; then
    rm -f /tmp/bigbluebutton.bak
    if ! grep -q "$HOST" /etc/nginx/sites-available/bigbluebutton; then  # make sure we can do the challenge
      if [ -f /etc/nginx/sites-available/bigbluebutton ]; then
        cp /etc/nginx/sites-available/bigbluebutton /tmp/bigbluebutton.bak
      fi
      cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;
server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }
}
HERE
      systemctl restart nginx
    fi

    if [ -z "$PROVIDED_CERTIFICATE" ]; then
      if ! certbot --email "$EMAIL" --agree-tos --rsa-key-size 4096 -w /var/www/bigbluebutton-default/assets/ \
           -d "$HOST" --deploy-hook "systemctl reload nginx" "${LETS_ENCRYPT_OPTIONS[@]}" certonly; then
        systemctl restart nginx
        err "Let's Encrypt SSL request for $HOST did not succeed - exiting"
      fi
    else
      # Place your fullchain.pem and privkey.pem files in /local/certs/ and bbb-install.sh will deal with the rest.
      mkdir -p "/etc/letsencrypt/live/$HOST/"
      ln -s /local/certs/fullchain.pem "/etc/letsencrypt/live/$HOST/fullchain.pem"
      ln -s /local/certs/privkey.pem "/etc/letsencrypt/live/$HOST/privkey.pem"
    fi
  fi

  if [ -z "$COTURN" ]; then
    # No COTURN credentials provided, setup a local TURN server
  cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;

server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  location ^~ / {
    return 301 https://\$server_name\$request_uri; #redirect HTTP to HTTPS
  }

  location ^~ /.well-known/acme-challenge/ {
    allow all;
    default_type "text/plain";
    root /var/www/bigbluebutton-default/assets;
  }

  location = /.well-known/acme-challenge/ {
    return 404;
  }
}

set_real_ip_from 127.0.0.1;
real_ip_header proxy_protocol;
real_ip_recursive on;
server {
  # this double listening is intended. We terminate SSL on haproxy. HTTP2 is a
  # binary protocol. haproxy has to decide which protocol is spoken. This is
  # negotiated by ALPN.
  #
  # Depending on the ALPN value traffic is redirected to either port 82 (HTTP2,
  # ALPN value h2) or 81 (HTTP 1.0 or HTTP 1.1, ALPN value http/1.1 or no value)

  # Http2 is disabled, include http2 to the list if you want to enable it
  # listen 127.0.0.1:82 http2 proxy_protocol;
  # listen [::1]:82 http2;

  listen 127.0.0.1:82 proxy_protocol;
  listen [::1]:82;
  listen 127.0.0.1:81 proxy_protocol;
  listen [::1]:81;
  server_name $HOST;

  # nginx does not know its external port/protocol behind haproxy, so use relative redirects.
  absolute_redirect off;

  # HSTS (uncomment to enable)
  #add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # This variable is used instead of \$scheme by bigbluebutton nginx include
  # files, so \$scheme can be overridden in reverse-proxy configurations.
  set \$real_scheme "https";

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }

  # Include specific rules for record and playback
  include /etc/bigbluebutton/nginx/*.nginx;
}
HERE
  else
    # We've been given COTURN credentials, so HAPROXY is not installed for local TURN server
  cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;

server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  location ^~ / {
    return 301 https://\$server_name\$request_uri; #redirect HTTP to HTTPS
  }

  location ^~ /.well-known/acme-challenge/ {
    allow all;
    default_type "text/plain";
    root /var/www/bigbluebutton-default/assets;
  }

  location = /.well-known/acme-challenge/ {
    return 404;
  }
}

server {
  # Http2 is disabled, include http2 to the list if you want to enable it
  # listen 443 ssl http2;
  # listen [::]:443 ssl http2;

  listen 443 ssl;
  listen [::]:443 ssl;
  server_name $HOST;

    ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_dhparam /etc/nginx/ssl/ffdhe2048.pem;

    # HSTS (comment out to enable)
    #add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # This variable is used instead of \$scheme by bigbluebutton nginx include
  # files, so \$scheme can be overridden in reverse-proxy configurations.
  set \$real_scheme \$scheme;

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }

  # Include specific rules for record and playback
  include /etc/bigbluebutton/nginx/*.nginx;
}
HERE

    if [[ ! -f /etc/nginx/ssl/ffdhe2048.pem ]]; then
      cat >/etc/nginx/ssl/ffdhe2048.pem <<"HERE"
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----
HERE
    fi
    if [[ -f /etc/nginx/ssl/dhp-4096.pem ]]; then
      rm /etc/nginx/ssl/dhp-4096.pem
    fi
  fi
# Create the default Welcome page BigBlueButton Frontend unless it exists.
if [[ ! -f /usr/share/bigbluebutton/nginx/default-fe.nginx && ! -f /usr/share/bigbluebutton/nginx/default-fe.nginx.disabled ]]; then
cat <<HERE > /usr/share/bigbluebutton/nginx/default-fe.nginx
# Default BigBlueButton Landing page.

location @bbb-fe {
  index  index.html index.htm;
  expires 1m;
}

HERE
fi

  # Configure rest of BigBlueButton Configuration for SSL
  xmlstarlet edit --inplace --update '//param[@name="wss-binding"]/@value' --value "$IP:7443" /opt/freeswitch/conf/sip_profiles/external.xml

  # shellcheck disable=SC1091
  eval "$(source /etc/bigbluebutton/bigbluebutton-release && declare -p BIGBLUEBUTTON_RELEASE)"
  if [[ $BIGBLUEBUTTON_RELEASE == 2.2.* ]] && [[ ${BIGBLUEBUTTON_RELEASE#*.*.} -lt 29 ]]; then
    sed -i "s/proxy_pass .*/proxy_pass https:\/\/$IP:7443;/g" /usr/share/bigbluebutton/nginx/sip.nginx
  else
    # Use nginx as proxy for WSS -> WS (see https://github.com/bigbluebutton/bigbluebutton/issues/9667)
    yq e -i '.public.media.sipjsHackViaWs = true' /etc/bigbluebutton/bbb-html5.yml
    sed -i "s/proxy_pass .*/proxy_pass http:\/\/$IP:5066;/g" /usr/share/bigbluebutton/nginx/sip.nginx
    xmlstarlet edit --inplace --update '//param[@name="ws-binding"]/@value' --value "$IP:5066" /opt/freeswitch/conf/sip_profiles/external.xml
  fi

  sed -i 's/^bigbluebutton.web.serverURL=http:/bigbluebutton.web.serverURL=https:/g' "$SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties"
  if [ -f "$BBB_WEB_ETC_CONFIG" ]; then
    sed -i 's/^bigbluebutton.web.serverURL=http:/bigbluebutton.web.serverURL=https:/g' "$BBB_WEB_ETC_CONFIG"
  fi

  yq e -i '.playback_protocol = "https"' /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml
  chmod 644 /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml

  # Update Greenlight (if installed) to use SSL
  for gl_dir in ~/greenlight $GL3_DIR;do
    if [ -f "$gl_dir"/.env ]; then
      if ! grep ^BIGBLUEBUTTON_ENDPOINT "$gl_dir"/.env | grep -q https; then
        if [[ -z $BIGBLUEBUTTON_URL ]]; then
          BIGBLUEBUTTON_URL=$(cat "$SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties" "$CR_TMPFILE" "$BBB_WEB_ETC_CONFIG" | grep -v '#' | sed -n '/^bigbluebutton.web.serverURL/{s/.*=//;p}' | tail -n 1 )/bigbluebutton/
        fi

        sed -i "s|.*BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BIGBLUEBUTTON_URL|" ~/greenlight/.env
        docker compose -f "$gl_dir"/docker-compose.yml down
        docker compose -f "$gl_dir"/docker-compose.yml up -d
      fi
    fi
  done

  mkdir -p /etc/bigbluebutton/bbb-webrtc-sfu
  TARGET=/etc/bigbluebutton/bbb-webrtc-sfu/production.yml
  touch $TARGET

  yq e -i ".freeswitch.ip = \"$IP\"" $TARGET

  if [[ $BIGBLUEBUTTON_RELEASE == 2.2.* ]] && [[ ${BIGBLUEBUTTON_RELEASE#*.*.} -lt 29 ]]; then
    if [ -n "$INTERNAL_IP" ]; then
      yq e -i ".freeswitch.sip_ip = \"$INTERNAL_IP\"" $TARGET
    else
      yq e -i ".freeswitch.sip_ip = \"$IP\"" $TARGET
    fi
  else
    # Use nginx as proxy for WSS -> WS (see https://github.com/bigbluebutton/bigbluebutton/issues/9667)
    yq e -i ".freeswitch.sip_ip = \"$IP\"" $TARGET
  fi
  chown bigbluebutton:bigbluebutton $TARGET
  chmod 644 $TARGET

  # Configure mediasoup IPs, reference: https://raw.githubusercontent.com/bigbluebutton/bbb-webrtc-sfu/v2.7.2/docs/mediasoup.md
  # mediasoup IPs: WebRTC
  yq e -i '.mediasoup.webrtc.listenIps[0].ip = "0.0.0.0"' $TARGET
  yq e -i ".mediasoup.webrtc.listenIps[0].announcedIp = \"$IP\"" $TARGET

  # mediasoup IPs: plain RTP (internal comms, FS <-> mediasoup)
  yq e -i '.mediasoup.plainRtp.listenIp.ip = "0.0.0.0"' $TARGET
  yq e -i ".mediasoup.plainRtp.listenIp.announcedIp = \"$IP\"" $TARGET

  systemctl reload nginx
}

if [ "$REPAIR" = "true" ]; then
    echo "Repair mode activated!"
    freeswitch_ip_update
    # Install SSL and configure nginx for BigBlueButton
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" -e dev@intellecta-lk.com
else
    clean_installation
fi