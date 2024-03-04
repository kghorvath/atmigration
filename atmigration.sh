#!/bin/bash

#Initial warning
echo "This script will assist in migrating an AT Protocol account between two personal data servers (PDS). Note: This script DOES NOT PERFORM ANY ERROR CHECKING. You are responsible for confirming that all steps have proceeded correctly. I take absolutely no responsibility for anything that occurs as a result of this script."
read -p "If you understand and Wish to proceed, type I UNDERSTAND: " ACCEPT
if [ "$ACCEPT" != "I UNDERSTAND" ]
then
   exit
fi

#Get the credentials of the originating account
read -p "Please enter the originating PDS you want to migrate from: " ORIG_PDS

echo "Please enter the credentials for the account you want to migrate."
read -p "Handle: @" ORIG_HANDLE
read -s -p "Password (will not echo): " ORIG_PASS

#Fetch the DID, endpoint, and originating JWT token
echo "Fetching tokens and user information"
ORIG_CRED=$(curl --silent -L "https://${ORIG_PDS}/xrpc/com.atproto.server.createSession" -H 'Content-Type: application/json' --data '{ "identifier": "'${ORIG_HANDLE}'", "password": "'${ORIG_PASS}'" }')

DID=$(echo ${ORIG_CRED} | jq -r '.did')
ORIG_ENDPOINT=$(echo ${ORIG_CRED} | jq -r '.didDoc.service[0].serviceEndpoint')
ORIG_JWT=$(echo ${ORIG_CRED} | jq -r '.accessJwt')

echo "Your DID is ${DID}"

#Get the target PDS
read -p "Please enter the target PDS you want to migrate to: " DEST_PDS

#Get service auth from originating PDS
echo "Fetching service auth..."
ORIG_AUTH=$(curl --silent -L -G "https://${ORIG_PDS}/xrpc/com.atproto.server.getServiceAuth" -d "aud=did:web:${DEST_PDS}" -H 'Accept: application/json' -H "Authorization: Bearer ${ORIG_JWT}")
SVC_AUTH=$(echo ${ORIG_AUTH} | jq -r '.token')

#Create the destination account
echo "Please enter the credentials for the new account you would like to create on the target PDS"
read -p "Handle: @" DEST_HANDLE
REGEX="^.*$DEST_PDS$"
if ! [[ $DEST_HANDLE =~ $REGEX ]]; then
  DEST_HANDLE="${DEST_HANDLE}.${DEST_PDS}"
  echo "Using $DEST_HANDLE as handle. Ctrl-C if this is incorrect."
