#!/bin/sh
# Runs the tests with a temporary keyring. Needs vim and gpg.
set -eu
cd "$(dirname "$0")/.."
# The path has to be short, gpg-agent puts a unix socket into it.
DIR=$(mktemp -d "${GPGEDIT_TESTDIR:-/tmp}/gpgedit.XXXXXX")
GNUPGHOME=$DIR/gnupg
export GNUPGHOME DIR
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
trap 'exit 1' INT TERM
mkdir -m 700 "$GNUPGHOME"

g() { gpg --batch --quiet --no-tty --trust-model always "$@"; }
fpr() { g --with-colons --list-keys "$1" | awk -F: '/^fpr/ { print $10; exit }'; }

for user in 'Alice Own <alice@example.test>' 'Bob Test <bob@example.test>' \
            'Carol Old <carol@example.test>' 'Carol New <carol@example.test>' \
            'Dora One <dora1@example.test>' 'Dora Two <dora2@example.test>' \
            'Signer <signer@example.test>'; do
  g --passphrase '' --quick-gen-key "$user" default default never 2>/dev/null
done

printf 'line1\nuser: \303\244\303\266\npass: x%%#!y\n' > "$DIR/plain"
g -r alice -r bob -o "$DIR/ok file.gpg" -e "$DIR/plain"
g -r alice -r bob --armor -o "$DIR/armor.gpg" -e "$DIR/plain"
g -r alice -r 'Carol Old' -o "$DIR/revoked.gpg" -e "$DIR/plain"
g -r bob -o "$DIR/foreign.gpg" -e "$DIR/plain"
g -r alice -u signer -o "$DIR/signed.gpg" -s -e "$DIR/plain"
g -r alice -R bob -o "$DIR/hidden.gpg" -e "$DIR/plain"
chmod 640 "$DIR/ok file.gpg"

sed 's/^:-----/-----/' "$GNUPGHOME/openpgp-revocs.d/$(fpr 'Carol Old').rev" | g --import 2>/dev/null
for user in bob 'Carol Old' 'Carol New' 'Dora One' 'Dora Two' signer; do
  g --yes --delete-secret-keys "$(fpr "$user")"
done
g --yes --delete-keys "$(fpr signer)"

mkdir "$DIR/tmp" "$DIR/bin"
# gpg wrapper that looks for plaintext in temporary files while gpg is in use
GPG=$(command -v gpg)
export GPG
cat > "$DIR/bin/gpg" <<'END'
#!/bin/sh
leak() { grep -rlE 'line1|line-new' "$DIR/tmp" >> "$DIR/leaks" 2>/dev/null; }
leak
"$GPG" "$@"
rc=$?
leak
exit $rc
END
chmod +x "$DIR/bin/gpg"

# Vim passes its own input on to the commands it runs and quits on end of file,
# so give it an input that stays open.
mkfifo "$DIR/input"
exec 3<> "$DIR/input"
rc=0
PATH=$DIR/bin:$PATH TMPDIR=$DIR/tmp vim -N -u NONE -i "$DIR/viminfo" -es \
  -c 'set undofile' -c "let &directory = \$DIR .. '/tmp'" -c "let &undodir = \$DIR .. '/tmp'" \
  -S plugin/gpgedit.vim -S test/test.vim <&3 || rc=$?
# Vim's exit code is useless here: with -es every expected error message counts.
# Without a result file it gave up before the end.
cat "$DIR/result" 2>/dev/null || echo "vim stopped before the end (exit code $rc)"
grep -q '^done: .* 0 failures$' "$DIR/result"
