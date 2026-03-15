#!/bin/sh
set -eu
VERBOSE=${VERBOSE:-0}
: "${UNIFI_API_TOKEN}"
: "${ASNLOOKUP_API_TOKEN}"

UNIFI_API_BASE="https://api.ui.com"
alias unifi='curl -sSf -H "X-API-KEY: ${UNIFI_API_TOKEN}"'

# Resolve host ID
if [ -n "${UNIFI_HOST_ID:-}" ]; then
	echo "[INFO] Using configured host ID: ${UNIFI_HOST_ID}" >&2
else
	echo "[INFO] Resolving host ID from Site Manager API..." >&2
	HOSTS_RESPONSE=$(unifi "${UNIFI_API_BASE}/v1/hosts" -H 'Accept: application/json')
	HOST_COUNT=$(echo "${HOSTS_RESPONSE}" | jq '.data | length')
	if [ "${HOST_COUNT}" -eq 0 ]; then
		echo "[ERROR] No hosts found in your UniFi account." >&2
		exit 1
	elif [ "${HOST_COUNT}" -eq 1 ]; then
		UNIFI_HOST_ID=$(echo "${HOSTS_RESPONSE}" | jq -r '.data[0].id')
		HOST_NAME=$(echo "${HOSTS_RESPONSE}" | jq -r '.data[0].reportedState.hostname // "unknown"')
		echo "[INFO] Found 1 host: ${HOST_NAME} (${UNIFI_HOST_ID})" >&2
	else
		echo "[ERROR] Found ${HOST_COUNT} hosts. Set \$UNIFI_HOST_ID to select one:" >&2
		echo "${HOSTS_RESPONSE}" | jq -r '.data[] | "  \(.id)  \(.reportedState.hostname // "unknown")"' >&2
		exit 1
	fi
fi

CONNECTOR_BASE="${UNIFI_API_BASE}/v1/connector/consoles/${UNIFI_HOST_ID}"

# Verify UniFi API connection credential
if ! unifi "${CONNECTOR_BASE}/proxy/network/integration/v1/info" >/dev/null 2>&1; then
	echo "[ERROR] Failed to request API information via Cloud Connector. Please check if \$UNIFI_API_TOKEN is configured correctly and has Network access." >&2
	unifi "${CONNECTOR_BASE}/proxy/network/integration/v1/info"
	exit 1
fi

# Process rules
RULES_ALL=$(unifi -X GET "${CONNECTOR_BASE}/proxy/network/v2/api/site/default/trafficroutes" -H 'Accept: application/json' | jq -c 'map(select(.enabled))')
MATCHING_RULE_NAMES=$(echo "${RULES_ALL}" | jq -r .[].description | grep '^AS[0-9]* ' | sort | uniq)
if [ "${VERBOSE}" -ne 0 ]; then
	echo "[TRACE] MATCHING_RULE_NAMES=${MATCHING_RULE_NAMES}" >&2
fi
ASNS=$(echo "$MATCHING_RULE_NAMES" | awk '{print $1}' | sort | uniq)
if [ "${VERBOSE}" -ne 0 ]; then
	echo "[TRACE] ASNS=${ASNS}" >&2
fi

