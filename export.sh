#!/bin/sh
export ASNLOOKUP_API_TOKEN=$(op read "op://Private/ASN Lookup apikey/password")
export UNIFI_API_TOKEN=$(op read "op://Private/unifi.ui.com/apikey")
