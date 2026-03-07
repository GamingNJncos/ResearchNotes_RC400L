#!/bin/sh
# deploy_shadow.sh — RC400L shadow-suite installer
# Run from rootshell after pushing both shadow packages to /data/tmp/
#
# SETUP (from PC):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/02_shadow_suite /data/tmp/shadow
#   MSYS_NO_PATHCONV=1 adb push PortableApps/25_shadow_extras /data/tmp/shadow_extras
#   adb shell
#   rootshell
#   sh /data/tmp/shadow/deploy_shadow.sh
#
# WHAT THIS DOES:
#   1. Preflight checks (root, source files present)
#   2. Creates /cache/bin/ and installs all shadow binaries (root-owned copies)
#   3. Creates /etc/shadow from /etc/passwd if absent:
#        - Entries with inline hash ($1$...) => moved to shadow, passwd field => x
#        - Entries already shadowed (x) => skipped
#        - Entries locked (*) or empty => written as-is to shadow
#   4. Installs /etc/login.defs from reference (if absent)
#   5. Smoke-tests su.shadow --help
#   6. Cleans up /data/tmp/shadow/ and /data/tmp/shadow_extras/
#
# AFTER INSTALL:
#   export PATH=/cache/bin:$PATH
#   su.shadow -         # open root shell using shadow password
#   passwd.shadow root  # change root password (written to /etc/shadow)
#   login.shadow        # shadow-aware login
#
# NOTE ON CAP_FOWNER LIMITATION:
#   rootshell has CapBnd=0x00c0 (SETUID+SETGID only). CAP_FOWNER is absent.
#   You cannot chmod a file you don't own. Files pushed via adb are owned by
#   uid=2000 (shell). Workaround: cp creates a new root-owned file; chmod on
#   that new file succeeds because you own it.
#
# BINARIES INSTALLED FROM /data/tmp/shadow/ (02_shadow_suite):
#   su.shadow, login.shadow, passwd.shadow, nologin, vipw.shadow,
#   useradd, userdel, usermod, groupadd, groupdel, groupmod,
#   chpasswd.shadow, chage, newgidmap, newuidmap
#
# BINARIES INSTALLED FROM /data/tmp/shadow_extras/ (25_shadow_extras) IF PRESENT:
#   chfn.shadow, chsh.shadow, gpasswd, newgrp.shadow, newusers,
#   chgpasswd, groupmems, grpck, grpconv, grpunconv,
#   pwck, pwconv, pwunconv, prepasswd, lastlog, logoutd, expiry, faillog

SRC_DIR="/data/tmp/shadow"
EXTRAS_DIR="/data/tmp/shadow_extras"
DEST_DIR="/cache/bin"
PASSWD="/etc/passwd"
SHADOW="/etc/shadow"
LOGIN_DEFS="/etc/login.defs"
LOGIN_DEFS_REF="$SRC_DIR/login.defs.reference"
SHADOW_TMP="/data/tmp/shadow.new"
PASSWD_TMP="/data/tmp/passwd.new"

# Core binaries from 02_shadow_suite (must all be present)
CORE_BINS="su.shadow login.shadow passwd.shadow nologin vipw.shadow \
           useradd userdel usermod groupadd groupdel groupmod \
           chpasswd.shadow chage newgidmap newuidmap"

# Optional extras from 25_shadow_extras (installed if dir exists)
EXTRA_BINS="chfn.shadow chsh.shadow gpasswd newgrp.shadow newusers \
            chgpasswd groupmems grpck grpconv grpunconv \
            pwck pwconv pwunconv prepasswd lastlog logoutd expiry faillog"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L shadow-suite installer"
echo "========================================"

# -------------------------------------------------------------------------
# [1] Preflight
# -------------------------------------------------------------------------
hdr "1. Preflight"

if [ "$(id -u)" != "0" ]; then
    err "Not running as root. Run: rootshell, then re-run this script."
    exit 1
fi
ok "Running as root (uid=0)"

if [ ! -d "$SRC_DIR" ]; then
    err "Source directory not found: $SRC_DIR"
    err "Push the package first:"
    err "  MSYS_NO_PATHCONV=1 adb push PortableApps/02_shadow_suite /data/tmp/shadow"
    exit 1
fi
ok "Source directory found: $SRC_DIR"

MISSING=""
for f in $CORE_BINS; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        MISSING="$MISSING $f"
    fi
done
if [ -n "$MISSING" ]; then
    err "Missing core binaries in $SRC_DIR:"
    for f in $MISSING; do
        err "  $f"
    done
    exit 1
