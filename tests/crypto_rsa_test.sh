#!/usr/bin/env bash
# tests/crypto_rsa_test.sh — #2096: RSASSA-PKCS1-v1_5 und RSASSA-PSS nach
# RFC 8017, nativ.
#
# Beide Richtungen, wie es die Sache verlangt:
#   1. FREMDE Signaturen (python-cryptography, 2048 und 3072 Bit, SHA-256/384
#      /512, beide Verfahren) muessen angenommen werden.
#   2. Jede dieser Signaturen mit einem gekippten Bit, und jeder mit einem
#      gekippten Hashbyte, muss ABGEWIESEN werden. Ein Test nur des guten
#      Falls waere auch von einer Pruefung erfuellt, die immer true liefert.
#   3. EIGENE PKCS#1-Signaturen sind bestimmt und werden byteweise gegen die
#      festgeschriebenen Erwartungen gehalten (sie stammen aus
#      python-cryptography, nicht aus einem frueheren Lauf dieses Codes).
#   4. EIGENE Signaturen beider Verfahren werden zusaetzlich von `openssl
#      pkeyutl` geprueft — PSS ist zufaellig gesalzen und darum nur so
#      pruefbar.
#   5. Abgewiesen werden muessen: unbekannte Hashlaenge (20), falsche
#      Signaturlaenge.
# Schluessel und Fremdsignaturen stehen unten im Test, der Lauf braucht kein
# Netz. `openssl` fehlt → Punkt 4 wird uebersprungen, der Rest laeuft.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rsa"
cat > "$TMP/rsa/k2048.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC2fFj4cnuVNDca
EXH4aWS1TGXCz1FCPw2V4dYN/083Yz7hoLM4wKvqwHzXvbqd6VKedBI9+gpdk45D
XirjbrKsT/HRVfT9uGnAGU+cUCogDDtvBWDiImb6sleeKynPqa9yOfSCSVQqO4Wl
9Npuy4sapXgIScCV9KOi/Byy0U9epHzxI4EtA9frkxcRgQX7K3M5wMm9yciGtEgg
hYZg9+68NhPGA7AVAwWJWY1beqfdkSEU289sRXj2Kmm1bzwhZFgSRoq7dg/yabFx
9pyDee5whP2G694kkFy/6mGiQpKHjUhAdh2WwSMiuAF+dwQuEwZ3FmAH5HxkHvHW
RRjeucsJAgMBAAECggEAL6HsjUlAtdTvzxefoqJL/cDHzR5VTQ/tSWKt/3BVapU2
vCk4rscn+LouvBeThxV4kdClVFUYcI2L9Ey3sC7cZ3rkmWow7Ss+OzzAGYKZRE09
FEEYpV4qeCSmFyyYGNLnb07uYjWmyPFJdOShQYtSr21ik/NAWEQHlIrvKMPWzlJ6
AIqwYkI1cm/0clNOAqCgVt8s3PUsGbyfjZAoXnB6xX1wTKowzwXSIVn2B8leKYFg
DiG7tJgVoHYNN1buSn9uDdc4Q1WnRdgwIsHt0rZzs0bp+776IU3/TLO4rb/IOpHY
XX9M4c4yTiSc591ZO7CdIsL5bKlehqIEg1Sd39MsywKBgQD7mjcGQ/mmEW7wi1Mf
3xClLtq4yCUB3HIK/AnK4R0QsJDbY1vCAwBVmqANtWTr98L9519je3ia35xGjIvB
Sh2bcxsZwShiAkqrVxXJjZpvlri1iRvW4I8CJlAHVg5ilQ4usSU+bCOqVTqun3yU
D7dUtuyn2vCbHgwejt/P6jJ/8wKBgQC5rN9ugzVnPsw5ld+3X/ghm4kwguu/PHyR
f3IDfMoUtLPhtq9cStp3YH7FHOi6L6KFU3SglTWt+YcdtszX3Wif2ta8yjyj3dO0
dr9xedDiJ9L7TttGx9pn3vz5beA39piGxvvGULzKyKRf1MLENO2EQE6mg8h4khDF
3W76sjuEEwKBgFwVmyHt6wb+xm2/cFLv3zW1qlOK3RCLUCn5CNR6A5tCJCJHgSPG
2W57Qy0BQMikS3eGIQFWBVQZlyay9ctuhtuIC1knutH0KMQBAXZdHzLMJRo77jZ8
xZpxz0SAGI+4IhKwvwLTrVIAE5Qpxvyhq+WTdZYRqZH8M09T11JPUuBFAoGAdYKQ
Qbvun3IiBEvzM3YcbwCl2bryAq0AVYEoIkbnCiW3NqHM6AdDrou2j3+VVshw/hps
VHk6aOnkdozLpc6tuYXho8gGitsIck05KlMjPQ5hO8WTh39SnayFxEKixiheLeZf
UAqnAVvsk+3uegjZTXr5i+8ZgB1JWkCjTSxh+FsCgYBnR6LhzHiiuPx5PVKbPzRx
WGWTJi5O6uw/V4AOocuNSLbmwFOZVxOSqFIELiRYczBZnXg13HzKuSJ9wgibJ+Jc
jb/8yaf0UxYF6lHpfSRTb3nsvAoRFy38zxO18S/7+7NbD8tNK/K8+vLI/P2y//7G
YU/S9gbTrF2XSeTLU8BvCw==
-----END PRIVATE KEY-----
PEMEOF
cat > "$TMP/rsa/k2048_pkcs1.pem" <<'PEMEOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEAtnxY+HJ7lTQ3GhFx+GlktUxlws9RQj8NleHWDf9PN2M+4aCz
OMCr6sB81726nelSnnQSPfoKXZOOQ14q426yrE/x0VX0/bhpwBlPnFAqIAw7bwVg
4iJm+rJXnispz6mvcjn0gklUKjuFpfTabsuLGqV4CEnAlfSjovwcstFPXqR88SOB
LQPX65MXEYEF+ytzOcDJvcnIhrRIIIWGYPfuvDYTxgOwFQMFiVmNW3qn3ZEhFNvP
bEV49ipptW88IWRYEkaKu3YP8mmxcfacg3nucIT9huveJJBcv+phokKSh41IQHYd
lsEjIrgBfncELhMGdxZgB+R8ZB7x1kUY3rnLCQIDAQABAoIBAC+h7I1JQLXU788X
n6KiS/3Ax80eVU0P7Ulirf9wVWqVNrwpOK7HJ/i6LrwXk4cVeJHQpVRVGHCNi/RM
t7Au3Gd65JlqMO0rPjs8wBmCmURNPRRBGKVeKngkphcsmBjS529O7mI1psjxSXTk
oUGLUq9tYpPzQFhEB5SK7yjD1s5SegCKsGJCNXJv9HJTTgKgoFbfLNz1LBm8n42Q
KF5wesV9cEyqMM8F0iFZ9gfJXimBYA4hu7SYFaB2DTdW7kp/bg3XOENVp0XYMCLB
7dK2c7NG6fu++iFN/0yzuK2/yDqR2F1/TOHOMk4knOfdWTuwnSLC+WypXoaiBINU
nd/TLMsCgYEA+5o3BkP5phFu8ItTH98QpS7auMglAdxyCvwJyuEdELCQ22NbwgMA
VZqgDbVk6/fC/edfY3t4mt+cRoyLwUodm3MbGcEoYgJKq1cVyY2ab5a4tYkb1uCP
AiZQB1YOYpUOLrElPmwjqlU6rp98lA+3VLbsp9rwmx4MHo7fz+oyf/MCgYEAuazf
boM1Zz7MOZXft1/4IZuJMILrvzx8kX9yA3zKFLSz4bavXErad2B+xRzoui+ihVN0
oJU1rfmHHbbM191on9rWvMo8o93TtHa/cXnQ4ifS+07bRsfaZ978+W3gN/aYhsb7
xlC8ysikX9TCxDTthEBOpoPIeJIQxd1u+rI7hBMCgYBcFZsh7esG/sZtv3BS7981
tapTit0Qi1Ap+QjUegObQiQiR4Ejxtlue0MtAUDIpEt3hiEBVgVUGZcmsvXLbobb
iAtZJ7rR9CjEAQF2XR8yzCUaO+42fMWacc9EgBiPuCISsL8C061SABOUKcb8oavl
k3WWEamR/DNPU9dST1LgRQKBgHWCkEG77p9yIgRL8zN2HG8Apdm68gKtAFWBKCJG
5woltzahzOgHQ66Lto9/lVbIcP4abFR5Omjp5HaMy6XOrbmF4aPIBorbCHJNOSpT
Iz0OYTvFk4d/Up2shcRCosYoXi3mX1AKpwFb7JPt7noI2U16+YvvGYAdSVpAo00s
YfhbAoGAZ0ei4cx4orj8eT1Smz80cVhlkyYuTursP1eADqHLjUi25sBTmVcTkqhS
BC4kWHMwWZ14Ndx8yrkifcIImyfiXI2//Mmn9FMWBepR6X0kU2957LwKERct/M8T
tfEv+/uzWw/LTSvyvPryyPz9sv/+xmFP0vYG06xdl0nky1PAbws=
-----END RSA PRIVATE KEY-----
PEMEOF
cat > "$TMP/rsa/k3072.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
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
1xqsJ51TSDEdTvlSbk2boA==
-----END PRIVATE KEY-----
PEMEOF
cat > "$TMP/rsa/p2048.pem" <<'PEMEOF'
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtnxY+HJ7lTQ3GhFx+Glk
tUxlws9RQj8NleHWDf9PN2M+4aCzOMCr6sB81726nelSnnQSPfoKXZOOQ14q426y
rE/x0VX0/bhpwBlPnFAqIAw7bwVg4iJm+rJXnispz6mvcjn0gklUKjuFpfTabsuL
GqV4CEnAlfSjovwcstFPXqR88SOBLQPX65MXEYEF+ytzOcDJvcnIhrRIIIWGYPfu
vDYTxgOwFQMFiVmNW3qn3ZEhFNvPbEV49ipptW88IWRYEkaKu3YP8mmxcfacg3nu
cIT9huveJJBcv+phokKSh41IQHYdlsEjIrgBfncELhMGdxZgB+R8ZB7x1kUY3rnL
CQIDAQAB
-----END PUBLIC KEY-----
PEMEOF
cat > "$TMP/rsa/p3072.pem" <<'PEMEOF'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAhWtvT9v+oqEpZzX5MmUS
W6ecEAARNeW1twBtiKxxprSbBvEdaUDV18jYTGdZME2PorR8qvHj7cczz4MPoZcn
IJn2LQbCu4UPOfS44Y4yvEPpE6x5oJRHq3nvD8N2o/BYy3k1I/pcx3yj0UdE6smh
EW0nBQGUJ2ILuXmJyU2QviDg9aHgbZ4KNeki+C55+N4bkj7E7rqeilNr/uZJa6uY
OmMFkR0RhvcLvgv3DjO2Ws7o6DBdD4RprdIqNtRxv8ldPTzRXs91d9WwFQKh9S+U
5IsgzW+5lFL74iIXieojpXaNIW9oUH9RHPWy/2wyGbh1586pJAvyGVc+qyLU+RgP
RtybZCBtNAP5IY3Tu4CD/3SwN6T0LObXHcSdMkXh92Wlr6kPXjk5Mquv1X5ODeZz
RVVKlm4fCLYr/ZqcCA+fe7Y6PjT3LA5tmMBaTF3iwKMgJByDzJhWhJnM2QOFonnZ
PM4sKIhBVLhrRbavt/Oq6awX5zqfROyPWtiTJOOWCuyRAgMBAAE=
-----END PUBLIC KEY-----
PEMEOF
base64 -d > "$TMP/rsa/msg.bin" <<'B64EOF'
BSRDYoGgv979HDtaeZi31vUUM1JxkK/O7QwrSmmIp8blBCNCYYCfvt38GzpZeJe21fQTMlFwj67N
7AsqSWiHpsXkAyJBYH+evdz7GjlYd5a11PMSMVBvjq3M6wopSGeGpcTjAiFAX36dvNv6GThXdpW0
0/IRME9ujazL6gkoR2aFpMPiASA/Xn2cu9r5GDdWdZSz0vEQL05tjKvK6QgnRmWEo8LhAB8+XXyb
utn4FzZVdJOy0fAPLk1si6rJ6AcmRWSDosHg/x49XHuaudj3FjVUc5Kx0O8OLUxriqnI5wYlRGOC
ocDf/h08W3qZuNf2FTRTcpGwz+4NLEtqiajH5gUkQ2KBoL/e/Rw7WnmYt9b1FDNScZCvzu0MK0pp
iKfG5QQjQmGAn77d/Bs6
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha256_pkcs1.bin" <<'B64EOF'
FfDce+pFoKsxGY2/HkVpEvnGdJLotrgpCNDOw3H68lah153WOpDk7Y/m2+xkXPZ4Ysxo6QEm965M
ftfQKhdWDYYm44EZ622+Vrb/jVKtwUgXGm7Z1emqvfNUGTinsCF5yrXFAJvAcgbqCAwdUJG1LDXg
DhB8w4eLRAiKI6nVyoO1nnPQm+7Zf4uS1xRgnzsL9pwpl756w1pR7siC8cGAVde3pj0OGQ1rcf5A
cnI6UEk7uwT323aiDKcrM4lJabzus2Y85Zta24NX4h2rlGWro2m+ul8OQ0eS8HWvvV/aJexVdK57
KpHj5xRtoJHESqiMZnLg45F+SsCfBUkeb544Bw==
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha256_pss.bin" <<'B64EOF'
G94Ugu4NutqVLN9idfw66SdrtpjM3h2dbJ0g5ob+5EDkJKnJG/6Al+5BC4s3fJFq6Y4EntQdB0C6
06GR8DmFs+pnjrdKUpYo278F/N32A4A/wzUyTPEAVKjz8+LSdQZ4vU0KObvzUCkv1TBI5Wf7EPBv
f/YZzhp0cW3JWXf1tLm8mPd/kU5wHHN+pSoa7KitYRfjRkxMYgpslwNLTcZMAOo+UCIW+iELpHm9
DvpOCiAVWPYDM0QwBIPfDPlOYngi7vODI2UADIFXeMl1Iyw85tYSjqZ74+2dZmiirB7m+cf7o2Ij
fRZjLSsob3liuPfYnNuptozEJQfByMAmMrYSjA==
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha384_pkcs1.bin" <<'B64EOF'
ftWBn6jKAB9LVAm4RiJxpH8Vrmnd81qL5ELgfet2C1rBLYHY9bBj+T+BPsduyBxbfxTHIAuH+Mo2
+H4Jh1KC/NHf5B1GYTBcdAecTmlj29q3uyNRAkkzj/91BKb38BLXE4kfiyjf56BHk7JfYXsWe0NJ
g0ODbUMoz+JU8bnDQMJaO3Ik8G8ZHoCGVAPevSgIyJCoxnqluvKZb9HUh0PXKsCJ93tmovV22RoY
fvuPur6ShU03g2h17wz0HfPLXoUl/bVPImQJXiYXXPGmv/rlg2lzt49uT2j5YcHe87+2lVpw25qg
yLznz9r+rgBsypmyktbC5H2vmnZgeTaNYd61uw==
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha384_pss.bin" <<'B64EOF'
WJ5lXjuXXMclcXRvKkWGLPgSQhJo8+A9RpTo9gFpLTPlQ1deAP++7Q0EINitkhLEYqjA9XHWrF1K
NCISAQ+RHxZhJKmPcy+yHwB5okijp98FOQTrKuGzggszqnnD8EJVXyZ253r/u6MbD+DGLuvWsXkI
yt9LNFtY6Sep+Q/W/eQKaYLVuL+/BRrKCULo5xAcdaQ70IE/YvSclM+y+arDf5v1zIb2kiQ3W5mx
T8JvB3ViRHrAzeNeegcLy9JSa6W/6XC0FvyIJ95p0ggCy9gCK4HYDZD7cIVwS7C/L1icKS+RxuYS
kJVtiOiAHbmYfX5CmAVQlqd8oQMTxxn5LFvSgw==
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha512_pkcs1.bin" <<'B64EOF'
RCtqrfAB3a/4T0XDb6gaCd2E+HAGuTOFU2g36t0d3aTg9sE2vi8iOOZfWGC6964nYpRDSiTtJrmP
6WsjINJhnuNV1Jad0SjR26UNvmsOJATNf1qFH6aJeQmBf/caBY8v071w9Xy9n4lF58G+tjjlAmDz
O3q4hl7g7hZojowHvtC1yp+N+IswAGSjDXqIlVkSBVDehoK4DvdAVqhRhZSs7a9WL7EwC4Ct8qdQ
G2PESgUqpWUIiFBfDnZLkZNxHmBANqLS0TeUu/LORcrYZm7jwjzcut8FBVONGNMGs+Rwnn5NlHDX
QSNexXyuvQZlysNUM6jHaT2ySyaraZYssbDQ8Q==
B64EOF
base64 -d > "$TMP/rsa/sig2048_sha512_pss.bin" <<'B64EOF'
TFNp9BM9B169drNJ8cjkczTeGn9GU6jz/5m5d9+cv6C5Celcs09BJDV3e91qT0qwnXYpY8V+WkcW
NiTNRbEnbpQfde4/iO/S9k2trhKepdyAjb3AHUYH5gQ7vkrbS0tFIcUDqhjMFFBuweUGK8PPua+/
gHLfMUqGEkaLxUnwtnnpn1EUljiNEWIj/6XiuswaIj09kfCSq1p6uzZIZZH8Do3C2M+8l15ZCYcI
3Mu6Hx3Vn2I7zcxYxukXQ8yz7AdztYGCg6JsgLhSMsZ4PwIe34bgz2E6Fo/ZhaXgg+iPgu3xzrkz
6fN9Q0Uk/ZdgKCxZp7y4N49k5WDIOG9s6lyOkw==
B64EOF
base64 -d > "$TMP/rsa/sig3072_sha256_pkcs1.bin" <<'B64EOF'
cLVgVV/dMR0IwmH5mRNVy3zKs89IoT3kpXtj7u4DxqvmseF5sXuC3mZskLMiC1uX5/ORpzdqMjkO
hvfwm+NHm0cTOG2H0GAVdy6RvmeMV24kq6mwS31VJrtVYnpIdqChc4ZEHGZ6PeYnfe9lVW3MHiYQ
SbIqJ7gUJ6T8Xn/hFhxF8Jeeu7kh3KpJU0T1aYWLzvxK/+CFVtBCWYaELF2hZ1SrMbjAdylBKRlj
cpnjTIf2RFwX41SB8woGdwmUPUmbLL9v2OyJ1KtwjSYU7X6WhPDJELsvsmm7pfrrCgTnaKvt0MIM
d1VID6E+JZ+K/z6TLkodqeW3WicaE6oIzvPA3gvk6EJwNvJqWpo6Kxb27hIhNdPkVn7zOuehNsHw
P9QhoV0J4ESAhG8uyDAaEKZWKLa7tuM9Xfcpm07SUOHuwIBJQREFNLIDzRgCQ/1l9V7evhPgY8Kh
iQPSrCZ3jhb6Te/2KDKpFep6oxo0gzoY3H+YichZJsPYgKciazAGUcgV
B64EOF
base64 -d > "$TMP/rsa/sig3072_sha256_pss.bin" <<'B64EOF'
Z7yVFHOSoOYQRcIibj6Muniv7dZnOVSw4u5qDiHJrQ49ROdD5qr5LCUBHOKm/0GHnDh15e3IKGst
Zv2FAoHS3mDhf64OW3Ny6eRgweLrYxfP7zLCscAT5zIst0+Aq5j2jIlkgKszvIK8TOvAcNoDJUPz
F06QB+7Nb19wFxTiZUPhCp3xGYw06XNi9jZEbkhEKmHSIzwtAD1/RPwWjgONiPqgOdei99YImM11
Cd63jB1s80xX9KhZVQYo/PWgTZmYxs+wvXVCUTPwOvoufFIh6D4n/na1jffKXknPH8B3MAhZBYUE
SS6+QDdLDznvHTMnfjrOJwO41uYhisMUzPmknxStWQYcoTgPQWfjgalmO5tDEvVoW8lv0xf4mGoD
Oi41Yjc/5HAyeLdKjv8PGZcs0zHh7xzM2FPPslLJF/PDFP3rZaNM1On5iq+sBh6EDUh1JD5zb2o3
mf4lQJkhvjHVhrFIt/p8SZ3vPUlXwqdfW9TonN+Bah147JxgB3YqU1P/
B64EOF
base64 -d > "$TMP/rsa/sig3072_sha512_pkcs1.bin" <<'B64EOF'
OUStmXtwy49wzLwEXNYRSm5B+FDbrpx6cA9g1tNLFMGdJHfojK3xmCvfl2JEGq6L21mdzRfvBqjp
q75XUJkVGA5t7CRGhKCgsOMc0Ob/9vVRVtrVhb+VEsOQZbGJ/bwtcq4gC88CgV5NbG2pNeuidugM
wrKkoihh3LfV17nmmb3xldR6WfrHHa02jrmkYjJDlkidRnHHSXWX3IWQjPyU5piF5XVxIZg1WLq3
sDl8TH3xKWp4G9s8FrfpNp9WswO0EqhuarYSvEFCHESFUeM7D2gwRQmgbq4lZjggAYUyfE21ZTms
zPWHtj20jxnfs8arIKQ4GNi4pxPzIhZSogWdhPv5gDg0U6b2OU42HgVPBkUkV65oKN1jia6thldk
aRMAvlpqQiKbYVr2Cvfaec0u9xVYeFtcsXxxQfW1CLjD6aYMmG/p+DFVbJYLsnx4WihxwT0wSnZs
+4Y4DoX6xHBlrKaM+L9f2kTvivZTxAc+R6GCVeutFzjgNl5P/0sf0jKd
B64EOF
base64 -d > "$TMP/rsa/sig3072_sha512_pss.bin" <<'B64EOF'
IFWFOPvWPjgVifIzRaFI1ech837PZgx5Wzrc+SaFJhdCmIT4Zh0N27qO+6Jy8Hel+SOd5ExIRK00
MdDwCIElyF6b9K7tYZcTofmiC6OriZwFKlXc6vWUzhSd4Hux5a97472fPCUh7QZsiDP6YufkFbL1
EyhwTtPyiOALJAUz0NGZpZA94dBtujJENS1/PhTrnfgJRs0g1PkDCpBX6+ojgqHBbFgLvW/v1OOV
xF65AGwGct4QoIsjEmRcSBGEWQj47SYjxqo/rV3X6J3j66Ng1gbnqSna+DlDXV+xImdarDNbXDJF
1b32FVeWvPQraikIiVNUaxgyc6bZIj+tivy1mvXACkLZ2EATP2LMlPWciI3Ix7A7yIJ1v8zaR9v6
uN7DbRLSGS9p9E8tb0utfGYpVwzX9DLIcCNpc6VjZGZ6h/bd58Ody467lNvblJWCR8juvK5cjUzv
ozsQP5SaeZZy4LwY5DF5peP52lgfZzq0nbord5OE7308zTBl0OMe2Wy5
B64EOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.string;
import std.crypto.der;
import std.crypto.sha256;
import std.crypto.sha512;
import std.crypto.rsa_native;

