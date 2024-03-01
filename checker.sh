#!/bin/bash

echo "This script will check the status of an account."
read -p "Handle: @" HANDLE
read -s -p "Password (will not echo): " PASS
read -p $'\n'"PDS: " PDS

CRED=$(curl --silent -L "https://${PDS}/xrpc/com.atproto.server.createSession" -H 'Content-Type: application/json' --data '{ "identifier": "'${HANDLE}'", "password": "'${PASS}'" }')

DID=$(echo ${CRED} | jq -r '.did')
JWT=$(echo ${CRED} | jq -r '.accessJwt')

CHECK_STATUS=$(curl --silent -L -X GET "https://${PDS}/xrpc/com.atproto.server.checkAccountStatus" -H 'Accept: application/json' -H "Authorization: Bearer ${JWT}")

echo $'\n'"====== Status for @${HANDLE} at ${PDS} ======"
echo "DID: ${DID}"
echo "Activation Status: $(echo ${CHECK_STATUS} | jq -r '.activated')"
echo "Valid DID Status: $(echo ${CHECK_STATUS} | jq -r '.validDid')"
echo "Blobs to import: $(echo ${CHECK_STATUS} | jq -r '.expectedBlobs')"
echo "Blobs imported: $(echo ${CHECK_STATUS} | jq -r '.importedBlobs')"
