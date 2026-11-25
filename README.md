# vim-gpgedit

Edit GPG encrypted files in Vim as if they were plain text. The file is
decrypted when you open it and encrypted again, to the same recipients, when
you save it.

It is meant for encrypted notes and password files that a group of people
share. It is a single small Vim9 script and calls `gpg` only twice to open a
file, no matter how many recipients it has.

## Features

- Decrypts on open and encrypts on save, keeping the recipients and the armor
  of the file.
- Edit the recipients in a normal buffer: `dd` removes one, a new line with a
  name, email address or key ID adds one.
- Plaintext goes through pipes only. It is not written to temporary, swap,
  undo, backup or viminfo files.
- Refuses to save if the file changed on disk since you opened it, for example
  because a sync client replaced it.
- Names the key when a recipient is revoked, expired or missing, and leaves the
  file untouched.
- Warns before you remove your own key.

## Requirements

- Vim 9.0 or later. Neovim is not supported, because it has no Vim9 script.
- GnuPG 2.2 or later.
- Linux, macOS or another Unix.
- A graphical pinentry such as `pinentry-mac` or `pinentry-gnome3`.
  `pinentry-curses` and `pinentry-tty` share the terminal with Vim and are
  likely to garble the screen.

## Installation

With Vim's built-in packages:

```sh
git clone https://github.com/lucron/vim-gpgedit.git ~/.vim/pack/plugins/start/vim-gpgedit
vim -u NONE -c "helptags ~/.vim/pack/plugins/start/vim-gpgedit/doc" -c q
```

A plugin manager works too, or copy `plugin/gpgedit.vim` to `~/.vim/plugin/`.

Remove vim-gnupg first. Both plugins handle the same files.

## Usage

Open, edit and save `*.gpg` and `*.pgp` files as usual:

```sh
vim passwords.gpg
```

### Recipients

`:GpgList` opens the recipients of the current file:

```
# dd = remove, o + name/email/key ID = add, :w = apply, :q! = cancel
3496F67845B14AB5  Alice Example <alice@example.com>
402D25A7ABF5F6BA  Carol Example <carol@example.com>  [REVOKED]
```

1. Delete lines with `dd`, add lines with `o`. Write one name, email address or
   key ID per line.
2. `:w` (or `:wq`) applies the list. Every line has to match exactly one usable
   key, otherwise nothing is changed.
3. Save the file itself with `:w`. Only then is it encrypted to the new list.

If a name matches several keys, they are listed with a leading `?`. Delete the
wrong lines and remove the `?` from the right one. Revoked and expired keys are
skipped when you search by name, so replacing a revoked key is `dd` on the old
line and `o` with the same name.

Removing a recipient does not take away access to older copies of the file.
Change the secrets as well.

### New files

Open a file that does not exist yet, enter the recipients with `:GpgList`, then
save.

### Options

Files handled by the plugin. Set it in your vimrc:

```vim
let g:gpgedit_pattern = '*.gpg,*.pgp'
```

`*.asc` is not included by default, because it is also used for public keys,
signatures and AsciiDoc.

## Limitations

- **Recipients are not checked for trust.** Files are encrypted with
  `--trust-model always`. Check the fingerprint of a key before you add it.
- Files are not signed. If a file was signed, the signature is lost on save.
- Files that use a passphrase or hidden recipients open read-only.
- `:read file.gpg` and writing a range to a `.gpg` file are not supported.
  Writing a range is refused.
- `viminfo`, `backup` and `writebackup` are global options in Vim. They stay
  off for the rest of the session after you open an encrypted file.
- Yanked text still reaches the system clipboard if you put it there, and
  `:w notes.txt` writes plaintext because you asked for it.
- Other plugins can see the decrypted text.

## Tests

```sh
./test/run.sh
```

The tests use a temporary keyring and never touch your own.

## Credits

Inspired by [vim-gnupg](https://github.com/jamessan/vim-gnupg) by James McCoy
and Markus Braun. This is a separate implementation and shares no code with it.

### Why another script?

vim-gnupg works well for many people, but it was a poor fit for files shared by
a larger group and opened with a graphical pinentry:

- **Faster.** See the numbers below.
- **Less flicker.** vim-gnupg resets the terminal after every `gpg` call, to
  work around a problem with `pinentry-curses`
  ([issue #64](https://github.com/jamessan/vim-gnupg/issues/64)). This script
  expects a graphical pinentry and never resets the terminal.
- **Fewer `gpg` calls.** vim-gnupg looks up every recipient separately when it
  opens a file. With ten recipients that is 13 calls, here it is always two.
- **Clearer errors.** If a recipient's key is revoked, vim-gnupg only says that
  the message could not be encrypted. This script shows gpg's own message,
  which names the key, and marks it in `:GpgList`.
- **Easier recipient changes.** Searching by name skips revoked and expired
  keys, ambiguous names become a list to pick from, and you are warned before
  you remove your own key.

Median of 15 runs, in milliseconds:

| Recipients | Open: vim-gnupg | Open: vim-gpgedit | Save: vim-gnupg | Save: vim-gpgedit |
|-----------:|----------------:|------------------:|----------------:|------------------:|
|          1 |             118 |                81 |             278 |                34 |
|         10 |             319 |                82 |            1495 |                45 |
|         30 |             772 |                86 |            2394 |                73 |

Opening counts from starting Vim until the text is visible; Vim alone with a
plaintext file takes 24 ms. Measured with keys without a passphrase in a pseudo
terminal, so time spent in pinentry is not included. Apple Silicon, Vim 9.1,
GnuPG 2.5.24, vim-gnupg 2.7.0-dev (August 2019).

vim-gnupg is the better choice if you need passphrase (symmetric) encryption,
signing, `pinentry-curses` or a Vim older than 9.0.

## License

[GPL-3.0-or-later](LICENSE)