fn hex(b: int64, n: int64): void {
  var d: pchar := "0123456789abcdef"c;
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := peek8(b + i) & 255;
    PrintChar(StrCharAt(d, (v >> 4) & 15)); PrintChar(StrCharAt(d, v & 15));
    i := i + 1;
  }
  PrintLn("");
}
fn ladePem(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 8192);
}
fn ladeRoh(pfad: pchar, out: int64, cap: int64): int64 {
  return ReadFile(pfad, out as pchar, cap);
}

fn jaNein(b: bool): void {
  if (b) { PrintLn("ja"); } else { PrintLn("nein"); }
}

fn pruefeSatz(basis: pchar, bits: pchar, hashLen: int64, hashName: pchar,
              msg: int64, msgLen: int64): void {
  // Die eigenen Signaturen landen zusaetzlich als Datei, damit der Test sie
  // von openssl pruefen lassen kann (zweite Richtung).
  var dPub: int64 := alloc(8192);
  var lPub: int64 := ladePem(StrConcat(StrConcat(basis, "/p"c), StrConcat(bits, ".pem"c)), "PUBLIC KEY"c, dPub);
  var oeff: int64 := alloc(RsaSchluesselGroesse());
  if (!RsaPubAusSpki(dPub, lPub, oeff)) { PrintLn("SPKI-FEHLER"); return; }
  Print("bits "); PrintInt(RsaBits(oeff)); Print(" bytes "); PrintInt(RsaBytes(oeff)); PrintLn("");

  var hash: int64 := alloc(64);
  if (hashLen == 32) { SHA256(msg, msgLen, hash); }
  if (hashLen == 48) { Sha384(msg, msgLen, hash); }
  if (hashLen == 64) { Sha512(msg, msgLen, hash); }

  // Fremdsignaturen pruefen
  var sig: int64 := alloc(1024);
  var pfad1: pchar := StrConcat(StrConcat(StrConcat(basis, "/sig"c), bits),
                                StrConcat(StrConcat("_"c, hashName), "_pkcs1.bin"c));
  var sl: int64 := ladeRoh(pfad1, sig, 1024);
  Print("pkcs1-fremd-gueltig "); jaNein(RsaVerifyPkcs1(oeff, hashLen, hash, sig, sl));
  // ein Bit im Signaturwert kippen -> muss abgewiesen werden
  poke8(sig + 10, peek8(sig + 10) ^ 1);
  Print("pkcs1-verfaelscht-abgewiesen "); jaNein(!RsaVerifyPkcs1(oeff, hashLen, hash, sig, sl));
  poke8(sig + 10, peek8(sig + 10) ^ 1);
  // falscher Hash -> muss abgewiesen werden
  poke8(hash, peek8(hash) ^ 0x80);
  Print("pkcs1-falscher-hash-abgewiesen "); jaNein(!RsaVerifyPkcs1(oeff, hashLen, hash, sig, sl));
  poke8(hash, peek8(hash) ^ 0x80);

  var pfad2: pchar := StrConcat(StrConcat(StrConcat(basis, "/sig"c), bits),
                                StrConcat(StrConcat("_"c, hashName), "_pss.bin"c));
  var sl2: int64 := ladeRoh(pfad2, sig, 1024);
  Print("pss-fremd-gueltig "); jaNein(RsaVerifyPss(oeff, hashLen, hash, sig, sl2));
  poke8(sig + 20, peek8(sig + 20) ^ 2);
  Print("pss-verfaelscht-abgewiesen "); jaNein(!RsaVerifyPss(oeff, hashLen, hash, sig, sl2));
  poke8(sig + 20, peek8(sig + 20) ^ 2);
  poke8(hash + 3, peek8(hash + 3) ^ 0x40);
  Print("pss-falscher-hash-abgewiesen "); jaNein(!RsaVerifyPss(oeff, hashLen, hash, sig, sl2));
  poke8(hash + 3, peek8(hash + 3) ^ 0x40);

  // Eigene Signaturen: PKCS#1 ist bestimmt -> Bytes werden gedruckt und
  // gegen python gehalten; PSS ist zufaellig -> nur Rundlauf pruefbar.
  var dPriv: int64 := alloc(8192);
  var lPriv: int64 := ladePem(StrConcat(StrConcat(basis, "/k"c), StrConcat(bits, ".pem"c)), "PRIVATE KEY"c, dPriv);
  var priv: int64 := alloc(RsaSchluesselGroesse());
  if (!RsaPrivAusPkcs8(dPriv, lPriv, priv)) { PrintLn("PKCS8-FEHLER"); return; }
  Print("privat-erkannt "); jaNein(RsaHatPrivat(priv));
  var eigen: int64 := alloc(1024);
  var el: int64 := RsaSignPkcs1(priv, hashLen, hash, eigen);
  WriteFile(StrConcat(StrConcat(StrConcat(basis, "/our_"c), bits),
                      StrConcat(StrConcat("_"c, hashName), "_pkcs1.bin"c)),
            eigen as pchar, el);
  Print("eigen-pkcs1-laenge "); PrintInt(el); PrintLn("");
  Print("eigen-pkcs1 "); hex(eigen, el);
  Print("eigen-pkcs1-selbst-gueltig "); jaNein(RsaVerifyPkcs1(oeff, hashLen, hash, eigen, el));
  var el2: int64 := RsaSignPss(priv, hashLen, hash, eigen);
  Print("eigen-pss-laenge "); PrintInt(el2); PrintLn("");
  Print("eigen-pss-selbst-gueltig "); jaNein(RsaVerifyPss(oeff, hashLen, hash, eigen, el2));
  var pfadPss: pchar := StrConcat(StrConcat(StrConcat(basis, "/our_"c), bits),
                                  StrConcat(StrConcat("_"c, hashName), "_pss.bin"c));
  WriteFile(pfadPss, eigen as pchar, el2);
  poke8(eigen + 30, peek8(eigen + 30) ^ 4);
  Print("eigen-pss-verfaelscht-abgewiesen "); jaNein(!RsaVerifyPss(oeff, hashLen, hash, eigen, el2));
}

