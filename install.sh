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


    # Check if the file does NOT exist (!)
    if [ ! -f "/etc/bigbluebutton/watermark.txt" ]; then
        echo "Watermark not found. Proceeding with move..."
        sudo cp -r ./etc/* /etc/
    else
        echo "Skipping: /etc/bigbluebutton/watermark.txt already exists."
    fi


    # wget -qO- https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh | \
    #     bash -s -- -v jammy-300 -s "$HOST" -e dev@intellecta-lk.com

    wget -P "$DL_DIR"  https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh
    chmod +x "$DL_DIR/bbb-install.sh"
    "$DL_DIR/bbb-install.sh" -v jammy-300 -s "$HOST" -e dev@intellecta-lk.com 

    # Check if bbb-playback-video is not installed
    if ! dpkg -l | grep -q bbb-playback-video; then
        apt install -y bbb-playback-video
        systemctl restart bbb-rap-resque-worker.service
    fi
}

nginx_hash_bucket_size_increase(){
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

if [ "$REPAIR" = "true" ]; then
    echo "Repair mode activated!"
    # nginx_hash_bucket_size_increase
    freeswitch_ip_update
else
    clean_installation
fi