# RNS-OS login banner.
# Tells whoever lands on the console or over SSH where the shop is and what
# state it is in, without them having to remember any paths.

if [ -x /usr/local/sbin/rns-os-ctl ]; then
  printf '\n'
  if [ -r /etc/rns/admin-password.txt ]; then
    printf '  Staff panel password (change it in Settings > Password):\n'
    sed -n 's/^password: /    /p' /etc/rns/admin-password.txt 2>/dev/null
  fi
  _rns_gip=$(sed -n 's/^GUEST_IP=//p' /var/lib/rns/config.env 2>/dev/null | head -n 1)
  _rns_gport=$(sed -n 's/^PORTAL_PORT=//p' /var/lib/rns/config.env 2>/dev/null | head -n 1)
  if [ -n "$_rns_gip" ]; then
    printf '  Staff panel   http://%s:%s/admin\n' "$_rns_gip" "${_rns_gport:-8080}"
  fi
  printf '  Commands      rns status   |   rns os status   |   rns os diag\n'
  printf '\n'
  unset _rns_gip _rns_gport
fi
