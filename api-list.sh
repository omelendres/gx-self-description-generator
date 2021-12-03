#!/bin/bash
# Little tool to list all advertised OpenStack APIs
# Does go beyond catalog by doing microversion discovery
#
# Outputs CSV with type,name,endpt,versions
#  versions is a space separated list of id:status tuples
#  version=- meaning that version discovery returns an error, ? unparsable
#
# TODO: Add logic for special features such as neutron's LBaaS2, VPNaaS, FWaaS ...
#
# Usage: api-list.sh [-d] [-r REGION]
#  -d is for debug, -r filters only one region (if your catalog reports several)
#
# You need to have OS_CLOUD set (and endpoint and credentials in clouds.yaml and secure.yaml)
#  or the traditional OS_AUTH_URL, OS_USERNAME etc. set, so openstack catalog list works
# You need to have jq and python[3]-openstackclient tools installed.
#
# (c) Kurt Garloff <t-systems@garloff.de>, 7/2018
# (c) Kurt Garloff <scs@garloff.de>, 2/2021
# License: CC-BY-SA 4.0
#

    OPVER=("Queens" "Rocky" "Stein" "Train" "Ussuri" "Victoria" "Wallaby" "Xena")
  NOVAVER=(2.54 2.61 2.66 2.73 2.80 2.80 2.88 2.89)
GLANCEVER=(2.6  2.7  2.7  2.9  2.10 2.11 2.11 2.11)
CINDERVER=(3.44 3.51 3.56 3.56 3.60 3.61 3.63 3.65)
#NEUTRONVER=()

test -x $(which jq) || exit 2

getToken()
{
	eval $(openstack token issue -f shell) || exit 1
}

getRegions()
{
	REGIONS=$(openstack catalog list -f json | jq '.[] | select(.Name == "nova") | .Endpoints[] | select(.interface == "public") | .region')
	echo "#Regions:" $REGIONS
}

getProject()
{
	PROJECT=$(openstack project list -f value -c ID | head -n1)
	echo "#Project: $PROJECT"
}

if test "$1" == "-d"; then DEBUG=1; shift; fi
if test "$1" == "-c"; then COL=1; shift; fi
if test "$1" == "-r"; then REGION=${2:-$OS_REGION_NAME}; shift; fi

if test "$COL" = 1; then
	RED="\e[0;31m"
	GREEN="\e[0;32m"
	YELLOW="\e[0;33m"
	BRIGHT="\e[0;1m"
	NORM="\e[0;0m"
fi