fn main(): int64 {
  var basis: pchar := "RSADIRMARKER"c;
  var msg: int64 := alloc(512);
  var msgLen: int64 := ladeRoh(StrConcat(basis, "/msg.bin"c), msg, 512);
  Print("nachricht-laenge "); PrintInt(msgLen); PrintLn("");
  pruefeSatz(basis, "2048"c, 32, "sha256"c, msg, msgLen);
  pruefeSatz(basis, "2048"c, 48, "sha384"c, msg, msgLen);
  pruefeSatz(basis, "2048"c, 64, "sha512"c, msg, msgLen);
  pruefeSatz(basis, "3072"c, 32, "sha256"c, msg, msgLen);
  pruefeSatz(basis, "3072"c, 64, "sha512"c, msg, msgLen);
  // PKCS#1-Schluesselform (nicht PKCS#8)
  var dP1: int64 := alloc(8192);
  var lP1: int64 := ladePem(StrConcat(basis, "/k2048_pkcs1.pem"c), "RSA PRIVATE KEY"c, dP1);
  var k1: int64 := alloc(RsaSchluesselGroesse());
  Print("pkcs1-schluesselform "); jaNein(RsaPrivAusPkcs1(dP1, lP1, k1));
  Print("pkcs1-schluesselform-bits "); PrintInt(RsaBits(k1)); PrintLn("");
  // unbekannte Hashlaenge muss abgewiesen werden
  var dPub: int64 := alloc(8192);
  var lPub: int64 := ladePem(StrConcat(basis, "/p2048.pem"c), "PUBLIC KEY"c, dPub);
  var oeff: int64 := alloc(RsaSchluesselGroesse());
  RsaPubAusSpki(dPub, lPub, oeff);
  var h2: int64 := alloc(64);
  var sig: int64 := alloc(1024);
  var sl: int64 := ladeRoh(StrConcat(basis, "/sig2048_sha256_pkcs1.bin"c), sig, 1024);
  Print("hashlaenge-20-abgewiesen "); jaNein(!RsaVerifyPkcs1(oeff, 20, h2, sig, sl));
  Print("falsche-siglaenge-abgewiesen "); jaNein(!RsaVerifyPkcs1(oeff, 32, h2, sig, sl - 1));
  return 0;
}
LYXEOF
sed -i "s|RSADIRMARKER|$TMP/rsa|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/s" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

