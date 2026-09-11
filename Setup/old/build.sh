#!/bin/bash

# Check if the package name is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ExecutableName>"
    exit 1
fi

EXECUTABLE_NAME=$1
BUILD_DIR=".dist/Build/Products/Release"
INSTALL_DIR="$HOME/bin"

# Create local bin directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Build the package in release mode
echo "Building $EXECUTABLE_NAME in release mode..."
# swift build -c release
xcodebuild build -scheme sewn-server-release -destination 'platform=OS X' -derivedDataPath ".dist/"

# Check if build succeeded
if [ $? -ne 0 ]; then
    echo "Build failed. Exiting."
    exit 1
fi

echo "$EXECUTABLE_NAME is now available."
echo "Running server."

./run.sh

#
## Copy the executable to the install directory
#echo "Copying $EXECUTABLE_NAME to $INSTALL_DIR..."
#cp "$BUILD_DIR/$EXECUTABLE_NAME" "$INSTALL_DIR/"
#
## Check if the copy succeeded
#if [ $? -ne 0 ]; then
#    echo "Failed to copy executable. Exiting."
#    exit 1
#fi
#
## Add local bin to PATH if not already present
#if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
#    echo "Adding $INSTALL_DIR to PATH..."
#    echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
#    source ~/.zshrc
#fi
#
#echo "$EXECUTABLE_NAME is now available globally. Run it with:"
#echo "$EXECUTABLE_NAME"
