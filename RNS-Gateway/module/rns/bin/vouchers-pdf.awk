# Batch voucher PDF. Reads 13-column voucher rows on stdin and writes a
# complete A4 PDF (8 voucher cards per page) on stdout.
#
#   awk -F'|' -v shop="RNS Internet" -v ssid="RNS" -v off=18000 \
#       -v title="Unused vouchers" -v now=EPOCH -f vouchers-pdf.awk < rows
#
# Every card shows: the RNS logo, shop and Wi-Fi name, the voucher code,
# the package (time and speed), price, START date/time and END date/time.
# For an unused code the start is "when the code is entered" and the end is
# "<duration> after start"; once redeemed the real timestamps are printed.
# Only PDF operators and the 14 standard fonts are used so busybox awk can
# emit it and any phone viewer can open it.

function fdiv(a, b,   q) { q = int(a / b); if (a % b != 0 && ((a < 0) != (b < 0))) q--; return q }
function civil(ts,   local, days, secs, z, era, doe, yoe, y, doy, mp, d, m, hh, mm) {
  # epoch -> "DD Mon YYYY  HH:MM" in the shop's local zone (off seconds)
  local = ts + off
  days = fdiv(local, 86400)
  secs = local - days * 86400
  z = days + 719468
  era = fdiv((z >= 0) ? z : z - 146096, 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = (mp < 10) ? mp + 3 : mp - 9
  if (m <= 2) y++
  hh = int(secs / 3600); mm = int((secs % 3600) / 60)
  return sprintf("%02d %s %04d  %02d:%02d", d, MON[m], y, hh, mm)
}
function dur(sec,   h, m) {
  sec += 0
  if (sec >= 86400 && sec % 86400 == 0) { h = sec / 86400; return h " day" (h == 1 ? "" : "s") }
  h = int(sec / 3600); m = int((sec % 3600) / 60)
  if (h && m) return h "h " m "m"
  if (h) return h " hour" (h == 1 ? "" : "s")
  return m " min"
}
function mb(k) { k += 0; if (k >= 1024) return (int(k / 102.4) / 10) " Mbps"; return k " Kbps" }
function pdfs(s) { gsub(/\\/, "\\\\", s); gsub(/\(/, "\\(", s); gsub(/\)/, "\\)", s); gsub(/[^ -~]/, "?", s); return s }
function txt(font, size, x, y, s) { return sprintf("BT /%s %s Tf %.1f %.1f Td (%s) Tj ET\n", font, size, x, y, pdfs(s)) }
function rgb(r, g, b, fill) { return sprintf("%.3f %.3f %.3f %s\n", r / 255, g / 255, b / 255, fill ? "rg" : "RG") }
function rrect(x, y, w, h, r, op,   k) {
  # rounded rectangle path; op = "f" fill, "S" stroke, "B" both
  k = 0.5523 * r
  return sprintf("%.1f %.1f m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f c %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f c %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f c %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f c h %s\n", \
    x + r, y,  x + w - r, y,  x + w - r + k, y, x + w, y + r - k, x + w, y + r, \
    x + w, y + h - r,  x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h, \
    x + r, y + h,  x + r - k, y + h, x, y + h - r + k, x, y + h - r, \
    x, y + r,  x, y + r - k, x + r - k, y, x + r, y, op)
}
function arc(cx, cy, r, w,   k, s) {
  # upper semicircle stroke (wifi wave) of radius r centred cx,cy
  k = 0.5523 * r
  s = sprintf("%.1f w ", w)
  s = s sprintf("%.1f %.1f m %.1f %.1f %.1f %.1f %.1f %.1f c ", cx - r, cy, cx - r, cy + k, cx - k, cy + r, cx, cy + r)
  s = s sprintf("%.1f %.1f %.1f %.1f %.1f %.1f c S\n", cx + k, cy + r, cx + r, cy + k, cx + r, cy)
  return s
}
function logo(x, y,   s) {
  # 44x44 rounded tile, white RNS + wifi waves
  s = rgb(13, 53, 78, 1) rrect(x, y, 44, 44, 11, "f")
  s = s rgb(112, 228, 219, 0) arc(x + 22, y + 24, 14, 1.6) arc(x + 22, y + 24, 9, 1.6) arc(x + 22, y + 24, 4, 1.6)
  s = s rgb(112, 228, 219, 1) sprintf("%.1f %.1f m %.1f %.1f l %.1f %.1f l h f\n", x + 20, y + 24, x + 24, y + 24, x + 22, y + 20.5)
  s = s rgb(255, 255, 255, 1) txt("HB", 9, x + 12.5, y + 6, "RNS")
  return s
}
function card(x, y, w, h, code, plan, sec, down, up, price, status, act, ends, created, note,   s, shown, startl, endl, statel) {
  shown = substr(code, 1, 4) "-" substr(code, 5)
  s = rgb(255, 255, 255, 1) rrect(x, y, w, h, 12, "f")
  s = s rgb(13, 53, 78, 0) "1.2 w " rrect(x, y, w, h, 12, "S")
  s = s "[3 3] 0 d 0.6 w " rgb(150, 170, 185, 0) sprintf("%.1f %.1f m %.1f %.1f l S\n", x + 12, y + h - 62, x + w - 12, y + h - 62) "[] 0 d\n"
  s = s logo(x + 12, y + h - 56)
  s = s rgb(13, 53, 78, 1) txt("HB", 12, x + 64, y + h - 27, shop)
  s = s rgb(90, 110, 125, 1) txt("H", 8, x + 64, y + h - 39, "Join Wi-Fi \"" ssid "\" (no password)")
  s = s rgb(90, 110, 125, 1) txt("H", 7, x + 64, y + h - 50, "Enter this code on the sign-in page. One code = one phone.")
  s = s rgb(90, 110, 125, 1) txt("HB", 6.5, x + 12, y + h - 76, "VOUCHER CODE")
  s = s rgb(13, 119, 124, 1) txt("CB", 24, x + 12, y + h - 100, shown)
  s = s rgb(20, 33, 27, 1) txt("HB", 10, x + 12, y + h - 116, plan)
  s = s rgb(90, 110, 125, 1) txt("H", 8, x + 12, y + h - 127, dur(sec) "  |  " mb(down) " down / " mb(up) " up" (price != "" ? "  |  Rs " price : ""))
  if (status == "new") {
    startl = "When the code is entered"
    endl = dur(sec) " after start (by the clock)"
    statel = "UNUSED"
  } else {
    startl = (act ~ /^[0-9]+$/ && act > 0) ? civil(act) : "-"
    endl = (ends ~ /^[0-9]+$/ && ends > 0) ? civil(ends) : "-"
    statel = toupper(status)
  }
  s = s rgb(90, 110, 125, 1) txt("HB", 6.5, x + 12, y + 32, "START DATE & TIME") txt("HB", 6.5, x + w / 2 + 4, y + 32, "END DATE & TIME")
  s = s rgb(20, 33, 27, 1) txt("H", 8.5, x + 12, y + 20, startl) txt("H", 8.5, x + w / 2 + 4, y + 20, endl)
  s = s rgb(150, 170, 185, 1) txt("H", 6, x + 12, y + 7, "Generated " ((created ~ /^[0-9]+$/ && created > 0) ? civil(created) : "-") (note != "" ? "  |  " note : ""))
  s = s rgb(13, 119, 124, 1) txt("HB", 6.5, x + w - 12 - length(statel) * 4.2, y + 7, statel)
  return s
}
function flush_page(   len) {
  if (pagebuf == "") return
  npage++
  pagecontent[npage] = header() pagebuf footer()
  pagebuf = ""
}
function header(   s) {
  s = "q\n" rgb(244, 239, 228, 1) "0 0 595 842 re f\n"
  s = s logo(36, 780)
  s = s rgb(13, 53, 78, 1) txt("HB", 16, 90, 804, shop) rgb(90, 110, 125, 1) txt("H", 9, 90, 790, title "  |  Wi-Fi " ssid "  |  printed " civil(now))
  return s
}
function footer() {
  return rgb(150, 170, 185, 1) txt("H", 7, 36, 22, "RNS Gateway  |  page " npage "  |  voucher time runs by the clock from first use; keep this sheet safe, each code works on one phone only") "Q\n"
}
BEGIN {
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MON, " ")
  if (shop == "") shop = "RNS Internet"
  if (ssid == "") ssid = "RNS"
  if (title == "") title = "Vouchers"
  off += 0; now += 0
  cols = 2; rows = 4; cw = 257; ch = 168; gx = 9; gy = 10; x0 = 36; ytop = 770
  n = 0; pagebuf = ""; npage = 0
}
NF >= 6 && $1 != "" {
  slot = n % (cols * rows)
  if (slot == 0 && n > 0) flush_page()
  c = slot % cols; r = int(slot / cols)
  x = x0 + c * (cw + gx); y = ytop - (r + 1) * ch - r * gy
  pagebuf = pagebuf card(x, y, cw, ch, $1, $2, $3, $4, $5, $13, $6, $9, $10, $11, $12)
  n++
}
END {
  if (n == 0) pagebuf = rgb(90, 110, 125, 1) txt("H", 12, 36, 740, "No vouchers match this selection.")
  flush_page()
  # Objects: 1 catalog, 2 pages, 3 H, 4 HB, 5 CB, then per page: page obj + content obj
  nobj = 5 + 2 * npage
  out = "%PDF-1.4\n%RNS-Gateway\n"
  kids = ""
  for (p = 1; p <= npage; p++) kids = kids (5 + 2 * p - 1) " 0 R "
  obj[1] = "<< /Type /Catalog /Pages 2 0 R >>"
  obj[2] = "<< /Type /Pages /Kids [ " kids "] /Count " npage " >>"
  obj[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
  obj[4] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
  obj[5] = "<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>"
  for (p = 1; p <= npage; p++) {
    po = 5 + 2 * p - 1; co = po + 1
    obj[po] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /H 3 0 R /HB 4 0 R /CB 5 0 R >> >> /Contents " co " 0 R >>"
    obj[co] = "<< /Length " length(pagecontent[p]) " >>\nstream\n" pagecontent[p] "endstream"
  }
  for (i = 1; i <= nobj; i++) {
    offs[i] = length(out)
    out = out i " 0 obj\n" obj[i] "\nendobj\n"
  }
  xref = length(out)
  out = out "xref\n0 " (nobj + 1) "\n0000000000 65535 f \n"
  for (i = 1; i <= nobj; i++) out = out sprintf("%010d 00000 n \n", offs[i])
  out = out "trailer\n<< /Size " (nobj + 1) " /Root 1 0 R >>\nstartxref\n" xref "\n%%EOF\n"
  printf "%s", out
}