fi
read -s -p "Password (will not echo): " DEST_PASS
read -p $'\n'"Email: " DEST_EMAIL
read -p "Invite Code: " DEST_INVITE
DEST_ACCT_CREATE=$(curl --silent -L -X POST "https://${DEST_PDS}/xrpc/com.atproto.server.createAccount" -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Bearer ${SVC_AUTH}" --data-raw '{ "email": "'${DEST_EMAIL}'", "handle": "'${DEST_HANDLE}'", "did": "'${DID}'", "inviteCode": "'${DEST_INVITE}'", "password": "'${DEST_PASS}'" }')

#Pause to check account creation output
echo ${DEST_ACCT_CREATE}
read -p "Press any key to continue..."

#Fetch destination JWT token from new account
DEST_JWT=$(echo ${DEST_ACCT_CREATE} | jq -r '.accessJwt')

echo "Account successfully created!"

CHECK_STATUS=$(curl --silent -L -X GET "https://${DEST_PDS}/xrpc/com.atproto.server.checkAccountStatus" -H 'Accept: application/json' -H "Authorization: Bearer ${DEST_JWT}")
echo $'\n'"Current Status for @${DEST_HANDLE}"
echo "--------------------------------------------------------------"
echo "Activation Status: $(echo ${CHECK_STATUS} | jq -r '.activated')"
echo "Valid DID Status: $(echo ${CHECK_STATUS} | jq -r '.validDid')"
echo "Blobs to import: $(echo ${CHECK_STATUS} | jq -r '.expectedBlobs')"
echo "Blobs imported: $(echo ${CHECK_STATUS} | jq -r '.importedBlobs')"

#Export the repo from the originating PDS to local filesystem
echo "Exporting repo from old PDS to ~/temp/"
curl --silent -L -G "${ORIG_ENDPOINT}/xrpc/com.atproto.sync.getRepo" -d "did=${DID}" -H 'Accept: application/vnd.ipld.car' --output ${HOME}/temp/bskyrepo

#Import repo to destination PDS
echo "Importing repo to new PDS"
curl --silent -L -X POST "https://${DEST_PDS}/xrpc/com.atproto.repo.importRepo" -H 'Content-Type: application/vnd.ipld.car' -H 'Accept: application/json' -H "Authorization: Bearer ${DEST_JWT}" --data-binary "@${HOME}/temp/bskyrepo"

#Export/Import preferences
echo "Exporting preferences from old PDS"
PREF=$(curl --silent -L -X GET "${ORIG_ENDPOINT}/xrpc/app.bsky.actor.getPreferences" -H 'Accept: application/json' -H "Authorization: Bearer ${ORIG_JWT}")
echo "Importing preferences to new PDS"
curl --silent -L -X POST "https://${DEST_PDS}/xrpc/app.bsky.actor.putPreferences" -H 'Content-Type: application/json' -H "Authorization: Bearer ${DEST_JWT}" --data-raw "${PREF}" 

#Check how many blobs we need to transfer
echo "Checking existing blobs"
BLOBLIST=$(curl --silent -L -G "${ORIG_ENDPOINT}/xrpc/com.atproto.sync.listBlobs" -d "did=${DID}" -H 'Accept: application/json')
BLOB_NUM=$(echo ${BLOBLIST} | jq -r '.cids | length')
echo "Found $BLOB_NUM blob(s)"

#Export/Import blobs
for (( i=1; i<=$BLOB_NUM; i++))
do
    j=`expr $i - 1`
    CID=$(echo ${BLOBLIST} | jq -r ".cids[$j]")
    echo "Fetching blob ${CID}"
    curl --silent -L -G "${ORIG_ENDPOINT}/xrpc/com.atproto.sync.getBlob" -H 'Accept: */*' -d "did=${DID}" -d "cid=${CID}" --output $HOME/temp/blob
    echo "Importing blob to new PDS"
    curl --silent -o /dev/null -L -X POST "https://${DEST_PDS}/xrpc/com.atproto.repo.uploadBlob" -H 'Content-Type: */*' -H 'Accept: application/json' -H "Authorization: Bearer ${DEST_JWT}" --data-binary "@${HOME}/temp/blob"
done

#Get recommended creds from the target PDS
echo "Fetching recommended credentials for the migration"
DEST_CRED=$(curl --silent -L -X GET "https://${DEST_PDS}/xrpc/com.atproto.identity.getRecommendedDidCredentials" -H 'Accept: application/json' -H "Authorization: Bearer ${DEST_JWT}")
DEST_KEY=$(echo ${DEST_CRED} | jq -r '.verificationMethods')
DEST_AKA=$(echo ${DEST_CRED} | jq -r '.alsoKnownAs')
DEST_ROT=$(echo ${DEST_CRED} | jq -r '.rotationKeys')
DEST_SVC=$(echo ${DEST_CRED} | jq -r '.services')

#Request a PLC token from the originating PDS
echo "Requesting a PLC operation from the originating PDS"
curl --silent -L -X POST "${ORIG_ENDPOINT}/xrpc/com.atproto.identity.requestPlcOperationSignature" -H "Authorization: Bearer ${ORIG_JWT}"

echo "A PLC operation request was sent to the email ${ORIG_EMAIL}. Please enter the code received below."
read -p "Code: " PLC_TOKEN

#Sign the PLC operation with the destination PDS credentials
echo "OK. Signing the operation"
ORIG_SIGNED=$(curl --silent -L -X POST "${ORIG_ENDPOINT}/xrpc/com.atproto.identity.signPlcOperation" -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Bearer ${ORIG_JWT}" -d "{\"token\": \"${PLC_TOKEN}\",\"rotationKeys\": ${DEST_ROT},\"alsoKnownAs\": ${DEST_AKA},\"verificationMethods\": ${DEST_KEY},\"services\": ${DEST_SVC}}")

#Last chance warning before we submit the PLC operation to the destination PDS
echo $'\n'"You are about to submit the PLC operation and update your identity. This is your LAST CHANCE to back out. Please not that if you are migrating from bsky.social, this operation is IRREVERSIBLE. Now would be a great time to manually check that everything has been migrated properly before moving forward. Please see https://github.com/bluesky-social/pds/blob/main/ACCOUNT_MIGRATION.md for more details."

read -p $'\n'"Are you sure you want to proceed? (yes/no): " LASTCHANCE

while [ ${LASTCHANCE,,} != "yes" ] && [ ${LASTCHANCE,,} != "no" ];
do
      read -p "You must type 'yes' or 'no': " LASTCHANCE
done

if [ ${LASTCHANCE,,} == "no" ]
then
    echo "No worries. When you're ready, run this script again."
    exit
fi

#Submit the PLC operation
echo "Transferring your identity from ${ORIG_PDS} to ${DEST_PDS}"
curl -L -X POST "https://${DEST_PDS}/xrpc/com.atproto.identity.submitPlcOperation" -H 'Content-Type: application/json' -H "Authorization: Bearer ${DEST_JWT}" -d "${ORIG_SIGNED}"

#Activate the new account
echo "Done! Activating account."
curl --silent -L -X POST "https://${DEST_PDS}/xrpc/com.atproto.server.activateAccount" -H "Authorization: Bearer ${DEST_JWT}"

#Display new account status
CHECK_STATUS=$(curl --silent -L -X GET "https://${DEST_PDS}/xrpc/com.atproto.server.checkAccountStatus" -H 'Accept: application/json' -H "Authorization: Bearer ${DEST_JWT}")
echo $'\n'"Current Status for @${DEST_HANDLE}"
echo "--------------------------------------------------------------"
echo "Activation Status: $(echo ${CHECK_STATUS} | jq -r '.activated')"
echo "Valid DID Status: $(echo ${CHECK_STATUS} | jq -r '.validDid')"
echo "Blobs to import: $(echo ${CHECK_STATUS} | jq -r '.expectedBlobs')"
echo "Blobs imported: $(echo ${CHECK_STATUS} | jq -r '.importedBlobs')"

echo "Finished! You may now log into your new account on ${DEST_PDS}. If all looks good, be sure to delete your old account on ${ORIG_PDS}"
