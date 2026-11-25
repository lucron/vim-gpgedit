if !has('vim9script') || v:version < 900
  finish
endif
vim9script
# gpgedit.vim - edit GPG encrypted files in place, keeping their recipients
#
# Copyright (C) 2026 Patric Halama
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version. It is distributed WITHOUT ANY WARRANTY; see the LICENSE file.
#
# Plaintext only goes through pipes, never into temp, swap, undo or viminfo
# files.

if exists('g:loaded_gpgedit') || !has('unix') || !has('syntax')
  finish
endif
g:loaded_gpgedit = 1
g:loaded_gnupg = 1                      # do not load vim-gnupg as well

const pattern: string = get(g:, 'gpgedit_pattern', '*.gpg,*.pgp')

def Err(msg: string)
  echohl ErrorMsg | echomsg 'gpg: ' .. msg | echohl None
enddef

# Output lines of a gpg call that only returns metadata, independent of 'shell'
def Gpg(args: string): list<string>
  const sh = &shell
  set shell=/bin/sh
  try
    return systemlist('LC_ALL=C gpg --batch ' .. args .. ' 2>/dev/null')
  finally
    &shell = sh
  endtry
  return []
enddef

# Checksum of the encrypted file, to notice changes made by someone else
def Checksum(file: string): string
  return filereadable(file) ? sha256(string(readblob(file))) : ''
enddef

# Run "ex" with pipes instead of temp files; returns [exit code, stderr lines]
def Run(ex: string, args: string): list<any>
  const errfile = tempname()
  const [st, sh, srr] = [&shelltemp, &shell, &shellredir]
  set noshelltemp shell=/bin/sh
  var rc = 1
  try
    execute 'silent ' .. ex .. ' !LC_ALL=C gpg --quiet --batch ' .. args .. ' 2>' .. shellescape(errfile, 1)
    rc = v:shell_error
  finally
    [&shelltemp, &shell, &shellredir] = [st, sh, srr]
  endtry
  const err = filereadable(errfile) ? readfile(errfile) : []
  delete(errfile)
  return [rc, err]
enddef

def Open(file: string)
  setlocal noswapfile noundofile nomodeline
  setlocal viminfo= nobackup nowritebackup
  b:gpg_file = resolve(file)
  b:gpg_sum = Checksum(b:gpg_file)
  b:gpg_recipients = []
  b:gpg_writable = true
  b:gpg_armor = file =~? '\.asc$'
  if !filereadable(file)
    setlocal buftype=acwrite
    echo 'New file: enter recipients with :GpgList, then :w'
    return
  endif
  # recipients, one call; no decryption and no passphrase involved
  const info = Gpg('--list-packets --list-only -- ' .. shellescape(file))
  for line in info
    const id = matchstr(line, '^:pubkey enc packet:.* keyid \zs\x\+')
    if id =~ '^0\+$' || line =~ '^:symkey enc packet'
      b:gpg_writable = false
    elseif id != ''
      add(b:gpg_recipients, id)
    endif
  endfor
  b:gpg_armor = get(readfile(file, '', 1), 0, '') =~ '^-----BEGIN PGP'
  const ul = &l:undolevels
  setlocal undolevels=-1
  var [rc, err] = Run(':0read ++edit', '--status-fd 2 --decrypt -- ' .. shellescape(file, 1))
  const msg = copy(err)->filter((_, l) => l !~ '^\[GNUPG:\]')->join(' | ')
  # gpg also fails for signatures it cannot verify, that only deserves a warning
  if rc != 0 && (match(err, '^\[GNUPG:\] DECRYPTION_OKAY') < 0 || match(err, '^\[GNUPG:\] \(DECRYPTION_FAILED\|BADMDC\)') >= 0)
    silent :%delete _
    setlocal nomodified nomodifiable readonly buftype=nofile
    b:gpg_writable = false
    redraw!
    Err('decryption failed: ' .. msg)
    return
  endif
  silent :$delete _
  &l:undolevels = ul
  setlocal buftype=acwrite nomodified
  if !b:gpg_writable
    setlocal readonly
  endif
  execute 'silent doautocmd <nomodeline> BufReadPost ' .. fnameescape(fnamemodify(file, ':r'))
  setlocal nomodified
  cursor(1, 1)
  redraw!
  if rc != 0 | Err(msg) | endif