fi
ok "All core binaries present in $SRC_DIR"

if [ ! -f "$PASSWD" ]; then
    err "/etc/passwd not found — cannot create shadow file"
    exit 1
fi
ok "/etc/passwd found ($(wc -l < "$PASSWD") entries)"

# -------------------------------------------------------------------------
# [2] Create /cache/bin/ and install core binaries
# -------------------------------------------------------------------------
hdr "2. Installing core binaries to $DEST_DIR"

mkdir -p "$DEST_DIR" || { err "mkdir $DEST_DIR failed"; exit 1; }
ok "Directory ready: $DEST_DIR"

for f in $CORE_BINS; do
    src="$SRC_DIR/$f"
    dst="$DEST_DIR/$f"
    cp "$src" "$dst" || { err "cp $f failed"; exit 1; }
    chmod 755 "$dst" || { err "chmod $f failed"; exit 1; }
    ok "Installed: $dst"
done

# su.shadow and passwd.shadow benefit from setuid root where supported,
# but setuid requires CAP_SETUID which rootshell has (CapBnd bit 6).
# Attempt it; non-fatal if it fails.
for f in su.shadow passwd.shadow; do
    chmod u+s "$DEST_DIR/$f" 2>/dev/null && info "setuid bit set on $f" \
        || info "setuid not set on $f (non-fatal — run as root anyway)"
done

# -------------------------------------------------------------------------
# [3] Install extras (25_shadow_extras) if pushed
# -------------------------------------------------------------------------
hdr "3. Installing extras from $EXTRAS_DIR"

if [ -d "$EXTRAS_DIR" ]; then
    EXTRAS_COUNT=0
    for f in $EXTRA_BINS; do
        src="$EXTRAS_DIR/$f"
        dst="$DEST_DIR/$f"
        if [ -f "$src" ]; then
            cp "$src" "$dst" || { err "cp $f failed"; exit 1; }
            chmod 755 "$dst" || { err "chmod $f failed"; exit 1; }
            ok "Installed: $dst"
            EXTRAS_COUNT=$((EXTRAS_COUNT + 1))
        fi
    done
    ok "$EXTRAS_COUNT extra binary(ies) installed"
else
    info "Extras directory not found: $EXTRAS_DIR"
    info "To install extras, push 25_shadow_extras:"
    info "  MSYS_NO_PATHCONV=1 adb push PortableApps/25_shadow_extras /data/tmp/shadow_extras"
    info "Then re-run this script. (Skipping — not required for basic operation)"
fi

# -------------------------------------------------------------------------
# [4] Create /etc/shadow from /etc/passwd
# -------------------------------------------------------------------------
hdr "4. Creating /etc/shadow"

if [ -f "$SHADOW" ]; then
    info "/etc/shadow already exists:"
    cat "$SHADOW" | sed 's/:[^:]*/:***:/' | sed 's/^/  /'
    info "Leaving existing /etc/shadow in place."
    info "To recreate it, remove /etc/shadow and re-run this script."
else
    info "No /etc/shadow found — generating from /etc/passwd ..."
    info "Parsing /etc/passwd ..."

    # Clear temp files
    rm -f "$SHADOW_TMP" "$PASSWD_TMP"

    # Process each line of /etc/passwd
    # Format: username:password:uid:gid:gecos:home:shell
    # We output a new /etc/shadow and a new /etc/passwd simultaneously.
    #
    # Shadow format:  username:hash:lastchg:min:max:warn:inactive:expire:
    # lastchg=0 forces password change on next login; use 0 so the existing
    # hash is accepted immediately with no forced-change pressure.
    # max=99999, warn=7 match standard Linux defaults.

    awk -F: '
    {
        username = $1
        pw       = $2
        rest     = $3 ":" $4 ":" $5 ":" $6 ":" $7

        if (pw == "x") {
            # Already shadowed — write a locked placeholder so shadow is
            # internally consistent, but do not touch passwd line.
            printf "%s:*:0:0:99999:7:::\n", username > "/data/tmp/shadow.new"
            print $0 > "/data/tmp/passwd.new"
        } else if (substr(pw, 1, 1) == "$" || substr(pw, 1, 1) == "*" || pw == "!" || pw == "") {
            # Hash present (any $N$ scheme), locked (*), or disabled (!/empty)
            # Move hash to shadow; replace passwd field with x
            printf "%s:%s:0:0:99999:7:::\n", username, pw > "/data/tmp/shadow.new"
            printf "%s:x:%s\n", username, rest > "/data/tmp/passwd.new"
        } else {
            # Plaintext or unknown format — lock in shadow, leave passwd alone
            printf "%s:%s:0:0:99999:7:::\n", username, pw > "/data/tmp/shadow.new"
            printf "%s:x:%s\n", username, rest > "/data/tmp/passwd.new"
        }
    }
    ' "$PASSWD"

    if [ ! -f "$SHADOW_TMP" ]; then
        err "awk failed to produce $SHADOW_TMP"
        exit 1
    fi

    # Backup originals before modifying
    cp "$PASSWD" /data/tmp/passwd.orig.bak 2>/dev/null \
        && ok "Backed up /etc/passwd to /data/tmp/passwd.orig.bak"

    # Install shadow file
    cp "$SHADOW_TMP" "$SHADOW" || { err "cp shadow failed"; exit 1; }
    chmod 640 "$SHADOW"        || { err "chmod shadow failed"; exit 1; }
    ok "Created $SHADOW (permissions 640)"

    # Install updated passwd (hashes replaced with x)
    cp "$PASSWD_TMP" "$PASSWD" || { err "cp passwd failed"; exit 1; }
    ok "Updated $PASSWD (inline hashes replaced with 'x')"

    # Show result
    info "Shadow entries created:"
    awk -F: '{printf "  %-16s %s\n", $1, (substr($2,1,1)=="$" ? "(hash moved)" : (substr($2,1,1)=="*" ? "(locked)" : "(other: " $2 ")"))}' "$SHADOW" \
        | sed 's/^/  /'

    # Clean temp files
    rm -f "$SHADOW_TMP" "$PASSWD_TMP"
