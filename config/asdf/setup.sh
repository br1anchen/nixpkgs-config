#!/bin/bash

if [ ! -d "$HOME/.asdf" ]; then
	git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
fi

# Define the fixed filename
filename="$HOME/nixpkgs-config/config/asdf/tool-versions"

# Check if the file exists
if [ ! -f "$filename" ]; then
	echo "File not found: $filename"
	exit 1
fi

# Read the file line by line
while IFS= read -r line; do
	# Extract the first entry of the line
	first_entry=$(echo "$line" | awk '{print $1}')

	echo "Adding plugin: $first_entry"
	# Use the first entry in the command "asdf plugin add"
	asdf plugin add "$first_entry"
done <"$filename"

asdf install
