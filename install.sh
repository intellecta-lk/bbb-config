#!/bin/bash

# 's:' means the script expects a value after the -s flag
while getopts "s:ru" opt; do
  case $opt in
    s)
      HOST="$OPTARG"
      ;;
    r)
      REPAIR="true"
      ;;
    u)
      UPDATE_CONFIG="true"
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

check_host_flag_valid() {
    if [ -z "$HOST" ]; then
        echo "Error: Host is not set. Use -s <hostname>"
        exit 1
    fi
    echo "The HOST is set to: $HOST"
}


DL_DIR=$(pwd)
EMAIL=dev@intellecta-lk.com
REPO_URL="https://github.com/intellecta-lk/bbb-config"

clean_installation() {

    wget -P "$DL_DIR"  https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh
    chmod +x "$DL_DIR/bbb-install.sh"
    # install without ssl by ommiting -e (email) flag, which is required for certbot to work
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" -e "$EMAIL"

    
    nginx_hash_bucket_size_increase

    # Restart BigBlueButton services to apply changes
    bbb-conf --restart
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
        sudo sed -i "s/.*server_names_hash_bucket_size.*/        $NEW_VALUE/" "$CONF_FILE"
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
    fi

    echo "Updating FreeSWITCH IP from $OLD_IP to $PUBLIC_IP..."

    # 5. Perform the replacement using sed
    # We use a different delimiter (|) in case the IP extraction gets messy
    sudo sed -i "s|$OLD_IP|$PUBLIC_IP|g" "$FS_VARS"

    # 6. Verify and Restart
    echo "Replacement complete. Restarting BigBlueButton services..."
}

check_domain_length() {

  # 1. Try to find the bucket size in Nginx config
  # Defaults to 64 if not explicitly set in nginx.conf
  BUCKET_SIZE=$(nginx -T 2>/dev/null | grep -i "server_names_hash_bucket_size" | awk '{print $2}' | tr -d ';' | head -n 1)

  if [ -z "$BUCKET_SIZE" ]; then
      BUCKET_SIZE=64
      echo "Note: server_names_hash_bucket_size not found in config. Using default: $BUCKET_SIZE"
  fi

  # 2. Calculate the length of the subdomain
  DOMAIN_LEN=${#HOST}
  EFFECTIVE_LEN=$((DOMAIN_LEN + 8)) 

  echo "---------------------------------------"
  echo "Domain:    $HOST"
  echo "Length:    $DOMAIN_LEN characters"
  echo "Effective Length:    $EFFECTIVE_LEN [+8 for nginx overhead]"
  echo "Limit:     $BUCKET_SIZE bytes"
  echo "---------------------------------------"

  # 3. Compare
  if [ "$EFFECTIVE_LEN" -ge "$BUCKET_SIZE" ]; then
      echo "❌ ERROR: Subdomain is too long!"
      echo "Increase 'server_names_hash_bucket_size' to the next power of two (e.g., 128) in nginx.conf."
      exit 1
  else
      echo "✅ SUCCESS: Subdomain fits within the bucket size."
  fi
}

fetch_latest_change() {
    # Setup or update the local repository clone
    echo "Updating existing repository..."
    git fetch origin
    git reset --hard origin/main
}

add_video_playback() {
    mkdir -p /etc/bigbluebutton/recording
    cat > /etc/bigbluebutton/recording/recording.yml << REC
    steps:
    archive: "sanity"
    sanity: "captions"
    captions:
        - process:presentation
        - process:video
    process:presentation: publish:presentation
    process:video: publish:video
REC

    if ! dpkg -l | grep -q bbb-playback-video; then
    apt install -y bbb-playback-video
    systemctl restart bbb-rap-resque-worker.service
    fi
}



if [ "$REPAIR" = "true" ]; then
    echo "Repair mode activated!"
    check_host_flag_valid
    check_domain_length
    freeswitch_ip_update
    # Install SSL and configure nginx for BigBlueButton
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" -e "$EMAIL"
else
    check_host_flag_valid
    check_domain_length
    clean_installation
    add_video_playback
fi