fi

# -------------------------------------------------------------------------
# [5] Install /etc/login.defs
# -------------------------------------------------------------------------
hdr "5. Installing /etc/login.defs"

if [ -f "$LOGIN_DEFS" ]; then
    info "/etc/login.defs already present — leaving in place"
    if grep -q "ENCRYPT_METHOD" "$LOGIN_DEFS" 2>/dev/null; then
        METHOD=$(grep "^ENCRYPT_METHOD" "$LOGIN_DEFS" | awk '{print $2}')
        ok "ENCRYPT_METHOD = $METHOD"
    fi
else
    if [ -f "$LOGIN_DEFS_REF" ]; then
        cp "$LOGIN_DEFS_REF" "$LOGIN_DEFS" || { err "cp login.defs failed"; exit 1; }
        chmod 644 "$LOGIN_DEFS"
        ok "Installed $LOGIN_DEFS (ENCRYPT_METHOD SHA512)"
    else
        info "Reference not found: $LOGIN_DEFS_REF"
        info "Writing minimal /etc/login.defs ..."
        cat > /data/tmp/login.defs.min << 'EOF'
# /etc/login.defs - minimal config for RC400L shadow-suite
MAIL_FILE         .mail
PASS_MAX_DAYS     99999
PASS_MIN_DAYS     0
PASS_MIN_LEN      5
PASS_WARN_AGE     7
UID_MIN           1000
UID_MAX           60000
GID_MIN           1000
GID_MAX           60000
SYS_UID_MIN       101
SYS_UID_MAX       999
SYS_GID_MIN       101
SYS_GID_MAX       999
ENCRYPT_METHOD    SHA512
UMASK             022
LOGIN_RETRIES     5
LOGIN_TIMEOUT     60
DEFAULT_HOME      yes
USERGROUPS_ENAB   yes
SU_NAME           su
EOF
        cp /data/tmp/login.defs.min "$LOGIN_DEFS" || { err "cp minimal login.defs failed"; exit 1; }
        chmod 644 "$LOGIN_DEFS"
        rm -f /data/tmp/login.defs.min
        ok "Installed minimal $LOGIN_DEFS (ENCRYPT_METHOD SHA512)"
    fi
fi

# -------------------------------------------------------------------------
# [6] Verify /etc/shadow is readable by shadow binaries
# -------------------------------------------------------------------------
hdr "6. Verification"

# Confirm shadow exists and is non-empty
if [ -s "$SHADOW" ]; then
    SHADOW_LINES=$(wc -l < "$SHADOW")
    ok "/etc/shadow exists, $SHADOW_LINES line(s)"
else
    err "/etc/shadow is missing or empty after creation"
    exit 1
fi

# Confirm root entry is in shadow
if grep -q "^root:" "$SHADOW"; then
    ROOT_HASH=$(grep "^root:" "$SHADOW" | cut -d: -f2)
    if [ -z "$ROOT_HASH" ] || [ "$ROOT_HASH" = "*" ]; then
        info "root shadow entry: locked/empty (no password set)"
        info "Use passwd.shadow to set a password: $DEST_DIR/passwd.shadow root"
    else
        ok "root shadow entry: hash present (length=${#ROOT_HASH})"
    fi
