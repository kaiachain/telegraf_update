#!/bin/bash

# Target configuration files
TARGET_FILES=("/etc/telegraf/telegraf.d/klaytn.conf" "/etc/telegraf/telegraf.d/kaia.conf")

# The configuration block to add
# Using newlines to ensure it starts as a new section at the end of the file
INSERT_BLOCK="\n[[inputs.procstat]]\n  exe = \"kpn\""

for FILE in "${TARGET_FILES[@]}"; do
    if [ -f "$FILE" ]; then
        echo "Processing: $FILE"

        # 1. Clean up existing procstat entries to prevent duplicates or syntax errors
        # This removes lines containing [[inputs.procstat]] and exe = "kpn"
        sudo sed -i '/\[\[inputs.procstat\]\]/d' "$FILE"
        sudo sed -i '/exe = "kpn"/d' "$FILE"

        # 2. Append the block to the end of the file
        # This keeps the [agent] section intact and avoids "Overlapping settings" errors
        echo -e "$INSERT_BLOCK" | sudo tee -a "$FILE" > /dev/null
        echo "Successfully updated $FILE."

        # 3. Restart Telegraf service
        sudo systemctl restart telegraf
        
        if [ $? -eq 0 ]; then
            echo "Telegraf service restarted successfully."
        else
            echo "Failed to restart Telegraf. Please check the logs."
        fi
        
        # Exit after processing the first found file
        exit 0
    fi
done

echo "Error: Neither klaytn.conf nor kaia.conf was found."
exit 1