cat > "$TMP/soll.txt" <<'SOLLEOF'
nachricht-laenge 300
bits 2048 bytes 256
pkcs1-fremd-gueltig ja
pkcs1-verfaelscht-abgewiesen ja
pkcs1-falscher-hash-abgewiesen ja
pss-fremd-gueltig ja
pss-verfaelscht-abgewiesen ja
pss-falscher-hash-abgewiesen ja
privat-erkannt ja
eigen-pkcs1-laenge 256
eigen-pkcs1 15f0dc7bea45a0ab31198dbf1e456912f9c67492e8b6b82908d0cec371faf256a1d79dd63a90e4ed8fe6dbec645cf67862cc68e90126f7ae4c7ed7d02a17560d8626e38119eb6dbe56b6ff8d52adc148171a6ed9d5e9aabdf3541938a7b02179cab5c5009bc07206ea080c1d5091b52c35e00e107cc3878b44088a23a9d5ca83b59e73d09beed97f8b92d714609f3b0bf69c2997be7ac35a51eec882f1c18055d7b7a63d0e190d6b71fe4072723a50493bbb04f7db76a20ca72b33894969bceeb3663ce59b5adb8357e21dab9465aba369beba5f0e434792f075afbd5fda25ec5574ae7b2a91e3e7146da091c44aa88c6672e0e3917e4ac09f05491e6f9e3807
eigen-pkcs1-selbst-gueltig ja
eigen-pss-laenge 256
eigen-pss-selbst-gueltig ja
eigen-pss-verfaelscht-abgewiesen ja
bits 2048 bytes 256
pkcs1-fremd-gueltig ja
pkcs1-verfaelscht-abgewiesen ja
pkcs1-falscher-hash-abgewiesen ja
pss-fremd-gueltig ja
pss-verfaelscht-abgewiesen ja
pss-falscher-hash-abgewiesen ja
privat-erkannt ja
eigen-pkcs1-laenge 256
eigen-pkcs1 7ed5819fa8ca001f4b5409b8462271a47f15ae69ddf35a8be442e07deb760b5ac12d81d8f5b063f93f813ec76ec81c5b7f14c7200b87f8ca36f87e09875282fcd1dfe41d4661305c74079c4e6963dbdab7bb23510249338fff7504a6f7f012d713891f8b28dfe7a04793b25f617b167b43498343836d4328cfe254f1b9c340c25a3b7224f06f191e80865403debd2808c890a8c67aa5baf2996fd1d48743d72ac089f77b66a2f576d91a187efb8fbabe92854d37836875ef0cf41df3cb5e8525fdb54f2264095e26175cf1a6bffae5836973b78f6e4f68f961c1def3bfb6955a70db9aa0c8bce7cfdafeae006cca99b292d6c2e47daf9a766079368d61deb5bb
eigen-pkcs1-selbst-gueltig ja
eigen-pss-laenge 256
eigen-pss-selbst-gueltig ja
eigen-pss-verfaelscht-abgewiesen ja
bits 2048 bytes 256
pkcs1-fremd-gueltig ja
pkcs1-verfaelscht-abgewiesen ja
pkcs1-falscher-hash-abgewiesen ja
pss-fremd-gueltig ja
pss-verfaelscht-abgewiesen ja
pss-falscher-hash-abgewiesen ja
privat-erkannt ja
eigen-pkcs1-laenge 256
eigen-pkcs1 442b6aadf001ddaff84f45c36fa81a09dd84f87006b93385536837eadd1ddda4e0f6c136be2f2238e65f5860baf7ae276294434a24ed26b98fe96b2320d2619ee355d4969dd128d1dba50dbe6b0e2404cd7f5a851fa6897909817ff71a058f2fd3bd70f57cbd9f8945e7c1beb638e50260f33b7ab8865ee0ee16688e8c07bed0b5ca9f8df88b300064a30d7a889559120550de8682b80ef74056a8518594acedaf562fb1300b80adf2a7501b63c44a052aa5650888505f0e764b9193711e604036a2d2d13794bbf2ce45cad8666ee3c23cdcbadf0505538d18d306b3e4709e7e4d9470d741235ec57caebd0665cac35433a8c7693db24b26ab69962cb1b0d0f1
eigen-pkcs1-selbst-gueltig ja
eigen-pss-laenge 256
eigen-pss-selbst-gueltig ja
eigen-pss-verfaelscht-abgewiesen ja
bits 3072 bytes 384
pkcs1-fremd-gueltig ja
pkcs1-verfaelscht-abgewiesen ja
pkcs1-falscher-hash-abgewiesen ja
pss-fremd-gueltig ja
pss-verfaelscht-abgewiesen ja
pss-falscher-hash-abgewiesen ja
privat-erkannt ja
eigen-pkcs1-laenge 384
eigen-pkcs1 70b560555fdd311d08c261f9991355cb7ccab3cf48a13de4a57b63eeee03c6abe6b1e179b17b82de666c90b3220b5b97e7f391a7376a32390e86f7f09be3479b4713386d87d06015772e91be678c576e24aba9b04b7d5526bb55627a4876a0a17386441c667a3de6277def65556dcc1e261049b22a27b81427a4fc5e7fe1161c45f0979ebbb921dcaa495344f569858bcefc4affe08556d0425986842c5da16754ab31b8c07729412919637299e34c87f6445c17e35481f30a067709943d499b2cbf6fd8ec89d4ab708d2614ed7e9684f0c910bb2fb269bba5faeb0a04e768abedd0c20c7755480fa13e259f8aff3e932e4a1da9e5b75a271a13aa08cef3c0de0be4e8427036f26a5a9a3a2b16f6ee122135d3e4567ef33ae7a136c1f03fd421a15d09e04480846f2ec8301a10a65628b6bbb6e33d5df7299b4ed250e1eec0804941110534b203cd180243fd65f55edebe13e063c2a18903d2ac26778e16fa4deff62832a915ea7aa31a34833a18dc7f9889c85926c3d880a7226b300651c815
eigen-pkcs1-selbst-gueltig ja
eigen-pss-laenge 384
eigen-pss-selbst-gueltig ja
eigen-pss-verfaelscht-abgewiesen ja
bits 3072 bytes 384
pkcs1-fremd-gueltig ja
pkcs1-verfaelscht-abgewiesen ja
pkcs1-falscher-hash-abgewiesen ja
pss-fremd-gueltig ja
pss-verfaelscht-abgewiesen ja
pss-falscher-hash-abgewiesen ja
privat-erkannt ja
eigen-pkcs1-laenge 384
eigen-pkcs1 3944ad997b70cb8f70ccbc045cd6114a6e41f850dbae9c7a700f60d6d34b14c19d2477e88cadf1982bdf9762441aae8bdb599dcd17ef06a8e9abbe57509915180e6dec244684a0a0b0e31cd0e6fff6f55156dad585bf9512c39065b189fdbc2d72ae200bcf02815e4d6c6da935eba276e80cc2b2a4a22861dcb7d5d7b9e699bdf195d47a59fac71dad368eb9a462324396489d4671c7497597dc85908cfc94e69885e5757121983558bab7b0397c4c7df1296a781bdb3c16b7e9369f56b303b412a86e6ab612bc41421c448551e33b0f68304509a06eae256638200185327c4db56539acccf587b63db48f19dfb3c6ab20a43818d8b8a713f3221652a2059d84fbf980383453a6f6394e361e054f06452457ae6828dd6389aead865764691300be5a6a42229b615af60af7da79cd2ef71558785b5cb17c7141f5b508b8c3e9a60c986fe9f831556c960bb27c785a2871c13d304a766cfb86380e85fac47065aca68cf8bf5fda44ef8af653c4073e47a18255ebad1738e0365e4fff4b1fd2329d
eigen-pkcs1-selbst-gueltig ja
eigen-pss-laenge 384
eigen-pss-selbst-gueltig ja
eigen-pss-verfaelscht-abgewiesen ja
pkcs1-schluesselform ja
pkcs1-schluesselform-bits 2048
hashlaenge-20-abgewiesen ja
falsche-siglaenge-abgewiesen ja
SOLLEOF