enddef

def Save(file: string)
  if !get(b:, 'gpg_writable', false)
    Err('not saved: buffer was not opened as a writable GPG file') | return
  endif
  const rcpt: list<string> = get(b:, 'gpg_recipients', [])
  if empty(rcpt)
    Err('not saved: no recipients, see :GpgList') | return
  endif
  const real = resolve(file)
  if !v:cmdbang && Checksum(real) != (real == b:gpg_file ? b:gpg_sum : '')
    Err('not saved: ' .. (real == b:gpg_file ? 'the file was changed by someone else since you opened it'
      : 'the target file exists') .. ' (use :w! to overwrite)')
    return
  endif
  # ciphertext, next to the target so that the rename is atomic
  const out = fnamemodify(real, ':h') .. '/.' .. fnamemodify(real, ':t') .. '.' .. getpid() .. '~'
  const opts = '--yes --trust-model always --no-encrypt-to --encrypt '
    .. (b:gpg_armor ? '--armor ' : '') .. '-o ' .. shellescape(out, 1) .. ' '
    .. join(mapnew(rcpt, (_, r) => '-r ' .. shellescape(r, 1)))
  const [rc, err] = Run(':%write', opts)
  if rc != 0 || getfsize(out) <= 0
    delete(out)
    redraw!
    Err('not saved: ' .. join(err, ' | '))
    return
  endif
  const perm = getfperm(real)
  if rename(out, real) != 0
    delete(out)
    Err('not saved: cannot write ' .. real) | return
  endif
  if perm != '' | setfperm(real, perm) | endif
  if resolve(expand('%:p')) == real
    b:gpg_file = real
    b:gpg_sum = Checksum(real)
    setlocal nomodified
  endif
  redraw!
  echo 'encrypted to ' .. len(rcpt) .. ' recipient(s)'
enddef

# ---- recipients -----------------------------------------------------------

def Colons(args: list<string>): list<list<string>>
  return Gpg('--with-colons --list-keys -- ' .. join(mapnew(args, (_, a) => shellescape(a))))
    ->mapnew((_, l) => split(l, ':', 1))
enddef

# Look up keys with one gpg call; returns one dict per primary key
def Lookup(args: list<string>): list<dict<any>>
  var keys: list<dict<any>> = []
  if empty(args) | return keys | endif
  for f in Colons(args)
    if f[0] == 'pub'
      var state = f[1] == 'r' ? 'REVOKED' : f[1] == 'e' ? 'EXPIRED'
        : f[1] =~ '[idn]' || f[11] !~# 'E' || f[11] =~# 'D' ? 'UNUSABLE' : ''
      add(keys, {id: f[4], ids: [f[4]], uid: '', uidbad: true, state: state})
    elseif f[0] == 'sub'
      add(keys[-1].ids, f[4])
    elseif f[0] == 'uid' && (keys[-1].uid == '' || (keys[-1].uidbad && f[1] !~ '[re]'))
      keys[-1].uid = substitute(f[9], '\\x\(\x\x\)', (m) => nr2char(str2nr(m[1], 16)), 'g')
      keys[-1].uidbad = f[1] =~ '[re]'
    endif
  endfor
  return keys
enddef

def Line(id: string, keys: list<dict<any>>): string
  for k in keys
    if index(k.ids, id) >= 0
      return id .. '  ' .. k.uid .. (k.state == '' ? '' : '  [' .. k.state .. ']')
    endif
  endfor
  return id .. '  [NOT IN KEYRING]'
enddef

def Fill(rcpt: list<string>)
  const keys = Lookup(rcpt)
  const ul = &l:undolevels
  setlocal undolevels=-1
  silent :%delete _
  setline(1, ['# dd = remove, o + name/email/key ID = add, :w = apply, :q! = cancel']
    + mapnew(rcpt, (_, r) => Line(r, keys)))
  &l:undolevels = ul
  setlocal nomodified
enddef