for ASN in ${ASNS}; do
	if [ "${VERBOSE}" -ne 0 ]; then
		echo "[TRACE] ASN=${ASN}" >&2
	fi
	ASN_RULE_NAMES=$(echo "${MATCHING_RULE_NAMES}" | grep "^${ASN} ")
	if [ "${VERBOSE}" -ne 0 ]; then
		echo "[TRACE] ASN_RULE_NAMES=${ASN_RULE_NAMES}" >&2
	fi
	ASNLOOKUP=$(curl -sSLf -X GET "https://asn-lookup.p.rapidapi.com/api?asn=${ASN}" -H "x-rapidapi-key: ${ASNLOOKUP_API_TOKEN}") \
		|| (echo "[WARN] Failed to fetch information from ASN Lookup. Skipping ${ASN}." >&2; exit 1) || continue
	ASN_RULE_NAME_PREFIX=$(echo "${ASNLOOKUP}" | jq -r '.[0] | "AS\(.asnHandle) \(.asnName)"')
	if [ "${VERBOSE}" -ne 0 ]; then
		echo "[TRACE] ASN_RULE_NAME_PREFIX=${ASN_RULE_NAME_PREFIX}" >&2
	fi
	echo "${ASN_RULE_NAMES}" | while IFS= read -r ASN_RULE_NAME ; do
		if [ "${VERBOSE}" -ne 0 ]; then
			echo "[TRACE] ASN_RULE_NAME=${ASN_RULE_NAME}" >&2
		fi
		if ! echo "${ASN_RULE_NAME}" | grep -Eq "^${ASN_RULE_NAME_PREFIX}( IPv[46])?\$"; then
			echo "[WARN] Rule name mismatch. Expect: \"${ASN_RULE_NAME_PREFIX}\", found: \"${ASN_RULE_NAME}\". Skipping ${ASN_RULE_NAME}." >&2
			continue
		fi
		NEW_IPS="[]"
		if [ "${VERBOSE}" -ne 0 ]; then
			echo "[TRACE] NEW_IPS=[]" >&2
		fi
		if [ "${ASN_RULE_NAME}" = "${ASN_RULE_NAME_PREFIX}" ] || [ "${ASN_RULE_NAME}" = "${ASN_RULE_NAME_PREFIX} IPv4" ]; then
			IPV4_IPS=$(echo "${ASNLOOKUP}" | jq -r '.[0] | .ipv4_prefix[]' | aggregate6 | jq -cRn '[inputs | select(length > 0)] | map({"ip_or_subnet":.,"ip_version":"v4","port_ranges":[],"ports":[]})')
			NEW_IPS=$(printf '%s\n%s' "${NEW_IPS}" "${IPV4_IPS}" | jq -sc 'add')
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] NEW_IPS+=IPv4" >&2
			fi
		fi
		if [ "${ASN_RULE_NAME}" = "${ASN_RULE_NAME_PREFIX}" ] || [ "${ASN_RULE_NAME}" = "${ASN_RULE_NAME_PREFIX} IPv6" ]; then
			IPV6_IPS=$(echo "${ASNLOOKUP}" | jq -r '.[0] | .ipv6_prefix[]' | aggregate6 | jq -cRn '[inputs | select(length > 0)] | map({"ip_or_subnet":.,"ip_version":"v6","port_ranges":[],"ports":[]})')
			NEW_IPS=$(printf '%s\n%s' "${NEW_IPS}" "${IPV6_IPS}" | jq -sc 'add')
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] NEW_IPS+=IPv6" >&2
			fi
		fi
		if [ "${VERBOSE}" -ne 0 ]; then
			echo "[TRACE] NEW_IPS=${NEW_IPS}" >&2
		fi
		if [ "${NEW_IPS}" = "[]" ]; then
			echo "[INFO] No IP exists for \"${ASN_RULE_NAME}\", using 192.0.2.0/32 as a placeholder. This rule can be disabled or removed." >&2
			NEW_IPS='[{"ip_or_subnet":"192.0.2.0/32","ip_version":"v4","port_ranges":[],"ports":[]}]'
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] NEW_IPS=[192.0.2.0/32]" >&2
			fi
		fi
		ASN_RULE_IDS=$(echo "${RULES_ALL}" | jq -r '.[] | select(.description == "'"${ASN_RULE_NAME}"'")._id')
		if [ "${VERBOSE}" -ne 0 ]; then
			echo "[TRACE] ASN_RULE_IDS=${ASN_RULE_IDS}" >&2
		fi
		if [ "$(echo "${ASN_RULE_IDS}" | grep -c "^")" -gt 1 ]; then
			echo "[INFO] Found multiple rule entries of \"${ASN_RULE_NAME}\". Updating all matching rules." >&2
		fi
		for ASN_RULE_ID in ${ASN_RULE_IDS}; do
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] ASN_RULE_ID=${ASN_RULE_ID}" >&2
			fi
			ASN_RULE_OLD=$(echo "${RULES_ALL}" | jq -c '.[] | select(._id == "'"${ASN_RULE_ID}"'")')
			OLD_IPS_LIST=$(echo "${ASN_RULE_OLD}" | jq -r ".ip_addresses[].ip_or_subnet" | sort -V)
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] OLD_IPS_LIST=${OLD_IPS_LIST}" >&2
			fi
			NEW_IPS_LIST=$(echo "${NEW_IPS}" | jq -r ".[].ip_or_subnet" | sort -V)
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] NEW_IPS_LIST=${NEW_IPS_LIST}" >&2
			fi
			CHANGESET=$(diff -u0 /dev/fd/3 3<<-EOF /dev/fd/4 4<<-EOF | grep '^[+-][^+-]' || true
${OLD_IPS_LIST}
EOF
${NEW_IPS_LIST}
EOF
			)
			if [ "${VERBOSE}" -ne 0 ]; then
				echo "[TRACE] CHANGESET=${CHANGESET}" >&2
			fi
			if [ -n "${CHANGESET}" ]; then
				if [ "${VERBOSE}" -ne 0 ]; then
					echo "[TRACE] CHANGESET>0" >&2
				fi
				ASN_RULE_NEW=$(printf '%s\n%s' "${ASN_RULE_OLD}" "${NEW_IPS}" | jq -sc '.[0].ip_addresses = .[1] | .[0]')
				ASN_RULE_URL="${CONNECTOR_BASE}/proxy/network/v2/api/site/default/trafficroutes/${ASN_RULE_ID}"
				if [ "${VERBOSE}" -ne 0 ]; then
					echo "[TRACE] ASN_RULE_URL=${ASN_RULE_URL}" >&2
				fi
				echo "${ASN_RULE_NEW}" | unifi -X PUT "${ASN_RULE_URL}" -d @- -H 'Accept: application/json' -H 'Content-Type: application/json' >/dev/null
				printf "%s [%s]:\n%s\n" "${ASN_RULE_NAME}" "${ASN_RULE_ID}" "${CHANGESET}"
			fi
		done
	done
done
