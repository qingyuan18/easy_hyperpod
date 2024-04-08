#!/bin/bash

# Run the scontrol command and capture the output
output=$(scontrol show nodes)

# Extract the NodeAddr values and write them to a file
echo "$output" | grep -oP '(?<=NodeAddr=)\S+' > hostfile

# Print the contents of the hostfile
echo "Contents of hostfile:"
cat hostfile