extractEP()
{
  #echo -en "$endpt"
  if test -n "$DEBUG"; then echo -e "# DEBUG:$type|$name|$endpt"; fi
  oldep="$endpt"
  if ! $(echo -en "$endpt" | grep public >/dev/null 2>&1); then return 1; fi
  if test -n "$REGION"; then
    endpt=$(echo -en "$endpt" | grep -A1 "$REGION" | grep public | head -n1)
    if test -z "$endpt"; then
      # If we have regionalized EPs but are filtering, skip
      if echo "$oldep" | grep 'region\(_id\|\):' >/dev/null 2>&1; then continue; fi
      endpt=$(echo -en "$oldep" | grep public | sort | head -n1)
    fi
  else
    endpt=$(echo -en "$endpt" | grep public | head -n1)
  fi
  #if test -n "$endpt"; then endpt="h${endpt##* h}"; fi
  #echo "$type:$name:$endpt"
  #endpt="${endpt%%  *}"
  #endpt=$(echo -en "$endpt" | jq '.url')
  endpt=$(echo -en "$endpt" | sed 's@^.*,url:\([^,]*\)[,}].*$@\1@')
  endpt=$(echo -en "$endpt" | sed 's@^{url:\([^,]*\),.*$@\1@')
  #echo "$type:$name:$endpt"
  http=${endpt%%://*}
  ept=${endpt#$http://}
  host=${ept%%/*}
  port=${host#*:}
  host=${host%:$port}
  if grep $host /etc/hosts >/dev/null; then
    ipaddr=$(grep $host /etc/hosts | head -n1 | cut -f1)
    resolv="--resolve $host:$port:$ipaddr"
    #echo $resolv
  else
    #echo "no host $host : $port ($ept)"
    resolv=""
  fi
  rept=$http://${ept%%/*}/
  #echo "$type:$name:$rept"
  return 0
}

getuVersion()
{

	VER=$(echo "$VERS" | jq '.versions[] | .id+"("+.min_version+"-"+.version+"):"+.status' 2>/dev/null | tr -d '"'; exit ${PIPESTATUS[1]})
	if test $? != 0; then VER=$(echo "$VERS" | jq '.versions.values[] | .id+"("+.version+"):"+.status' 2>/dev/null | tr -d '"'; exit ${PIPESTATUS[1]}); fi
    	if test $? != 0; then VER="?"; fi
}

getCurrVersion()
{
	#echo "$VERS"
	CURR=$(echo "$VERS" | jq '.versions[] | select(.status=="CURRENT") | .version' 2>/dev/null | tr -d '"'; exit ${PIPESTATUS[1]})
	if test $? != 0 -o "$CURR" == "null"; then CURR=$(echo "$VERS" | jq '.versions[] | select(.status=="CURRENT") | .id' 2>/dev/null | tr -d '"'; exit ${PIPESTATUS[1]}); fi
	if test $? != 0 -o "$CURR" == "null"; then CURR=$(echo "$VERS" | jq '.versions.values[] | select(.status=="CURRENT") | .version' 2>/dev/null | tr -d '"'; exit ${PIPESTATUS[1]}); fi
	if test $? != 0; then CURR="?"; fi
}

findORelease()
{
	NVER=${1#v}
	NVER=$((1000*${NVER%.*}+${NVER##*.}))
	VARR=($2)
	OVER=""
	ONM=""
	for i in $(seq 0 $((${#OPVER[*]}-1)) ); do
		LASTOVER=$OVER
		OVER=$((1000*${VARR[$i]%.*}+${VARR[$i]##*.}))
		if test "$OVER" = "$LASTOVER"; then
			if test $NVER == $OVER; then ONM="$ONM/${OPVER[$i]}"
			elif test $NVER -gt $OVER; then ONM="$ONM/${OPVER[$i]}+"
			else break; fi
		else
			if test $NVER == $OVER; then ONM="${OPVER[$i]}"
			elif test $NVER -gt $OVER; then ONM="${OPVER[$i]}+"
			else break; fi
		fi
	done
	if test -z "$ONM"; then ONM="pre-${OPVER[0]}"; fi
}

getExtension()
{
	EXT=$(curl -m 6 -sS -X GET $resolv -H "Content-Type: application/json" -H "Accept: application/json" \
              -H "X-Auth-Token: $id" -H "X-Language: en-us" "$endpt/extensions" 2>/dev/null)
	RC=$?
	#echo "## DEBUG: /extensions $RC $EXT"
	if echo "$EXT" | grep '[Cc]ode\":' >/dev/null 2>&1 && test "$VER" != "?" -a "$r{VER:0:1}" != "-"; then
		EXT=$(curl -m 6 -sS -X GET $resolv -H "Content-Type: application/json" -H "Accept: application/json" \
        	      -H "X-Auth-Token: $id" -H "X-Language: en-us" "$endpt/${VER%%(*}/extensions" 2>/dev/null)
		if echo "$EXT" | grep '[Cc]ode\":' >/dev/null 2>&1; then EXT=""; return; fi
	fi
	if echo "$EXT" | grep '[Cc]ode\":' >/dev/null 2>&1; then EXT=""; return; fi
	EXT=$(echo "$EXT" | jq '.extensions[].alias' 2>/dev/null)
}

testS3()
{
    read S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY < <(openstack ec2 credentials create -f value -c access -c secret) || return
    S3_HOSTNAME=$host:$port
    export S3_HOSTNAME S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
    s3 list >/dev/null 2>&1
    if test $? == 0; then echo "$type,S3,https:$host:$port,-"; fi
    openstack ec2 credentials delete $S3_ACCESS_KEY_ID

}

getAZs()
{
	AZS=$(openstack availability zone list --$1 -f value -c "Zone Name")
}

getVersion()
{
  #VERS=$(otc.sh custom GET $rept 2>/dev/null)

  VERS=$(curl -m 6 -sS -X GET $resolv -H "Content-Type: application/json" -H "Accept: application/json" \
              -H "X-Auth-Token: $id" -H "X-Language: en-us" "$rept" 2>/dev/null)
  RC=$?
  if test -n "$DEBUG"; then
    echo "# DEBUG:$endpt:$RC/$VERS"
  fi
  if test $RC == 0 && [[ "$VERS" != *40* ]] && [[ "$VERS" != *"API not found"* ]]; then
    getuVersion
    getExtension
    getCurrVersion
  else
    if [[ "$VERS" == *"API not found"* ]]; then
      VER="- ${RED}(ERROR $RC/$(echo $VERS | jq '.message')${NORM})"
    else
      VER="- ${RED}(ERROR $RC/${VERS:0:3})${NORM}"
    fi
  fi
  unset AZS
  case "$name" in
	  "cinderv3") findORelease "$CURR" "${CINDERVER[*]}"
		  getAZs volume;;
	  "nova") findORelease "$CURR" "${NOVAVER[*]}"
		  getAZs compute;;
	  "glance") findORelease "$CURR" "${GLANCEVER[*]}";;
	  "neutron") ONM="";
		  getAZs network;;
	  *) ONM="";;
  esac
  if test -n "$ONM"; then ONM=" ${GREEN}[$ONM]${NORM}"; fi
  echo -e "${BRIGHT}$type,$name,$(echo $endpt | sed s@$PROJECT@\${OS_PROJECT_ID}@),${NORM}"$VER $ONM
  if test -n "$AZS"; then echo "# $name AZs:" $AZS; fi
  if test -n "$EXT"; then echo -en "${YELLOW}# $name extensions: "; echo -n $EXT; echo -e "${NORM}"; fi
  if test "$type" == "identity"; then KEYSTONE_URL="$host:$port"; fi
  if test "$name" == "swift"; then testS3; fi
}

# Extract sections from openssl response
section()
{
	LN=${#1}
	fnd=0
	while IFS="" read line; do
		if test $fnd == 0; then
			if test "${line::$LN}" == "$1"; then
				fnd=1
				echo "$line"
			else
				continue
			fi
		else
			if test "${line::3}" == "---"; then
				fnd=0;
				#if test "$line" != "---"; then echo "$line"; fi
				echo "$line"
				#return
			else
				echo "$line"
			fi
		fi
	done
}

# MAIN

echo -e "${GREEN}#Collecting info for OpenStack Cloud $OS_CLOUD $OS_AUTH_URL${NORM}"
getToken
getRegions
getProject
while IFS="," read type name endpt; do
  extractEP || continue
  getVersion
done < <(openstack catalog list -f json 2>/dev/null | jq 'def tostr(v): v|tostring; .[] | .Type+","+.Name+","+tostr(.Endpoints[])' | tr -d '"' | sed 's/\\n/\\\\n/g' | sort)
if test -n "$KEYSTONE_URL"; then
	RES=$(echo | openssl s_client -connect "$KEYSTONE_URL" 2>/dev/null)
	RC=$?
	if test $RC = 0; then
		echo -n "#SSL Cert signed by: "
		echo "$RES" | section 'Certificate chain' | head -n3 | tail -n1
		echo -n "#SSL Root Cert from: "
		echo "$RES" | section 'Certificate chain' | tail -n2 | head -n1
	fi
fi
