#!/bin/bash

# Run the scontrol command and capture the output
rm -rf ./hostfile
rm -rf ./hostfile_tmp
output=$(scontrol show nodes)

# Extract the NodeAddr values and write them to a file
echo "$output" | grep -oP '(?<=NodeAddr=)\S+' > hostfile_tmp

cat hostfile_tmp|while read host_name
do
   slot_num=$(ssh -o StrictHostKeyChecking=no ${host_name} "nvidia-smi -L | wc -l")
   echo "${host_name}  slot=${slot_num}"
   echo "${host_name}  slot=${slot_num}" >> hostfile
done

# Print the contents of the hostfile
echo "Contents of hostfile:"
cat hostfile
