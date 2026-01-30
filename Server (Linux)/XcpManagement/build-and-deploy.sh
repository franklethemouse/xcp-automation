#!/bin/bash
set -e

echo "Building XCP Management API..."

# Restore and build
dotnet restore
dotnet build -c Release

# Publish
dotnet publish -c Release -o ./publish

echo ""
echo "Build complete!"
echo ""
echo "To deploy, run:"
echo "sudo /opt/xcp-management/deploy.sh --source ./publish"