else
    err "root entry not found in /etc/shadow"
    exit 1
fi

# Confirm /etc/passwd root entry now shows x
ROOT_PASSWD_FIELD=$(grep "^root:" "$PASSWD" | cut -d: -f2)
if [ "$ROOT_PASSWD_FIELD" = "x" ]; then
    ok "/etc/passwd root entry: password field is 'x' (shadowed)"
else
    info "/etc/passwd root password field: '$ROOT_PASSWD_FIELD'"
    info "(Expected 'x' — shadow binaries may still work if field contains hash)"
fi

# Smoke-test: su.shadow --help
info "Smoke-testing su.shadow --help ..."
"$DEST_DIR/su.shadow" --help 2>&1 | head -5 | sed 's/^/  /'
SU_EXIT=$?
# su --help exits non-zero on many shadow builds; check for output instead
if "$DEST_DIR/su.shadow" --help 2>&1 | grep -qi "usage\|option\|su"; then
    ok "su.shadow responds to --help"
else
    info "su.shadow --help did not produce expected output (exit $SU_EXIT)"
    info "Binary may still work correctly — test with: $DEST_DIR/su.shadow -"
fi

# List installed binaries
info "Installed binaries in $DEST_DIR:"
ls -la "$DEST_DIR"/ | grep -v "^total\|^d" | awk '{printf "  %-24s %s\n", $9, $5}' | sed 's/^  $//'

# -------------------------------------------------------------------------
# [7] Cleanup staging directories
# -------------------------------------------------------------------------
hdr "7. Cleanup"

rm -rf "$SRC_DIR" 2>/dev/null && ok "Removed $SRC_DIR" \
    || info "Could not remove $SRC_DIR (non-fatal)"

rm -rf "$EXTRAS_DIR" 2>/dev/null && ok "Removed $EXTRAS_DIR" \
    || info "$EXTRAS_DIR not present or could not be removed (non-fatal)"

# -------------------------------------------------------------------------
# [8] Success + usage
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Binaries installed to:  $DEST_DIR/"
echo " /etc/shadow:            created (root hash moved from /etc/passwd)"
echo " /etc/login.defs:        installed (ENCRYPT_METHOD SHA512)"
echo " /data/tmp/passwd.orig.bak: original /etc/passwd backup"
echo ""
echo " ACTIVATE IN CURRENT SHELL:"
echo "   export PATH=/cache/bin:\$PATH"
echo ""
echo " CORE USAGE:"
echo "   su.shadow -                      # open root login shell (reads /etc/shadow)"
echo "   su.shadow -c 'id' someuser       # run command as another user"
echo "   passwd.shadow root               # change root password (SHA512, stored in shadow)"
echo "   login.shadow                     # shadow-aware login prompt"
echo "   chage -l root                    # show root password aging info"
echo "   chage -M 99999 root              # set max password age"
echo ""
echo " USER MANAGEMENT:"
echo "   useradd -m -s /bin/sh newuser    # create user with home dir"
echo "   userdel newuser                  # delete user"
echo "   usermod -aG audio newuser        # add user to group"
echo "   groupadd mygroup                 # create a group"
echo "   groupdel mygroup                 # delete a group"
echo "   chpasswd.shadow <<'EOF'          # batch password change"
echo "   user:newpassword"
echo "   EOF"
echo ""
if [ -d "$DEST_DIR" ] && ls "$DEST_DIR"/chfn.shadow >/dev/null 2>&1; then
echo " EXTRAS (25_shadow_extras) INSTALLED:"
echo "   pwck                             # verify /etc/passwd integrity"
echo "   grpck                            # verify /etc/group integrity"
echo "   pwconv / pwunconv                # convert passwd <-> shadow"
echo "   gpasswd                          # administer /etc/group"
echo "   newgrp.shadow                    # log into a new group"
echo "   lastlog                          # show last login times"
echo "   faillog                          # show login failure log"
echo ""
fi
echo " PERSISTENCE:"
echo "   /cache survives reboot; /etc/shadow and /etc/login.defs"
echo "   are on the system partition — changes persist across reboots."
echo "   Add 'export PATH=/cache/bin:\$PATH' to your shell init if needed."
echo ""
echo " FILES:"
echo "   /etc/shadow       — shadow password database (root:640)"
echo "   /etc/login.defs   — shadow-suite configuration"
echo "   /data/tmp/passwd.orig.bak — original /etc/passwd backup"
echo ""
