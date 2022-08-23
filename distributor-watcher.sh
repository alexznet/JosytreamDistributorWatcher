#!/bin/bash

#Сontants
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
#Endof: Color contants

#Setting variables
qnEndpoint='https://YOUR_QN_HOSTNAME/graphql'
leadPwd='LEAD_PWD'
configYmlPath='PATH_TO_JOYSTREAM_FOLDER/distributor-node/config.yml'

declare -i failTrashold
failTrashold=3
#Endof: Setting variables

scriptPath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
shutdownLogPath="$scriptPath/shutdown.log"
runLogPath="$scriptPath/run.log"
curTime=$(date '+%d-%m-%Y %H:%M:%S')

echo -e "${GREEN}Starting distributors check${NC}"

origin=${qnEndpoint%/graphql} 

qnActiveDstrResponse=$(curl -s "$qnEndpoint" -H 'Accept-Encoding: gzip, deflate, br' -H 'Content-Type: application/json' -H 'Accept: application/json' -H 'Connection: keep-alive' -H 'DNT: 1' -H "Origin: $origin" --data-binary '{"query":"query{\n  \tdistributionBucketOperators(where: {distributionBucket: {distributing_eq: true}}){\n      id,\n      metadata {\n        nodeEndpoint\n      }\n    }\n}"}' --compressed | jq '.data.distributionBucketOperators')

echo "Got response from QN"

readarray -t distributorIds <<< $( jq -r  '.[].id' <<< "${qnActiveDstrResponse}" )
readarray -t distributorEndpoints <<< $( jq -r  '.[].metadata.nodeEndpoint' <<< "${qnActiveDstrResponse}" )

nodesArrlen=${#distributorIds[@]}
echo "Got $nodesArrlen active nodes"

for (( i=0; i<$nodesArrlen; i++ ))
do
   curEndpoint=${distributorEndpoints[$i]}
   curId=${distributorIds[$i]}

   echo "Working with node $curEndpoint - ID: $curId"

   endpToCheck=$(echo "${curEndpoint}api/v1/status" | tr -d '"')
   #cutting address part to get hostname
   host=${endpToCheck%/distributor/api/v1/status}
   #cutting schema part to get hostname
   host=${host:8}

   if [[ ! -d "./$host/" ]]
   then
      echo "Folder with data about $host does not exist. Going to create it"
      mkdir "./$host"
   fi

   echo "Going to check $endpToCheck for status code"
   statusResult=$(curl -s -o /dev/null -w "%{http_code}" $endpToCheck)

   failsFilePath="$scriptPath/$host/failCount.txt"

   if [[ $statusResult -eq '200' ]]
   then
      #setting up emty file with failures count
      #this will just reset the file, regardless of current content
      echo -e "${GREEN}$endpToCheck - $statusResult ${NC}"
      cp /dev/null $failsFilePath
      echo "Node is fine - finishing, fail count reset ($failsFilePath)"
   else
      #It means that we've got some other code that is not normal
      #usually 500 or 404. We will need to read failCount content
      #and increase it if it is less than configured value. If more
      #we need to shutdown the node
      echo -e "${RED}$endpToCheck - $statusResult ${NC}"

      echo "Trying to read current fails count from $failsFilePath"
      typeset -i failCount=$(cat $failsFilePath)
      echo "Old fail count - '$failCount' -> new fail count '$((++failCount))'"

      if [[ $failCount -lt $failTrashold ]]
      then
         echo "Fail count '$failCount' is less than trashold '$failTrashold'. Skipping."
         echo "$failCount" > $failsFilePath
      else
         echo "Reached fail trashold '$failTrashold' of node fail statuses"
         #This means that we need to shutown this node
         echo -e "${RED}Need to shutdown node $host ${NC}"

         #Firstly let's leave just family-bucket
         familyBucket=${curId%-*}
         echo "Family:bucket of node to shutdown is $familyBucket"
         
         curLocation=$(pwd)
         echo $curLocation
         cd $(echo "${configYmlPath%/distributor-node/config.yml}")
         echo 'Going to run shutdown command'
         echo $leadPwd | yarn joystream-distributor leader:update-bucket-mode -B $familyBucket -d off -y -c $configYmlPath
         echo 'Shutdown is complete'
         cd $curLocation

         echo "$curTime - Shutdown '$familyBucket'" >> $shutdownLogPath

         #and let's clear fail count as node is already shutdown
         echo 'Resetting fails count because node is not active any more'
         cp /dev/null $failsFilePath
      fi
   fi
done

echo "$curTime - script executed (checked $nodesArrlen nodes)" >> $runLogPath
echo -e "${GREEN}Operation complete ${NC}"
