#!/system/bin/sh
# Magisk "Action" button. Opens the staff panel on the phone.
AM=/system/bin/am
[ -x "$AM" ] || AM=am
"$AM" start -a android.intent.action.VIEW -d "http://127.0.0.1:8080/admin" >/dev/null 2>&1
echo "RNS admin: http://127.0.0.1:8080/admin"
echo "Customer page: http://127.0.0.1:8080/"
