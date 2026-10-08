#!/usr/bin/env bash
# Mirror staging.solit.com  ->  production-solit-com (solit.com, PRE-LAUNCH ONLY)
#
# 1. Backs up staging (DB + files) to ~/backup-staging-solit-com-auto
# 2. Backs up production DB + config to ~/backup-production-solit-com-auto
# 3. Syncs staging files to production (keeps production's wp-config, .htaccess, .htpasswd, .user.ini)
# 4. Imports staging DB into production, rewrites staging.solit.com -> solit.com
# 5. Verifies: preview cookie gets 200, public still redirected to solit-kapital.de
#
# SAFETY: refuses to run once the "solit-prelaunch" gate is gone from production's
# .htaccess, i.e. once solit.com is live. It will never overwrite a live site.

set -Eeuo pipefail
export PATH="$HOME/bin:$PATH"

STG="$HOME/public_html/staging-solit-com"
PROD="$HOME/public_html/production-solit-com"
STG_BK="$HOME/backup-staging-solit-com-auto"
PROD_BK="$HOME/backup-production-solit-com-auto"
LOG_DIR="$HOME/wordpress-automation/logs"
KEEP_STG=7    # staging backups (DB + files) to keep
KEEP_PROD=3   # production safety backups to keep

OLD_HOST="staging.solit.com"
NEW_HOST="solit.com"
OLD_PATH="/usr/www/users/solitn/staging-solit-com"
NEW_PATH="/usr/www/users/solitn/production-solit-com"
PUBLIC_REDIRECT="https://www.solit-kapital.de/"

if command -v wp >/dev/null 2>&1; then WP=(wp); else WP=(php "$HOME/wp-cli.phar"); fi
wps() { "${WP[@]}" --path="$STG" "$@"; }
wpp() { "${WP[@]}" --path="$PROD" "$@"; }
step() { echo; echo "== $(date '+%F %T')  $*"; }

rotate() { # rotate <dir> <glob> <keep>
  local dir=$1 glob=$2 keep=$3
  # shellcheck disable=SC2012,SC2086
  ls -1t "$dir"/$glob 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f --
}

mkdir -p "$STG_BK" "$PROD_BK" "$LOG_DIR" "$HOME/.tmp"
chmod 700 "$STG_BK" "$PROD_BK"
TS=$(date +%Y%m%d-%H%M)
exec > >(tee -a "$LOG_DIR/sync-staging-to-production-solit-com.log") 2>&1

# one run at a time
exec 9>"$HOME/.tmp/sync-solit-com.lock"
flock -n 9 || { echo "Another sync is already running - exiting."; exit 1; }

trap 'echo; echo "!! FAILED at line $LINENO (exit $?)";
      echo "!! Production DB before this run: $PROD_BK/production-db-$TS.sql.gz";
      echo "!! Rollback: gunzip -c $PROD_BK/production-db-$TS.sql.gz | wp --path=$PROD db import -"' ERR

step "Start mirror $OLD_HOST -> $NEW_HOST ($TS)"

# ---- safety gate -----------------------------------------------------------
if ! grep -q '^# BEGIN solit-prelaunch' "$PROD/.htaccess"; then
  echo "ABORT: pre-launch gate not found in $PROD/.htaccess."
  echo "solit.com appears to be LIVE - refusing to overwrite it with staging."
  exit 1
fi
TOKEN=$(grep -oE 'solit_preview=[0-9a-f]+' "$PROD/.htaccess" | head -n1 | cut -d= -f2)
[ -n "$TOKEN" ] || { echo "ABORT: preview token not found in .htaccess"; exit 1; }

# ---- 1. backup staging -----------------------------------------------------
step "1/6 Backup staging DB"
STG_SQL="$STG_BK/staging-db-$TS.sql"
wps db export "$STG_SQL" --single-transaction --quick
tail -n 1 "$STG_SQL" | grep -q 'Dump completed' || { echo "Staging dump incomplete"; false; }

step "1/6 Backup staging files"
# tar exit 1 = "file changed as we read it" (cache files) -> acceptable
tar -czf "$STG_BK/staging-files-$TS.tar.gz" -C "$HOME/public_html" staging-solit-com || [ $? -eq 1 ]

# ---- 2. safety backup of production ----------------------------------------
step "2/6 Backup production DB + config"
wpp db export - --single-transaction --quick | gzip > "$PROD_BK/production-db-$TS.sql.gz"
tar -czf "$PROD_BK/production-config-$TS.tar.gz" -C "$PROD" wp-config.php .htaccess

# ---- 3. files --------------------------------------------------------------
step "3/6 Sync files staging -> production"
# rsync exit 24 = files vanished during transfer (cache) -> acceptable
rsync -a --delete \
  --exclude='/wp-config.php' \
  --exclude='/.htaccess' \
  --exclude='/.htaccess.bak*' \
  --exclude='/.htpasswd' \
  --exclude='/.user.ini' \
  --exclude='/wp-content/cache/' \
  "$STG/" "$PROD/" || [ $? -eq 24 ]

# ---- 4. database -----------------------------------------------------------
step "4/6 Import staging DB into production"
wpp db import "$STG_SQL"

step "4/6 Rewrite URLs and paths"
wpp search-replace "$OLD_HOST" "$NEW_HOST" --all-tables --skip-columns=guid --report-changed-only
wpp search-replace "$OLD_PATH" "$NEW_PATH" --all-tables --report-changed-only
wpp option update blog_public 0   # keep hidden from search engines until go-live

# ---- 5. caches -------------------------------------------------------------
step "5/6 Flush caches"
wpp cache flush
wpp rewrite flush
wpp elementor flush-css 2>/dev/null || echo "(elementor flush-css not available - skipped)"

# ---- 6. verify -------------------------------------------------------------
step "6/6 Verify"
HOME_URL=$(wpp option get home)
[ "$HOME_URL" = "https://$NEW_HOST" ] || { echo "home is '$HOME_URL', expected https://$NEW_HOST"; false; }

CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "solit_preview=$TOKEN" "https://$NEW_HOST/")
[ "$CODE" = "200" ] || { echo "Preview homepage returned HTTP $CODE (expected 200)"; false; }

PUBLIC=$(curl -s -o /dev/null -w '%{redirect_url}' "https://$NEW_HOST/")
[ "$PUBLIC" = "$PUBLIC_REDIRECT" ] || { echo "Public redirect is '$PUBLIC' (expected $PUBLIC_REDIRECT)"; false; }
echo "home=$HOME_URL  preview=HTTP $CODE  public->$PUBLIC"

# ---- housekeeping ----------------------------------------------------------
step "Compress + rotate backups"
gzip -f "$STG_SQL"
rotate "$STG_BK"  'staging-db-*.sql.gz'            "$KEEP_STG"
rotate "$STG_BK"  'staging-files-*.tar.gz'         "$KEEP_STG"
rotate "$PROD_BK" 'production-db-*.sql.gz'         "$KEEP_PROD"
rotate "$PROD_BK" 'production-config-*.tar.gz'     "$KEEP_PROD"
du -sh "$STG_BK" "$PROD_BK"

step "Done - staging mirrored to $NEW_HOST"