# :GpgList  open the recipients of this file as an editable buffer
def List()
  if !exists('b:gpg_recipients')
    Err('not a GPG file') | return
  endif
  const parent = bufnr()
  const rcpt: list<string> = b:gpg_recipients
  const writable: bool = b:gpg_writable
  const name = 'GPG-Recipients-' .. parent
  const win = bufwinid(get(b:, 'gpg_list', -1))
  if win > 0
    win_gotoid(win)
    return
  endif
  execute 'silent botright :' .. min([len(rcpt) + 3, 20]) .. 'new'
  execute 'silent file ' .. name
  setlocal buftype=acwrite bufhidden=wipe noswapfile noundofile nobuflisted
  setlocal formatoptions-=r formatoptions-=o textwidth=0 nowrap
  b:gpg_parent = parent
  setbufvar(parent, 'gpg_list', bufnr())
  syntax match Comment /^#.*/
  syntax match WarningMsg /^?.*/
  syntax match ErrorMsg /\[[A-Z ]\+\]$/
  Fill(rcpt)
  cursor(min([2, line('$')]), 1)
  if !writable
    setlocal nomodifiable readonly
    return
  endif
  autocmd BufWriteCmd <buffer> Apply()
enddef

# :w in the list: all lines must resolve to exactly one usable key, or nothing changes
def Apply()
  const parent: number = b:gpg_parent
  if !bufloaded(parent)
    Err('the file belonging to this list is no longer open') | return
  endif
  var result: list<string> = []
  var errors: list<string> = []
  var lines: list<string> = []
  for raw in getline(1, '$')
    const text = trim(raw)
    if text == '' || text[0] == '#'
      add(lines, raw)
      continue
    endif
    if text[0] == '?'
      add(lines, raw)
      add(errors, 'pick a key: delete the wrong lines and remove the "?" from the right one')
      continue
    endif
    const id = matchstr(text, '^\%(0x\)\?\zs\x\{16,40}\ze\%(\s\|$\)')
    const keys = Lookup([id != '' ? id : text])
    const good = copy(keys)->filter((_, k) => k.state == '')
    if len(good) == 1
      add(lines, raw)
      if index(result, good[0].id) < 0
        add(result, good[0].id)
      endif
    elseif len(good) > 1
      for k in good
        add(lines, '? ' .. k.id .. '  ' .. k.uid)
      endfor
      add(errors, '"' .. text .. '" is ambiguous')
    else
      add(lines, raw)
      add(errors, empty(keys) ? 'no key found for "' .. text .. '"'
        : keys[0].state .. ': ' .. keys[0].id .. ' ' .. keys[0].uid)
    endif
  endfor
  if empty(errors) && empty(result)
    add(errors, 'the list is empty')
  endif
  if empty(errors) && !v:cmdbang && !HaveSecret(result)
    add(errors, 'your own key is missing, you could not open the file again (use :w! to override)')
  endif
  if !empty(errors)
    if lines != getline(1, '$')
      silent :%delete _
      setline(1, lines)
    endif
    setlocal modified
    redraw
    Err('not applied: ' .. join(uniq(errors), ' | '))
    return
  endif
  setbufvar(parent, 'gpg_recipients', result)
  setbufvar(parent, '&modified', 1)
  Fill(result)
  redraw
  echo len(result) .. ' recipient(s) applied, now save the file with :w'
enddef

def HaveSecret(ids: list<string>): bool
  for id in ids
    if match(Gpg('--with-colons --list-secret-keys -- ' .. id), '^sec') >= 0
      return true
    endif
  endfor
  return false
enddef

def Refuse()
  throw 'gpgedit: only whole buffers can be written (a range would end up as plaintext)'
enddef

augroup GpgEdit
  autocmd!
  execute 'autocmd BufReadCmd ' .. pattern .. ' Open(expand(''<afile>:p''))'
  execute 'autocmd BufWriteCmd ' .. pattern .. ' Save(expand(''<afile>:p''))'
  execute 'autocmd FileWriteCmd,FileAppendCmd ' .. pattern .. ' Refuse()'
augroup END

command! -bar GpgList List()
