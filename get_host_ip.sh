#!/bin/bash

SLURM_CONF="/var/spool/slurmd/conf-cache/slurm.conf"

# Check if slurm.conf exists
if [ ! -f "$SLURM_CONF" ]; then
    echo "Error: Cannot find slurm.conf at $SLURM_CONF"
    exit 1
fi

# Clean up existing files
rm -rf ./hostfile
rm -rf ./hostfile_tmp

# Extract NodeAddr values and write them to a temporary file
grep "NodeAddr=" "$SLURM_CONF" | grep -oP '(?<=NodeAddr=)\S+' > hostfile_tmp

# Process each host and get its GPU count
while read host_name; do
    # Get GPU count for the current node from slurm.conf
    gpu_count=$(grep "NodeAddr=$host_name" "$SLURM_CONF" | grep -oP 'Gres=gpu:[^:]+:(\d+)' | cut -d':' -f3 || echo "0")
    
    # Write hostname and slots to hostfile
    echo "${host_name} slots=${gpu_count}" >> hostfile
done < hostfile_tmp

# Clean up temporary file
rm -f hostfile_tmp

# Print the contents of the hostfile
echo "Contents of hostfile:"
cat hostfile