if ! ( ulimit -v 4000000; timeout 300 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
  echo "FAIL Lauf gescheitert: $(head -1 "$TMP/err.txt")"; exit 1
fi

ZS=$(wc -l < "$TMP/soll.txt"); ZI=$(wc -l < "$TMP/ist.txt")
if [ "$ZI" != "$ZS" ]; then echo "FAIL $ZI Zeilen statt $ZS"; diff "$TMP/soll.txt" "$TMP/ist.txt" | head -20; exit 1; fi
FAIL=0; PASS=0; N=0
while IFS= read -r soll && IFS= read -r ist <&3; do
  N=$((N+1))
  if [ "$soll" = "$ist" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL Zeile $N"; echo "  ist:  $ist"; echo "  soll: $soll"; fi
done < "$TMP/soll.txt" 3< "$TMP/ist.txt"

# --- Punkt 4: unsere eigenen Signaturen von openssl pruefen lassen ---
if command -v openssl >/dev/null 2>&1; then
  for fall in "2048 sha256" "2048 sha384" "2048 sha512" "3072 sha256" "3072 sha512"; do
    set -- $fall; bits=$1; h=$2
    for verf in pkcs1 pss; do
      sig="$TMP/rsa/our_${bits}_${h}_${verf}.bin"
      if [ ! -s "$sig" ]; then echo "FAIL $verf $bits/$h: keine Signatur geschrieben"; FAIL=$((FAIL+1)); continue; fi
      if [ "$verf" = pss ]; then
        opt="-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1"
      else
        opt=""
      fi
      if openssl dgst -"$h" -verify "$TMP/rsa/p${bits}.pem" $opt \
           -signature "$sig" "$TMP/rsa/msg.bin" >/dev/null 2>&1; then
        echo "PASS openssl nimmt unsere $verf-Signatur ($bits/$h)"; PASS=$((PASS+1))
      else
        echo "FAIL openssl lehnt unsere $verf-Signatur ab ($bits/$h)"; FAIL=$((FAIL+1))
      fi
    done
  done
else
  echo "SKIP openssl nicht im Pfad — eigene Signaturen nur selbst geprueft"
fi

echo "PASS $PASS / FAIL $FAIL (RSA PKCS#1 v1.5 und PSS)"
[ "$FAIL" = 0 ] || exit 1
echo "ALL PASS"
exit 0
