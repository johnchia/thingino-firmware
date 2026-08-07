#!/bin/sh
#
# SigmaStar version of thingino-webui's json-sensor-info.cgi.
#
# Two things in the stock CGI are Ingenic-specific:
#
#   1. the sensor name is read from /proc/jz/sensor/sensor0/name, which is
#      created by Ingenic's tx-isp driver and does not exist here;
#   2. the tuning file is looked for at /etc/sensor/<sensor>-<soc>.bin, which
#      is the Ingenic layout. sigmastar-sdk-infinity6e installs the ISP
#      tuning blobs as /etc/sensors/<sensor>.bin -- plural directory, and no
#      SoC in the filename, because the blob is per-sensor and all six ship on
#      every image for autodetect.
#
# The JSON shape is deliberately unchanged so the page consuming it needs no
# edit. soc_model/soc_family keep the stock meaning: `soc -f` on Ingenic
# returns a family-ish string ("t31") and soc_family is that with the digits
# stripped, so here they come out "infinity6e" and "infinity".

. /var/www/x/auth.sh
require_auth

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-cache\r\n'
printf 'Connection: close\r\n'
printf '\r\n'

SENSOR_MODEL=$(sensor name 2>/dev/null)
SOC_MODEL=$(soc -f 2>/dev/null)
SOC_FAMILY=$(echo "$SOC_MODEL" | sed 's/[0-9x].*//' | tr '[:upper:]' '[:lower:]')

SENSOR_IQ_PATH="/etc/sensors"
SENSOR_IQ_FILE="${SENSOR_MODEL}.bin"
SENSOR_FILE_FULL_PATH="${SENSOR_IQ_PATH}/${SENSOR_IQ_FILE}"

if [ -n "$SENSOR_MODEL" ] && [ -f "$SENSOR_FILE_FULL_PATH" ]; then
  FILE_MD5=$(md5sum "$SENSOR_FILE_FULL_PATH" 2>/dev/null | cut -d' ' -f1)
  if [ -z "$FILE_MD5" ]; then
    FILE_MD5="Unknown"
  fi
elif [ -z "$SENSOR_MODEL" ]; then
  FILE_MD5="Sensor not detected"
else
  FILE_MD5="File not found"
fi

cat << EOF
{
  "sensor_model": "$SENSOR_MODEL",
  "soc_model": "$SOC_MODEL",
  "soc_family": "$SOC_FAMILY",
  "file_path": "$SENSOR_FILE_FULL_PATH",
  "md5": "$FILE_MD5"
}
EOF
