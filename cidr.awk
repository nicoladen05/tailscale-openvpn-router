#!/usr/bin/awk -f
# IPv4 CIDR helpers used by entrypoint.sh.
#
# Subtract a set of CIDRs from another set and print the result as a
# comma-separated list of CIDRs:
#   awk -f cidr.awk -v mode=exclude -v routes="10.0.0.0/8" -v exclude="10.1.2.3/32"
#
# Print "network netmask" for a CIDR (the format openvpn's --route expects):
#   awk -f cidr.awk -v mode=netmask -v routes="10.0.0.0/8"
#
# Entries may be separated by commas and/or whitespace. A bare address is
# treated as a /32.

function ip2n(s,    a) {
  split(s, a, ".")
  return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
}

function n2ip(n) {
  return int(n / 16777216) % 256 "." int(n / 65536) % 256 "." int(n / 256) % 256 "." n % 256
}

# Parses a CIDR into P_NET/P_LEN, normalizing away any host bits.
function parse(s,    a, size) {
  if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) {
    print "invalid IPv4 CIDR: " s > "/dev/stderr"
    exit 1
  }
  if (split(s, a, "/") == 1) a[2] = 32
  P_LEN = a[2] + 0
  if (P_LEN > 32) {
    print "invalid prefix length: " s > "/dev/stderr"
    exit 1
  }
  size = 2 ^ (32 - P_LEN)
  P_NET = int(ip2n(a[1]) / size) * size
}

# Appends net/len minus enet/elen to the NEXT list.
function subtract(net, len, enet, elen,    size, half) {
  size = 2 ^ (32 - len)
  if (enet + 2 ^ (32 - elen) <= net || enet >= net + size) {
    # No overlap, keep the block as-is.
    NEXT_NET[++NEXT_N] = net
    NEXT_LEN[NEXT_N] = len
    return
  }
  # Block lies entirely within the excluded range, drop it.
  if (elen <= len) return
  # Excluded range is inside this block, split it in half and recurse.
  half = size / 2
  subtract(net, len + 1, enet, elen)
  subtract(net + half, len + 1, enet, elen)
}

BEGIN {
  nr = split(routes, r, /[,[:space:]]+/)

  if (mode == "netmask") {
    for (i = 1; i <= nr; i++) {
      if (r[i] == "") continue
      parse(r[i])
      print n2ip(P_NET), n2ip(2 ^ 32 - 2 ^ (32 - P_LEN))
    }
    exit 0
  }

  n = 0
  for (i = 1; i <= nr; i++) {
    if (r[i] == "") continue
    parse(r[i])
    NET[++n] = P_NET
    LEN[n] = P_LEN
  }

  ne = split(exclude, e, /[,[:space:]]+/)
  for (j = 1; j <= ne; j++) {
    if (e[j] == "") continue
    parse(e[j])
    NEXT_N = 0
    for (i = 1; i <= n; i++) subtract(NET[i], LEN[i], P_NET, P_LEN)
    n = NEXT_N
    for (i = 1; i <= n; i++) {
      NET[i] = NEXT_NET[i]
      LEN[i] = NEXT_LEN[i]
    }
  }

  out = ""
  for (i = 1; i <= n; i++) out = out (out == "" ? "" : ",") n2ip(NET[i]) "/" LEN[i]
  print out
}
